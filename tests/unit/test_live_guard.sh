#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# The live tier stops the server, replaces worlds and restarts it. Pointed at a real
# deployment it would be destructive, so its guard is the one part of that tier which
# must be verified by a suite that actually runs in CI — a destructive suite's safety
# check cannot be tested only by a tier nobody runs automatically.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
LIB="$DIR/../live/lib/testbed.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run the guard in a subshell with a chosen testbed, capturing output and status.
guard() {  # guard <testbed-dir>
  ( PALWARDEN_LIVE_TESTBED="$1" bash -c '
      source "$0" >/dev/null 2>&1 || exit 90
      live_require_testbed
    ' "$LIB" ) 2>&1
}
guard_rc() { guard "$1" >/dev/null 2>&1; echo $?; }

# --- refuses a directory with no marker -----------------------------------
mkdir -p "$WORK/nomarker"
assert_ne "$(guard_rc "$WORK/nomarker")" "0" "a testbed without the marker is refused"
assert_contains "$(guard "$WORK/nomarker")" ".palwarden-live-testbed" \
  "the refusal names the marker file, so the operator knows what to create"

# --- refuses a directory that does not exist at all -----------------------
assert_ne "$(guard_rc "$WORK/absent")" "0" "an absent testbed is refused"
# The checks are ordered, and the order is part of the contract: a path that is
# simply not there must be reported as that, not as a uid problem. Without this
# pair the ordering is unfalsifiable — every check still refuses in every case,
# just with the wrong explanation, and "wrong explanation" is precisely what
# sends an operator chasing a permission bug that does not exist.
assert_contains "$(guard "$WORK/absent")" "does not exist" \
  "the absent-testbed refusal reports the missing directory"
assert_not_contains "$(guard "$WORK/absent")" "uid" \
  "a missing directory is not reported as a uid problem"

# --- refuses when the marker exists but the game is not installed ---------
mkdir -p "$WORK/bare"; : > "$WORK/bare/.palwarden-live-testbed"
assert_ne "$(guard_rc "$WORK/bare")" "0" "a marked testbed with no install is refused"
assert_contains "$(guard "$WORK/bare")" "UPDATE_ON_START" \
  "the refusal points at the one-time install step"

# --- accepts a marked testbed with an install present ---------------------
mkdir -p "$WORK/ok/server"; : > "$WORK/ok/.palwarden-live-testbed"
printf '#!/bin/sh\n' > "$WORK/ok/server/PalServer.sh"; chmod +x "$WORK/ok/server/PalServer.sh"
assert_eq "$(guard_rc "$WORK/ok")" "0" "a marked, installed testbed is accepted"

# --- refuses a uid mismatch ------------------------------------------------
# The container's steam account is uid 1000. A bind mount owned by anyone else means
# the game cannot write its own save, and this repo has already broken CI once on a
# uid 1000-vs-1001 mismatch — so it is refused up front with the expected uid named,
# rather than surfacing later as a permission error inside the game.
out="$( PALWARDEN_LIVE_TESTBED="$WORK/ok" PALWARDEN_LIVE_EXPECT_UID=65534 \
        bash -c 'source "$0" >/dev/null 2>&1; live_require_testbed' "$LIB" 2>&1 )"
rc=$?
assert_ne "$rc" "0" "a uid mismatch is refused"
assert_contains "$out" "65534" "the refusal names the uid it expected"

assert_report
