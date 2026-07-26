#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Unit tests for the container `sudo` passthrough shim.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
SUDO="$DIR/../../docker/shims/sudo"

# Plain command passthrough.
assert_eq "$("$SUDO" echo hello)" "hello" "plain passthrough"

# Value-less flags are stripped.
assert_eq "$("$SUDO" -n echo hi)" "hi" "-n stripped"
assert_rc 0 "$SUDO" -n true

# -u USER (option + value) is stripped, command still runs.
assert_eq "$("$SUDO" -u someuser echo world)" "world" "-u USER stripped"

# `sudo -n true` reduced to a command that succeeds.
assert_rc 0 "$SUDO" -n true

# Exit code of the wrapped command is propagated.
assert_rc 3 "$SUDO" bash -c 'exit 3'

# Only-options (no command) succeeds quietly.
assert_rc 0 "$SUDO" -n

assert_report
