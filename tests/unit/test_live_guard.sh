#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# The live tier stops the server, replaces worlds and restarts it. Pointed at a real
# deployment it would be destructive, so its guard is the one part of that tier which
# must be verified by a suite that actually runs in CI — a destructive suite's safety
# check cannot be tested only by a tier nobody runs automatically.
#
# Which means this suite must pass at *any* uid. `mkdir -p` below creates fixtures
# owned by whoever runs it (1000 locally, 1001 on ubuntu-latest's runner, 0 in a
# container), while the guard's built-in expectation is a hardcoded 1000 — so every
# should-pass case states the invoker's own uid as the expectation, and the
# should-refuse case names a uid the invoker cannot be. Hardcoding 1000 here would
# reintroduce in CI the very 1000-vs-1001 break the guard exists to prevent.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
LIB="$DIR/../live/lib/testbed.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Read the ownership the guard itself will see, rather than assuming `id -u` matches
# it: on an idmapped or uid-shifting mount the two diverge, and the should-pass cases
# below would then fail for a reason that has nothing to do with the guard.
ME="$(stat -c %u "$WORK")"
# Every fixture below is created by this process, so this is the ownership the
# guard should accept. Cases that want a *mismatch* override it per call.
export PALWARDEN_LIVE_EXPECT_UID="$ME"

# Run the guard in a subshell with a chosen testbed, capturing output and status.
guard() {  # guard <testbed-dir>
  ( PALWARDEN_LIVE_TESTBED="$1" bash -c '
      source "$0" >/dev/null 2>&1 || exit 90
      live_require_testbed
    ' "$LIB" ) 2>&1
}
guard_rc() { guard "$1" >/dev/null 2>&1; echo $?; }

# A `stat` that reports uid 0 for the world directory and the truth for everything
# else, so the nested-ownership case can exist without root. Ownership is the one
# fixture property an unprivileged suite cannot create: `mkdir` always gives the
# invoker, and a symlink is no help because `stat` does not dereference. The real
# stat is baked in by absolute path — PATH is shadowed when this is in use.
REAL_STAT="$(command -v stat)"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/stat" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
case "\$last" in
  */server/Pal/Saved) echo 0 ;;
  *) exec "$REAL_STAT" "\$@" ;;
esac
EOF
chmod +x "$WORK/bin/stat"

# guard_stubbed <testbed-dir> — same as guard, with that stat ahead on PATH.
guard_stubbed() {
  ( PATH="$WORK/bin:$PATH" PALWARDEN_LIVE_TESTBED="$1" bash -c '
      source "$0" >/dev/null 2>&1 || exit 90
      live_require_testbed
    ' "$LIB" ) 2>&1
}

# --- refuses a directory with no marker -----------------------------------
mkdir -p "$WORK/nomarker"
assert_ne "$(guard_rc "$WORK/nomarker")" "0" "a testbed without the marker is refused"
out="$(guard "$WORK/nomarker")"
assert_contains "$out" ".palwarden-live-testbed" \
  "the refusal names the marker file, so the operator knows what to create"
assert_contains "$out" "LIVE_E_UNMARKED" "the unmarked refusal carries its own code"

# --- refuses a directory that does not exist at all -----------------------
assert_ne "$(guard_rc "$WORK/absent")" "0" "an absent testbed is refused"
# The checks are ordered, and the order is part of the contract: a path that is
# simply not there must be reported as that, not as a uid problem. Without this
# pair the ordering is unfalsifiable — every check still refuses in every case,
# just with the wrong explanation, and "wrong explanation" is precisely what
# sends an operator chasing a permission bug that does not exist. The code is the
# durable half of the assertion; the prose one survives as a second opinion.
out="$(guard "$WORK/absent")"
assert_contains "$out" "does not exist" \
  "the absent-testbed refusal reports the missing directory"
assert_contains "$out" "LIVE_E_NO_TESTBED" "the absent-testbed refusal carries its own code"
assert_not_contains "$out" "LIVE_E_OWNER_UID" \
  "a missing directory is not reported as a uid problem"

# --- refuses when the marker exists but the game is not installed ---------
mkdir -p "$WORK/bare"; : > "$WORK/bare/.palwarden-live-testbed"
assert_ne "$(guard_rc "$WORK/bare")" "0" "a marked testbed with no install is refused"
out="$(guard "$WORK/bare")"
assert_contains "$out" "UPDATE_ON_START" \
  "the refusal points at the one-time install step"
assert_contains "$out" "LIVE_E_NOT_INSTALLED" "the not-installed refusal carries its own code"

# --- accepts a marked testbed with an install present ---------------------
mkdir -p "$WORK/ok/server/Pal/Saved"; : > "$WORK/ok/.palwarden-live-testbed"
printf '#!/bin/sh\n' > "$WORK/ok/server/PalServer.sh"; chmod +x "$WORK/ok/server/PalServer.sh"
assert_eq "$(guard_rc "$WORK/ok")" "0" "a marked, installed testbed is accepted"

# --- refuses a uid mismatch ------------------------------------------------
# The container's steam account is uid 1000 by default. A bind mount owned by anyone
# else means the game cannot write its own save, so it is refused up front rather
# than surfacing later as a permission error inside the game.
#
# Both uids in that message are pinned by *role*, not by value: the message
# interpolates the owner and the expectation next to each other, and asserting only
# that "65534" appears would let the two be swapped — leaving the suite green while
# the message told the operator to `chown -R 65534`, i.e. to give their testbed to
# nobody.
FOREIGN_UID=65534  # nobody: a uid no real invoker of this suite has
if [[ "$ME" == "$FOREIGN_UID" ]]; then
  printf '  NOTE: running as uid %s; skipping the uid-mismatch case\n' "$FOREIGN_UID"
else
  assert_ne "$(PALWARDEN_LIVE_EXPECT_UID="$FOREIGN_UID" guard_rc "$WORK/ok")" "0" \
    "a uid mismatch is refused"
  out="$(PALWARDEN_LIVE_EXPECT_UID="$FOREIGN_UID" guard "$WORK/ok")"
  assert_contains "$out" "is owned by uid $ME" "the refusal names the actual owner"
  assert_contains "$out" "account is uid $FOREIGN_UID" "the refusal names the uid it expected"
  assert_contains "$out" "LIVE_E_OWNER_UID" "the uid refusal carries its own code"
fi

# --- the uid check reaches below the testbed root --------------------------
# docker/entrypoint.sh non-recursively chowns the install dir, Pal and Pal/Saved on
# every embedded start, so those self-heal — but a `sudo mkdir -p` of
# server/Pal/Saved (which create_host_path: false makes the operator do by hand)
# leaves deeper levels owned by root forever. Checking only the root would pass such
# a tree; the stubbed stat above makes exactly that tree without root.
mkdir -p "$WORK/deep/server/Pal/Saved"; : > "$WORK/deep/.palwarden-live-testbed"
printf '#!/bin/sh\n' > "$WORK/deep/server/PalServer.sh"; chmod +x "$WORK/deep/server/PalServer.sh"
if [[ "$ME" == "0" ]]; then
  # The stub reports 0, which is then not a mismatch at all.
  printf '  NOTE: running as uid 0; skipping the nested-ownership case\n'
else
  guard_stubbed "$WORK/deep" >/dev/null 2>&1
  assert_ne "$?" "0" "a foreign-owned server/Pal/Saved is refused"
  out="$(guard_stubbed "$WORK/deep")"
  assert_contains "$out" "server/Pal/Saved is owned by uid 0" \
    "the refusal names the nested path that is wrong, not just the root"
  # ...and the stub is load-bearing only there: the same tree passes unstubbed, so
  # this case cannot pass for some unrelated reason.
  assert_eq "$(guard_rc "$WORK/deep")" "0" "the same tree is accepted when nothing is foreign-owned"
fi

# --- refuses an install whose launcher lost its exec bit -------------------
# docker/entrypoint.sh's own check exits 1 on a non-executable PalServer.sh before
# it would chmod the file, so an install restored from a tar that dropped the exec
# bits never boots — and unguarded that appears only as a live_up timeout.
mkdir -p "$WORK/noexec/server/Pal/Saved"; : > "$WORK/noexec/.palwarden-live-testbed"
printf '#!/bin/sh\n' > "$WORK/noexec/server/PalServer.sh"; chmod -x "$WORK/noexec/server/PalServer.sh"
assert_ne "$(guard_rc "$WORK/noexec")" "0" "a non-executable PalServer.sh is refused"
out="$(guard "$WORK/noexec")"
assert_contains "$out" "LIVE_E_NOT_EXECUTABLE" "the non-executable refusal carries its own code"
assert_contains "$out" "chmod +x" "the refusal says how to fix the exec bit"

# --- a directory named PalServer.sh is not an install ----------------------
# -x alone is true for a directory, which would make an empty directory of that
# name look like a game install and fail much later, inside the container.
mkdir -p "$WORK/dirsh/server/PalServer.sh"; : > "$WORK/dirsh/.palwarden-live-testbed"
assert_ne "$(guard_rc "$WORK/dirsh")" "0" "a directory named PalServer.sh is refused"
assert_contains "$(guard "$WORK/dirsh")" "LIVE_E_NOT_INSTALLED" \
  "a directory named PalServer.sh is reported as no install, not as a bad exec bit"

assert_report
