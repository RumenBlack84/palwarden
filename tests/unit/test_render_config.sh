#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Unit tests for palwarden-render-config: env -> settings.env / notify.env.
# We assert the real contract: sourcing the output yields the right values
# (the files are consumed via `source` by palworld-api / config-apply-env).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
RENDER="$DIR/../../docker/palwarden-render-config"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() { local s="$1" n="$2"; shift 2; env "$@" bash "$RENDER" "$s" "$n"; }
# value of KEY after sourcing FILE (empty string if unset)
val() { ( set -a; source "$1" 2>/dev/null; printf '%s' "${!2:-}" ); }
# whether KEY is set at all after sourcing FILE
isset() { ( set -a; source "$1" 2>/dev/null; [ -n "${!2+x}" ] && echo yes || echo no ); }

# --- embedded with ADMIN_PASSWORD: REST connection for localhost -------------
s="$WORK/s1"; n="$WORK/n1"
render "$s" "$n" PALWARDEN_MODE=embedded ADMIN_PASSWORD=secret123 >/dev/null
assert_eq "$(val "$s" REST_API_ENABLED)" "True"      "embedded enables REST"
assert_eq "$(val "$s" REST_API_HOST)"    "127.0.0.1" "embedded targets localhost"
assert_eq "$(val "$s" REST_API_PORT)"    "8212"      "default REST port"
assert_eq "$(val "$s" ADMIN_PASSWORD)"   "secret123" "admin password written"

# secrets file should be private (0600)
perms="$(stat -c '%a' "$s" 2>/dev/null || stat -f '%Lp' "$s" 2>/dev/null)"
assert_eq "$perms" "600" "settings.env is 0600"

# --- external: REST host is the target --------------------------------------
s="$WORK/s2"; n="$WORK/n2"
render "$s" "$n" PALWARDEN_MODE=external PALWORLD_TARGET_HOST=palbox.example ADMIN_PASSWORD=pw PALWORLD_REST_PORT=9999 >/dev/null
assert_eq "$(val "$s" REST_API_HOST)" "palbox.example" "external targets remote host"
assert_eq "$(val "$s" REST_API_PORT)" "9999"           "custom REST port"

# --- PALWORLD_CFG_* passthrough (values with spaces must survive) ------------
s="$WORK/s3"; n="$WORK/n3"
render "$s" "$n" PALWARDEN_MODE=embedded ADMIN_PASSWORD=x \
  PALWORLD_CFG_SERVER_NAME="Yggdrasil Palworld" \
  PALWORLD_CFG_MAX_PLAYERS=32 >/dev/null
assert_eq "$(val "$s" SERVER_NAME)" "Yggdrasil Palworld" "server name with space survives"
assert_eq "$(val "$s" MAX_PLAYERS)" "32"                 "max players passthrough"

# --- password with shell metacharacters round-trips safely ------------------
s="$WORK/s6"; n="$WORK/n6"
render "$s" "$n" PALWARDEN_MODE=embedded ADMIN_PASSWORD='p$a b`c"d' >/dev/null
assert_eq "$(val "$s" ADMIN_PASSWORD)" 'p$a b`c"d' "special-char password round-trips"

# --- Discord webhook -> notify.env ------------------------------------------
s="$WORK/s4"; n="$WORK/n4"
render "$s" "$n" DISCORD_WEBHOOK="https://discord/hook" PALWORLD_NOTIFY_NAME="Ygg" >/dev/null
assert_eq "$(val "$n" PALWORLD_DISCORD_WEBHOOK)" "https://discord/hook" "webhook written"
assert_eq "$(val "$n" PALWORLD_NOTIFY_NAME)"     "Ygg"                  "notify name written"

# --- no ADMIN_PASSWORD: no REST enable (telemetry stays off) ----------------
s="$WORK/s5"; n="$WORK/n5"
render "$s" "$n" PALWARDEN_MODE=embedded >/dev/null
assert_eq "$(isset "$s" REST_API_ENABLED)" "no" "no REST enable without password"

assert_report
