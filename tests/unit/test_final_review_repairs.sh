#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
# Isolated safety regressions for the final five idle/knock review findings.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
if python3 "$DIR/../fixtures/idle-review-repairs.py"; then
  pass "final idle/knock review safety regressions"
else
  fail "final idle/knock review safety regressions"
fi
assert_report
