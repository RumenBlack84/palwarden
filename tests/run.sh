#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden test runner.
#
#   ./tests/run.sh              # unit tests only
#   ./tests/run.sh --integration# unit + docker integration tests
#   ./tests/run.sh --live       # + suites against a REAL Palworld server
#   ./tests/run.sh --reset-world# wipe the live testbed's world, then exit
#   RUN_INTEGRATION=1 ./tests/run.sh
#   RUN_LIVE=1 ./tests/run.sh
#
# Unit tests are fast and dependency-free. Integration tests build the Docker
# image and exercise container scenarios (require docker). Live tests need a real
# game install on a marked, disposable testbed — a one-time multi-GB SteamCMD
# download — so they are off by default; see tests/live/lib/testbed.sh.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

want_integration=0
[[ "${RUN_INTEGRATION:-0}" == "1" ]] && want_integration=1
for a in "$@"; do [[ "$a" == "--integration" ]] && want_integration=1; done

want_live=0
[[ "${RUN_LIVE:-0}" == "1" ]] && want_live=1
for a in "$@"; do [[ "$a" == "--live" ]] && want_live=1; done

# --reset-world is the live tier's escape hatch, not a test mode: world drift is
# accepted there, so the only recovery needed is throwing the cheap half away and
# keeping the expensive install. It runs the guard first (so it can never fire at an
# unmarked directory) and exits without running any suite, because mixing a
# destructive reset into a test run is how someone loses a world they meant to keep.
for a in "$@"; do
  if [[ "$a" == "--reset-world" ]]; then
    # shellcheck source=tests/live/lib/testbed.sh
    source "$DIR/live/lib/testbed.sh"
    live_require_testbed
    live_reset_world
    exit 0
  fi
done

failed=0
run_file() {
  local f="$1"
  echo "== ${f#"$DIR"/} =="
  if bash "$f"; then :; else failed=1; echo "  -> FAILED"; fi
}

echo "### unit tests ###"
for f in "$DIR"/unit/test_*.sh; do
  [[ -e "$f" ]] || continue
  run_file "$f"
done

if [[ "$want_integration" == "1" ]]; then
  echo
  echo "### integration tests ###"
  if command -v docker >/dev/null 2>&1; then
    for f in "$DIR"/integration/test_*.sh; do
      [[ -e "$f" ]] || continue
      run_file "$f"
    done
  else
    echo "docker not available — skipping integration tests"
  fi
else
  echo
  echo "(integration tests skipped; pass --integration to run them)"
fi

# Same shape as the gate above, deliberately: off unless asked, and when skipped it
# names how to enable it — a tier nobody knows exists is a tier nobody runs.
if [[ "$want_live" == "1" ]]; then
  echo
  echo "### live tests ###"
  if command -v docker >/dev/null 2>&1; then
    for f in "$DIR"/live/test_*.sh; do
      [[ -e "$f" ]] || continue
      run_file "$f"
    done
  else
    echo "docker not available — skipping live tests"
  fi
else
  echo
  # Points at docs/tools.md's "Test tiers" section, which documents all three
  # tiers, the testbed, the marker, the one-time install and the recovery step in
  # one place. (It used to point at docker/compose.live.yaml's header comment,
  # because that section did not exist yet.)
  echo "(live tests skipped; pass --live to run them — needs a real server, see docs/tools.md#test-tiers)"
fi

echo
if [[ "$failed" == "0" ]]; then echo "ALL SUITES PASSED"; else echo "SOME SUITES FAILED"; fi
exit "$failed"
