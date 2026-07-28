#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden test runner.
#
#   ./tests/run.sh              # unit tests only
#   ./tests/run.sh --integration# unit + docker integration tests
#   ./tests/run.sh --live       # + suites against a REAL Palworld server
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
  # Points at the overlay's header comment, which documents the testbed, the marker
  # and the one-time install in full. docs/tools.md documents no test tier at all
  # (not even RUN_INTEGRATION); repoint this line there once Task 4 adds one.
  echo "(live tests skipped; pass --live to run them — needs a real server, see docker/compose.live.yaml)"
fi

echo
if [[ "$failed" == "0" ]]; then echo "ALL SUITES PASSED"; else echo "SOME SUITES FAILED"; fi
exit "$failed"
