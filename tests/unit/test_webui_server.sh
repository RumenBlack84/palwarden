#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden-webui: auth on every path (the static editors included), safe static
# serving, and the read-only API. Uses stub tools so no real server is needed.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
WEBUI="$DIR/../../sbin/palwarden-webui"

WORK="$(mktemp -d)"
PORT=18099
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture: web root, credentials, stub tools ---------------------------
mkdir -p "$WORK/webroot" "$WORK/sbin" "$WORK/cfg"
echo '<html><body>PALWARDEN DASHBOARD</body></html>' > "$WORK/webroot/palwarden.html"
echo '<html>vendored editor</html>' > "$WORK/webroot/PalWorldSettingsEditor.html"
echo 'SECRET-HOST-FILE' > "$WORK/secret-outside-webroot.txt"

printf 'WEBUI_USER="admin"\nWEBUI_PASSWORD="pw-for-tests"\nWEBUI_TOKEN="tok-for-tests"\n' \
  > "$WORK/webui.env"

cat > "$WORK/sbin/palworld-health-report" <<'EOF'
#!/usr/bin/env bash
echo '{"service":{"active_state":"active"},"buildid":"12345"}'
EOF
cat > "$WORK/sbin/palworld-fps" <<'EOF'
#!/usr/bin/env bash
echo '{"windows":{"24h":{"avg":59.5}}}'
EOF
cat > "$WORK/sbin/palworld-service-events" <<'EOF'
#!/usr/bin/env bash
echo '{"restarts":2,"unexpected":1,"outages":0}'
EOF
cat > "$WORK/sbin/palworld-engine-config" <<'EOF'
#!/usr/bin/env bash
echo "Engine.ini check OK: managed values match /etc/palworld/engine.env."
EOF
cat > "$WORK/sbin/palworld-broken-tool" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2; exit 3
EOF
chmod +x "$WORK/sbin/"*

# a config file with a secret to prove redaction
printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(ServerName="Ygg",AdminPassword="hunter-would-be-bad",PublicPort=8211)\n' \
  > "$WORK/cfg/PalWorldSettings.ini"

# --- start the server ------------------------------------------------------
PALWARDEN_WEBUI_ENV="$WORK/webui.env" \
PALWARDEN_WEBUI_ROOT="$WORK/webroot" \
PALWARDEN_WEBUI_BIND=127.0.0.1 \
PALWARDEN_WEBUI_PORT="$PORT" \
PALWARDEN_SBIN_DIR="$WORK/sbin" \
PALWARDEN_PARSER_BIN="$DIR/../../bin/palworld-config-parser" \
PALWORLD_CONFIG_FILE="$WORK/cfg/PalWorldSettings.ini" \
  python3 "$WEBUI" --serve >"$WORK/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.25
done

U="http://127.0.0.1:$PORT"
CREDS="admin:pw-for-tests"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }

# --- auth is required for EVERYTHING, static pages included ---------------
assert_eq "$(code "$U/")" "401" "dashboard requires auth"
assert_eq "$(code "$U/PalWorldSettingsEditor.html")" "401" "vendored editor requires auth"
assert_eq "$(code "$U/api/health")" "401" "API requires auth"
hdrs="$(curl -s -D - -o /dev/null "$U/")"
assert_contains "$hdrs" "WWW-Authenticate" "sends a Basic challenge"
assert_eq "$(code -u "admin:wrong-password" "$U/")" "401" "wrong password rejected"
assert_eq "$(code -u "wrong-user:pw-for-tests" "$U/")" "401" "wrong user rejected"

# --- authenticated static serving -----------------------------------------
assert_eq "$(code -u "$CREDS" "$U/")" "200" "authenticated root is served"
assert_contains "$(body -u "$CREDS" "$U/")" "PALWARDEN DASHBOARD" "root serves the dashboard"
assert_eq "$(code -u "$CREDS" "$U/PalWorldSettingsEditor.html")" "200" "editor is served"

# --- traversal must not escape the web root -------------------------------
assert_ne "$(code -u "$CREDS" "$U/../secret-outside-webroot.txt")" "200" "no parent traversal"
assert_not_contains "$(body -u "$CREDS" "$U/../secret-outside-webroot.txt")" "SECRET-HOST-FILE" "traversal leaks nothing"
assert_ne "$(code -u "$CREDS" "$U/..%2fsecret-outside-webroot.txt")" "200" "no encoded traversal"
assert_eq "$(code -u "$CREDS" "$U/does-not-exist.html")" "404" "missing file is 404"

# --- read API --------------------------------------------------------------
assert_eq "$(code -u "$CREDS" "$U/api/health")" "200" "health is served"
assert_contains "$(body -u "$CREDS" "$U/api/health")" '"buildid"' "health returns tool JSON"
assert_contains "$(body -u "$CREDS" "$U/api/fps?window=24h")" '"avg"' "fps returns tool JSON"
assert_contains "$(body -u "$CREDS" "$U/api/service-events")" '"unexpected"' "service events returned"
assert_contains "$(body -u "$CREDS" "$U/api/engine")" '"drift_ok"' "engine drift reported"

# config is redacted
cfg="$(body -u "$CREDS" "$U/api/config")"
assert_contains "$cfg" '"ServerName"' "config exposes normal keys"
assert_contains "$cfg" "<redacted>" "config redacts secrets"
assert_not_contains "$cfg" "hunter-would-be-bad" "the admin password never leaves the host"

# a rejected window falls back rather than passing junk to the tool
assert_eq "$(code -u "$CREDS" "$U/api/fps?window=;rm%20-rf%20/")" "200" "hostile window is sanitised"

# --- mutations are not available in this increment ------------------------
assert_eq "$(code -u "$CREDS" -X POST "$U/api/jobs")" "501" "POST /api/jobs is not implemented yet"

# --- nothing sensitive in the log ----------------------------------------
assert_not_contains "$(cat "$WORK/server.log")" "pw-for-tests" "password never logged"
assert_not_contains "$(cat "$WORK/server.log")" "tok-for-tests" "token never logged"

# --- the real dashboard page is what gets served at / ---------------------
REAL_ROOT="$DIR/../../webui"
assert_rc 0 test -f "$REAL_ROOT/palwarden.html"
assert_file_contains "$REAL_ROOT/palwarden.html" 'id="palwarden-dashboard"' "has the dashboard root element"
assert_file_contains "$REAL_ROOT/palwarden.html" "/api/health" "fetches health"
assert_file_contains "$REAL_ROOT/palwarden.html" "sessionStorage" "keeps the token in sessionStorage"
# the shared component vocabulary from the design spec, so later pages can reuse it
assert_file_contains "$REAL_ROOT/palwarden.html" "--pw-bg" "declares the design tokens"
assert_file_contains "$REAL_ROOT/palwarden.html" "pw-card" "uses the card component"
assert_file_contains "$REAL_ROOT/palwarden.html" "pw-pill--ok" "uses state pills"
# it must not ship a hardcoded credential
assert_file_not_contains "$REAL_ROOT/palwarden.html" "WEBUI_PASSWORD" "no credential baked into the page"
# and the vendored editors must remain untouched
assert_rc 0 git -C "$DIR/../.." diff --quiet -- webui/PalWorldSettingsEditor.html webui/EngineIniPerformanceEditor.html

assert_report
