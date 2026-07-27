#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palworld-config-snapshot runs as ROOT (jobd's snapshot_create action, which is
# not disruptive and so needs no confirm) with an attacker-chosen label. It used to
# write into a directory the *unprivileged* web account owned and then chown the
# finished tree to that account, which made it an arbitrary-root-write and
# arbitrary-chown primitive: the directory name is fully predictable from the
# label, and between root's mkdir and its last write there are six subprocesses at
# 30s timeouts each — seconds of window, not a tight race. Rename the directory
# root just made, drop a symlink in its place, and root writes manifest.json,
# buildid.txt and every command output through the link; the chown then follows it
# too.
#
# The fix removed the class: the snapshot root is root-owned 0755 on both platforms
# and there is no chown at all. So the assertions here are (a) the tool no longer
# hands ownership to anyone, and (b) the swap itself, reproduced, does not let
# root's writes escape the snapshot root.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
SNAP="$DIR/../../sbin/palworld-config-snapshot"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ME="$(id -un)"
MY_GROUP="$(id -gn)"
# A *secondary* group is what makes an unwanted chown observable without root:
# files are created with the primary group already, so asserting on the primary
# group would pass whether or not a chown ran at all. Empty when the user has only
# one group, in which case the "no chown happened" assertion is skipped rather
# than left vacuous.
ALT_GROUP="$(id -Gn | tr ' ' '\n' | grep -vx "$MY_GROUP" | head -1)"
# Set deliberately to a *different* group than creation would give: nothing in the
# tool may act on these any more. (They still mean the service account elsewhere in
# the repo, e.g. palworld-backup, so they are not removed from the environment.)
unset PALWORLD_USER PALWORLD_GROUP

# Module-load rather than run the CLI: `create` would shell out to the real
# /usr/local/sbin tools and systemctl, none of which exist here. files=[] and
# commands=[] keep the snapshot to the two files it always writes itself.
snapshot() {  # snapshot <output-root> [env...]
  local root="$1"; shift
  env "$@" python3 - "$SNAP" "$root" <<'EOF'
import importlib.machinery, importlib.util, sys
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("snapshot_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

path = mod.create_snapshot("Before Tuning", Path(sys.argv[2]), files=[], commands=[], mark=False)
print(path)
EOF
}

# --- the snapshot itself is created, and its name is derived from the label ---
out="$(snapshot "$WORK/snaps" 2>"$WORK/err1")"
snap_dir="$out"
if [ -d "$snap_dir" ]; then pass; else fail "snapshot directory not created: '$snap_dir'"; fi
assert_contains "$snap_dir" "before-tuning" "the label is slugified into the directory name"
assert_file_contains "$snap_dir/manifest.json" '"label": "Before Tuning"' "manifest records the label"
if [ -s "$snap_dir/buildid.txt" ]; then pass; else fail "buildid.txt not written"; fi
assert_eq "$(stat -c '%a' "$snap_dir")" "755" "the snapshot dir is 0755: listable, not writable by others"
assert_eq "$(wc -c < "$WORK/err1" | tr -d ' ')" "0" "a normal snapshot is silent on stderr"

# --- no ownership is handed out, whatever PALWORLD_USER/GROUP say ------------
# The tool must not chown its output at all now: the snapshot root is root-owned,
# so there is nobody to hand it to and any chown would be the arbitrary-chown leg
# of the escalation. A secondary group is what makes this observable unprivileged
# — creation gives the primary group, so a tree still carrying it proves nothing
# ran. Ask for the secondary group explicitly; a tool that still chowns would take
# it, and this fails.
if [ -n "$ALT_GROUP" ]; then
  out="$(snapshot "$WORK/snaps" PALWORLD_USER="$ME" PALWORLD_GROUP="$ALT_GROUP" 2>"$WORK/err2")"
  snap_dir2="$out"
  assert_eq "$(stat -c '%G' "$snap_dir2")" "$MY_GROUP" \
    "the snapshot dir keeps its creation group; PALWORLD_GROUP is not applied"
  chowned=0
  for f in "$snap_dir2"/*; do
    [ "$(stat -c '%G' "$f")" = "$MY_GROUP" ] || { chowned=1; echo "  (chowned: $f)"; }
  done
  assert_eq "$chowned" "0" "no file in the tree is chowned either"
  assert_eq "$(wc -c < "$WORK/err2" | tr -d ' ')" "0" "and no chown warning is emitted"
else
  echo "  SKIP: $ME has no secondary group, so an unwanted chown is unobservable"
fi

# --- the swap, reproduced: root's writes must not escape the snapshot root ----
# This is the demonstrated attack. The unprivileged owner of the snapshot root
# predicts the directory name (stamp + slugified label, both known), waits for root
# to create it, renames it aside, and puts a symlink to a file outside the tree at
# the name root is still writing to. Every subsequent write — manifest.json,
# buildid.txt, each command output — then lands on the symlink target.
#
# Reproduced by racing it for real rather than by patching the tool: the helper
# below runs create_snapshot with a slow `commands` list, and a background shell
# performs the swap while those commands are running. `victim` starts with known
# contents; if root wrote through the link it will not still have them.
SWAP_ROOT="$WORK/swap"
mkdir -p "$SWAP_ROOT"
printf 'ORIGINAL-VICTIM-CONTENTS\n' > "$WORK/victim"
printf 'ORIGINAL-VICTIM-CONTENTS\n' > "$WORK/victim-buildid"

# Predict the name the same way the tool does, then swap it the instant it appears.
(
  # Wait for any directory to appear under the (initially empty) snapshot root.
  for _ in $(seq 1 400); do
    target="$(find "$SWAP_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)"
    [ -n "$target" ] && break
    sleep 0.05
  done
  [ -n "${target:-}" ] || exit 0
  mv "$target" "$target.moved" 2>/dev/null || exit 0
  # A symlink to a *directory* outside the tree is the general form: every
  # `snapshot_dir / name` write then resolves through it.
  mkdir -p "$WORK/escape"
  ln -s "$WORK/escape" "$target" 2>/dev/null || true
  # And the specific form: point one attacker-known file name straight at a victim.
  ln -sfn "$WORK/victim" "$WORK/escape/manifest.json" 2>/dev/null || true
  ln -sfn "$WORK/victim-buildid" "$WORK/escape/buildid.txt" 2>/dev/null || true
) &
swapper=$!

env python3 - "$SNAP" "$SWAP_ROOT" >"$WORK/swap.out" 2>"$WORK/swap.err" <<'EOF' || true
import importlib.machinery, importlib.util, sys
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("snapshot_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

# Three slow commands stand in for the six 30s-timeout subprocesses the real
# default_commands() runs: they hold the window open long enough for the swapper.
slow = [(f"slow-{i}.txt", ["sleep", "1"]) for i in range(3)]
print(mod.create_snapshot("Before Tuning", Path(sys.argv[2]), files=[], commands=slow, mark=False))
EOF
wait "$swapper" 2>/dev/null || true

# The mkdir happens with mode 0755 in a root-owned root, so in production the
# swapper cannot even rename. Here the test user owns everything, so the rename
# *does* succeed — which is exactly what makes the assertion meaningful: even with
# the rename granted, root must not have written through the planted links.
assert_file_contains "$WORK/victim" "ORIGINAL-VICTIM-CONTENTS" \
  "root did not write manifest.json through a symlink planted outside the snapshot root"
assert_file_contains "$WORK/victim-buildid" "ORIGINAL-VICTIM-CONTENTS" \
  "root did not write buildid.txt through a planted symlink either"
assert_file_not_contains "$WORK/victim" '"label"' \
  "no snapshot manifest content leaked into the victim file"
# And nothing in the tool tries to chown the swapped-in path, which is the leg that
# turned this into a host takeover.
assert_file_not_contains "$WORK/swap.err" "chown" \
  "the tool never mentions chown: the arbitrary-chown leg is gone entirely"

# --- and the escalation's other half: no chown_tree symbol survives -----------
# A regression check on the *interface*, not the behaviour: re-adding a chown pass
# over a path the tool wrote is the whole bug, so its absence is asserted, not
# assumed. (Nothing outside this module called it — see the grep in the review.)
out="$(python3 - "$SNAP" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("snap", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)
print("present" if hasattr(mod, "chown_tree") else "absent")
EOF
)"
assert_eq "$out" "absent" "chown_tree is gone, not merely unused"

assert_report
