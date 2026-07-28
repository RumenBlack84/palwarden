#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palworld-api's *exit codes*, which nothing asserted until now — and that is why a
# wrong one survived to a review.
#
# Two callers read the code and not just "did it work":
#
#   * palworld-graceful-restart's readiness loops (both branches) stop on 2 rather
#     than polling to the startup deadline;
#   * palworld-restore's _confirm_startup maps 2 to "readiness unverifiable" (the
#     world was still restored) and anything else to "keep retrying until the
#     deadline, then fail the restore".
#
# So the contract is: **2 means not configured** — no settings.env, REST disabled,
# or no ADMIN_PASSWORD — and waiting cannot change the answer. **1 means something
# went wrong that might not be permanent** (a transport failure) or is fixable (a
# settings.env that exists but cannot be read). Getting the missing-file case wrong
# cost a restore on a rebuilt host 180s of polling and then a false failure report,
# in the one scenario the feature exists for.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
API="$DIR/../../sbin/palworld-api"

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

CFG="$WORK/settings.env"
api() { env PALWORLD_SETTINGS_ENV="$CFG" bash "$API" "$@"; }

# --- not configured: exit 2, in all three shapes ------------------------------
# Absent. This is the rebuilt-host case: the world is being restored precisely
# because nothing local has been set up yet.
rm -f "$CFG"
out="$(api info 2>&1)"; rc=$?
assert_eq "$rc" "2" "a missing settings.env exits 2 (not configured), not 1 (output: $out)"
assert_contains "$out" "does not exist" "the message says the file is not there"

# Present, but REST is switched off.
printf 'REST_API_ENABLED=False\nADMIN_PASSWORD=x\n' > "$CFG"
out="$(api info 2>&1)"; rc=$?
assert_eq "$rc" "2" "REST_API_ENABLED=False exits 2 (output: $out)"
assert_contains "$out" "REST API is not enabled" "the message names the disabled API"

# Present and enabled, but no password to authenticate with.
printf 'REST_API_ENABLED=True\nADMIN_PASSWORD=\n' > "$CFG"
out="$(api info 2>&1)"; rc=$?
assert_eq "$rc" "2" "an empty ADMIN_PASSWORD exits 2 (output: $out)"
assert_contains "$out" "ADMIN_PASSWORD is not set" "the message names the missing password"

# --- present but unreadable: exit 1, deliberately NOT 2 -----------------------
# A permission problem on a file that IS configured is fixable and must surface as
# an error, rather than being reported as "the REST API isn't set up" and skipped.
if [ "$(id -u)" = "0" ]; then
  echo "  (note: running as root; skipping the unreadable-settings case)"
else
  printf 'REST_API_ENABLED=True\nADMIN_PASSWORD=x\n' > "$CFG"
  chmod 000 "$CFG"
  out="$(api info 2>&1)"; rc=$?
  chmod 600 "$CFG"
  assert_eq "$rc" "1" "an unreadable settings.env exits 1, not 2 (output: $out)"
  assert_contains "$out" "Cannot read" "the message distinguishes unreadable from absent"
fi

# --- a transport failure: exit 1, so callers keep retrying --------------------
# Fully configured and pointed at a port with nothing on it: this is the shape that
# must NOT be 2, because a server still starting up looks exactly like this and the
# retry loop is what waits for it.
printf 'REST_API_ENABLED=True\nADMIN_PASSWORD=x\nREST_API_PORT=1\nREST_API_HOST=127.0.0.1\n' > "$CFG"
out="$(api info 2>&1)"; rc=$?
assert_eq "$rc" "1" "an unreachable REST API exits 1 so the caller retries (output: $out)"

# --- usage: 64, and distinct from both -----------------------------------------
printf 'REST_API_ENABLED=True\nADMIN_PASSWORD=x\n' > "$CFG"
out="$(api not-an-action 2>&1)"; rc=$?
assert_eq "$rc" "64" "an unknown action exits 64 (output: $out)"

# --- and the callers that depend on these codes still say so -------------------
# Both branches of the readiness wait, so the bare-metal one cannot quietly lose the
# check again: it polled to the deadline on a REST API that was merely disabled.
sed -n '/PALWARDEN_CONTAINER/,/^fi$/p' \
  "$DIR/../../sbin/palworld-graceful-restart" > "$WORK/container-branch.txt"
assert_file_contains "$WORK/container-branch.txt" "-eq 2" \
  "the container readiness wait still stops on exit 2"
# The bare-metal loop lives after that block; take the rest of the file.
sed -n '/# Wait for API readiness/,$p' \
  "$DIR/../../sbin/palworld-graceful-restart" > "$WORK/metal-branch.txt"
assert_file_contains "$WORK/metal-branch.txt" "api_rc == 2" \
  "the bare-metal readiness wait stops on exit 2 too"
assert_file_contains "$WORK/metal-branch.txt" "REST API not configured" \
  "...and says that is why it did not wait"

assert_report
