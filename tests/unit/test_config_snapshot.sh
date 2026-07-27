#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palworld-config-snapshot normally runs as ROOT (jobd's snapshot_create action)
# and writes into a directory the unprivileged service account owns, so handing
# the finished tree to that account is the whole point of its last step. That step
# hardcoded "palworld" inside a bare `except Exception: pass`, which meant it
# raised LookupError in the container (the account there is `steam`) and said
# nothing — root-owned snapshots in a steam-owned directory. The container is what
# reproduces it, so these assertions pin the two halves that are testable without
# docker: the account comes from PALWORLD_USER/PALWORLD_GROUP, and a name that
# does not resolve warns instead of being swallowed.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
SNAP="$DIR/../../sbin/palworld-config-snapshot"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ME="$(id -un)"
MY_GROUP="$(id -gn)"
# A *secondary* group is what makes the chown observable without root: files are
# created with the primary group already, so asserting on it would pass whether
# or not chown_tree ran at all. Empty when the user has only one group, in which
# case the ownership assertions below are skipped rather than left vacuous.
ALT_GROUP="$(id -Gn | tr ' ' '\n' | grep -vx "$MY_GROUP" | head -1)"
# Every case below states its own owner env; unset here so the default-value case
# is really testing the default and not something inherited from the caller.
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
TARGET_GROUP="${ALT_GROUP:-$MY_GROUP}"
out="$(snapshot "$WORK/snaps" PALWORLD_USER="$ME" PALWORLD_GROUP="$TARGET_GROUP" 2>"$WORK/err1")"
snap_dir="$out"
if [ -d "$snap_dir" ]; then pass; else fail "snapshot directory not created: '$snap_dir'"; fi
assert_contains "$snap_dir" "before-tuning" "the label is slugified into the directory name"
assert_file_contains "$snap_dir/manifest.json" '"label": "Before Tuning"' "manifest records the label"
if [ -s "$snap_dir/buildid.txt" ]; then pass; else fail "buildid.txt not written"; fi

# --- ownership comes from PALWORLD_USER/PALWORLD_GROUP -----------------------
# Non-root can only chown to itself, so the *group* carries the assertion: a
# secondary group differs from what creation already gave the files, so these
# fail unless the names really were read from the environment and applied to the
# whole tree. The hardcoded version cannot pass — "palworld" does not exist here.
if [ -n "$ALT_GROUP" ]; then
  assert_eq "$(stat -c '%U %G' "$snap_dir")" "$ME $TARGET_GROUP" "the snapshot dir gets PALWORLD_USER:PALWORLD_GROUP"
  bad_owner=0
  for f in "$snap_dir"/*; do
    [ "$(stat -c '%U %G' "$f")" = "$ME $TARGET_GROUP" ] || { bad_owner=1; echo "  (wrong owner on $f)"; }
  done
  assert_eq "$bad_owner" "0" "every file in the tree gets it too, not just the directory"
else
  echo "  SKIP: $ME has no secondary group, so a non-root chown is unobservable"
fi
assert_eq "$(wc -c < "$WORK/err1" | tr -d ' ')" "0" "a resolvable owner produces no warning"

# --- an unresolvable owner WARNS, and the snapshot still succeeds ------------
# The silent `except Exception: pass` is what hid the container bug; a failed
# chown must stay non-fatal (a snapshot with the wrong owner beats no snapshot)
# but must not be invisible.
out="$(snapshot "$WORK/snaps" PALWORLD_USER="definitely-no-such-user" \
        PALWORLD_GROUP="definitely-no-such-group" 2>"$WORK/err2")"
snap_dir2="$out"
if [ -d "$snap_dir2" ]; then pass; else fail "snapshot not created with an unresolvable owner"; fi
assert_file_contains "$snap_dir2/manifest.json" '"label": "Before Tuning"' "the snapshot is still complete"
assert_file_contains "$WORK/err2" "definitely-no-such-user" "the warning names the owner it could not resolve"
assert_file_contains "$WORK/err2" "Warning" "and says it is a warning, not a failure"

# --- the default is still the bare-metal account ----------------------------
# PALWORLD_USER unset must mean `palworld`, not the invoking user: the same
# ${VAR-default} convention every other script in the repo uses.
out="$(snapshot "$WORK/snaps" 2>"$WORK/err3")" || true
if [ -d "$out" ]; then pass; else fail "snapshot not created with no owner env at all"; fi
if id palworld >/dev/null 2>&1; then
  echo "  SKIP: a real 'palworld' account exists here, so the default resolves"
  pass
else
  assert_file_contains "$WORK/err3" "palworld:palworld" "with no env set it defaults to palworld:palworld"
fi

assert_report
