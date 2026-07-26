#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Minimal assertion helpers for palwarden's test suites. No external deps.
# Each test script sources this, makes assertions, and ends with `assert_report`
# (which exits nonzero if any assertion failed).

_ASSERT_PASS=0
_ASSERT_FAIL=0

pass() { _ASSERT_PASS=$((_ASSERT_PASS + 1)); }
fail() { _ASSERT_FAIL=$((_ASSERT_FAIL + 1)); printf '  FAIL: %s\n' "$*" >&2; }

# assert_eq <actual> <expected> [msg]
assert_eq() { if [ "$1" = "$2" ]; then pass; else fail "${3:-values differ}: expected '$2', got '$1'"; fi; }
# assert_ne <a> <b> [msg]
assert_ne() { if [ "$1" != "$2" ]; then pass; else fail "${3:-should differ}: both '$1'"; fi; }
# assert_contains <haystack> <needle> [msg]
assert_contains() { case "$1" in *"$2"*) pass ;; *) fail "${3:-missing substring}: '$2' not in '$1'" ;; esac; }
# assert_not_contains <haystack> <needle> [msg]
assert_not_contains() { case "$1" in *"$2"*) fail "${3:-unexpected substring}: '$2' in '$1'" ;; *) pass ;; esac; }
# assert_file_contains <file> <needle> [msg]
assert_file_contains() { if grep -qF -- "$2" "$1" 2>/dev/null; then pass; else fail "${3:-file check}: '$1' missing '$2'"; fi; }
# assert_file_not_contains <file> <needle> [msg]
assert_file_not_contains() { if grep -qF -- "$2" "$1" 2>/dev/null; then fail "${3:-file check}: '$1' contains '$2'"; else pass; fi; }
# assert_rc <expected_rc> <cmd...>
assert_rc() { local exp="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?; if [ "$rc" = "$exp" ]; then pass; else fail "rc: expected $exp, got $rc for: $*"; fi; }

assert_report() {
  printf '  %d passed, %d failed\n' "$_ASSERT_PASS" "$_ASSERT_FAIL"
  [ "$_ASSERT_FAIL" -eq 0 ]
}
