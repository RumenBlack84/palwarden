#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Unit tests for palworld-public-info-watch: reads the server config, resolves
# the public IP, and writes the join-info state file. Fakes `curl` (public IP)
# and `sudo` (passthrough), and uses temp config/state paths.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
SCRIPT="$DIR/../../sbin/palworld-public-info-watch"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "203.0.113.5"
EOF
cat > "$WORK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$WORK/bin/curl" "$WORK/bin/sudo"

cat > "$WORK/config.ini" <<'EOF'
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(ServerName="Ygg",ServerPassword="hunter2",PublicPort=8888,RESTAPIEnabled=True)
EOF

state="$WORK/state.env"
PATH="$WORK/bin:$PATH" \
  PALWORLD_CONFIG_FILE="$WORK/config.ini" \
  PALWORLD_PUBLIC_INFO_FILE="$state" \
  PUBLIC_HOSTNAME="pal.example" \
  bash "$SCRIPT" >/dev/null 2>&1 || true   # notify may be a no-op/undefined; state is written first

assert_file_contains "$state" "PUBLIC_IP=203.0.113.5" "public IP detected"
assert_file_contains "$state" "SERVER_PORT=8888"       "public port read from config"
assert_file_contains "$state" "SERVER_PASSWORD=hunter2" "server password read from config"
assert_file_contains "$state" "HOSTNAME=pal.example"   "hostname from PUBLIC_HOSTNAME"

# Second run with no change -> no rewrite (mtime unchanged)
before="$(stat -c '%Y' "$state" 2>/dev/null || stat -f '%m' "$state")"
sleep 1
PATH="$WORK/bin:$PATH" PALWORLD_CONFIG_FILE="$WORK/config.ini" \
  PALWORLD_PUBLIC_INFO_FILE="$state" PUBLIC_HOSTNAME="pal.example" \
  bash "$SCRIPT" >/dev/null 2>&1 || true
after="$(stat -c '%Y' "$state" 2>/dev/null || stat -f '%m' "$state")"
assert_eq "$after" "$before" "no rewrite when join info is unchanged"

# Hostname falls back to the public IP when PUBLIC_HOSTNAME is unset
state2="$WORK/state2.env"
PATH="$WORK/bin:$PATH" PALWORLD_CONFIG_FILE="$WORK/config.ini" \
  PALWORLD_PUBLIC_INFO_FILE="$state2" \
  bash "$SCRIPT" >/dev/null 2>&1 || true
assert_file_contains "$state2" "HOSTNAME=203.0.113.5" "hostname falls back to public IP"

assert_report
