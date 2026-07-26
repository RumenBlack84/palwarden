#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Credential handling for palwarden-webui. The server must fail closed: no
# credentials means no serving, and generation must never clobber an existing
# file (that would lock the operator out of their own panel).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
WEBUI="$DIR/../../sbin/palwarden-webui"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ENVF="$WORK/webui.env"

run_webui() { PALWARDEN_WEBUI_ENV="$ENVF" python3 "$WEBUI" "$@"; }

# --- generation ------------------------------------------------------------
out="$(run_webui --init-credentials 2>&1)"; rc=$?
assert_eq "$rc" "0" "init-credentials exits 0"
assert_rc 0 test -f "$ENVF"
perms="$(stat -c '%a' "$ENVF")"
assert_eq "$perms" "600" "credential file is 0600"
assert_file_contains "$ENVF" "WEBUI_USER=" "user recorded"
assert_file_contains "$ENVF" "WEBUI_PASSWORD=" "password recorded"
assert_file_contains "$ENVF" "WEBUI_TOKEN=" "token recorded"
assert_contains "$out" "WEBUI_PASSWORD" "prints the credentials once, on creation"

# generated secrets must not be trivial
pw="$(grep '^WEBUI_PASSWORD=' "$ENVF" | cut -d= -f2- | tr -d '"')"
tok="$(grep '^WEBUI_TOKEN=' "$ENVF" | cut -d= -f2- | tr -d '"')"
if [ "${#pw}" -ge 16 ]; then pass; else fail "password too short: ${#pw}"; fi
if [ "${#tok}" -ge 16 ]; then pass; else fail "token too short: ${#tok}"; fi
assert_ne "$pw" "$tok" "password and token differ"

# --- idempotence: must not overwrite --------------------------------------
before="$(cat "$ENVF")"
out2="$(run_webui --init-credentials 2>&1)"
assert_eq "$(cat "$ENVF")" "$before" "existing credentials are preserved"
assert_not_contains "$out2" "$pw" "does not reprint secrets when they already exist"

# --- explicit values are honoured (so operators can set their own) --------
ENVF2="$WORK/preset.env"
PALWARDEN_WEBUI_ENV="$ENVF2" WEBUI_USER=ygg WEBUI_PASSWORD=chosen-password \
  WEBUI_TOKEN=chosen-token python3 "$WEBUI" --init-credentials >/dev/null 2>&1
assert_file_contains "$ENVF2" 'WEBUI_USER="ygg"' "honours WEBUI_USER"
assert_file_contains "$ENVF2" 'WEBUI_PASSWORD="chosen-password"' "honours WEBUI_PASSWORD"

# --- fail closed on a missing or incomplete file --------------------------
out="$(PALWARDEN_WEBUI_ENV="$WORK/nope.env" python3 "$WEBUI" --serve 2>&1)"; rc=$?
assert_ne "$rc" "0" "serving without credentials exits nonzero"
assert_contains "$out" "credentials" "explains that credentials are missing"
assert_not_contains "$out" "Traceback" "no traceback on missing credentials"

printf 'WEBUI_USER="admin"\nWEBUI_PASSWORD=""\nWEBUI_TOKEN="t"\n' > "$WORK/empty.env"
out="$(PALWARDEN_WEBUI_ENV="$WORK/empty.env" python3 "$WEBUI" --serve 2>&1)"; rc=$?
assert_ne "$rc" "0" "empty password is rejected"
assert_not_contains "$out" "Traceback" "no traceback on empty password"

assert_report
