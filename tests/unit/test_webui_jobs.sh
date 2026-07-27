#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# POST /api/jobs is the only mutating surface of the web UI, and it runs in the
# UNPRIVILEGED process — it may only ever write a job file. So this suite is
# mostly about what must be *refused*: Basic auth alone (a browser hands it to a
# cross-origin POST for free), a cross-site Origin/Sec-Fetch-Site, an action or
# parameter the root worker would not accept, and a second disruptive job while
# one is still pending. Anything hostile must produce a status code, never a
# traceback and never a dead server.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
REPO="$DIR/../.."
WEBUI="$REPO/sbin/palwarden-webui"

WORK="$(mktemp -d)"
PORT=18097
PORT_RO=18096
PID=""
PID_RO=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  [ -n "$PID_RO" ] && kill "$PID_RO" 2>/dev/null
  chmod u+w "$WORK/nowrite" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- fixture: same shape as test_webui_server.sh ---------------------------
mkdir -p "$WORK/webroot" "$WORK/sbin" "$WORK/cfg" "$WORK/backups"
echo '<html><body>PALWARDEN DASHBOARD</body></html>' > "$WORK/webroot/palwarden.html"

printf 'WEBUI_USER="admin"\nWEBUI_PASSWORD="pw-for-tests"\nWEBUI_TOKEN="tok-for-tests"\n' \
  > "$WORK/webui.env"

# Stubs for the read API only. The *job* actions are never executed here: this
# process must not be able to run them, which is the whole point.
cat > "$WORK/sbin/palworld-health-report" <<'EOF'
#!/usr/bin/env bash
echo '{"service":{"active_state":"active"}}'
EOF
chmod +x "$WORK/sbin/"*
printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(ServerName="Ygg")\n' \
  > "$WORK/cfg/PalWorldSettings.ini"

# A real rollback source, so engine_rollback's validator has something valid to
# accept and we can prove a *forged* name is still refused.
: > "$WORK/backups/Engine.ini.20260101T000000Z"

# raw request sender: the only way to exercise a missing, negative or
# non-integer Content-Length, or a duplicated header, since curl builds those
# itself. Prints the status code, or 000 if the server closed/timed out.
cat > "$WORK/raw.py" <<'EOF'
import socket
import sys

port, path = int(sys.argv[1]), sys.argv[2]
with open(path, "rb") as fh:
    request = fh.read()
data = b""
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=4)
except OSError:
    print("000")
    raise SystemExit(0)
try:
    sock.sendall(request)
    while b"\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
except OSError:
    data = b""
finally:
    sock.close()
parts = data.split(b"\r\n")[0].decode("latin-1", "replace").split(" ")
print(parts[1] if len(parts) > 1 else "000")
EOF

start_server() {  # start_server <port> <jobs-dir> <logfile>
  PALWARDEN_WEBUI_ENV="$WORK/webui.env" \
  PALWARDEN_WEBUI_ROOT="$WORK/webroot" \
  PALWARDEN_WEBUI_BIND=127.0.0.1 \
  PALWARDEN_WEBUI_PORT="$1" \
  PALWARDEN_JOBS_DIR="$2" \
  PALWARDEN_SBIN_DIR="$WORK/sbin" \
  PALWARDEN_PARSER_BIN="$REPO/bin/palworld-config-parser" \
  PALWORLD_CONFIG_FILE="$WORK/cfg/PalWorldSettings.ini" \
  PALWORLD_ENGINE_ENV="$WORK/engine.env" \
  PALWORLD_BACKUP_DIR="$WORK/backups" \
    python3 "$WEBUI" --serve >"$3" 2>&1 &
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "http://127.0.0.1:$1/" && return 0
    sleep 0.25
  done
}

start_server "$PORT" "$WORK/jobs" "$WORK/server.log"
PID=$!

U="http://127.0.0.1:$PORT"
CREDS="admin:pw-for-tests"
TOKHDR="X-Palwarden-Token: tok-for-tests"
B64="$(printf 'admin:pw-for-tests' | base64 | tr -d '\n')"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }
# a fully-credentialled POST; only the JSON body varies
post_json() {
  code -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
    --data-binary "$1" "$U/api/jobs"
}
post_body() {
  body -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
    --data-binary "$1" "$U/api/jobs"
}
raw() { python3 "$WORK/raw.py" "$PORT" "$1"; }

# --- the CSRF defence: Basic auth alone must never mutate ------------------
assert_eq "$(code -u "$CREDS" -X POST -H 'Content-Type: application/json' \
  -d '{"action":"backup"}' "$U/api/jobs")" "403" "Basic alone cannot enqueue"
assert_eq "$(code -u "$CREDS" -H 'X-Palwarden-Token: wrong' -X POST \
  -H 'Content-Type: application/json' -d '{"action":"backup"}' "$U/api/jobs")" "403" \
  "wrong token refused"
# missing credentials is 401 (with a challenge), NOT 403: the client must be told
# to authenticate rather than that it is forbidden.
assert_eq "$(code -X POST -d '{"action":"backup"}' "$U/api/jobs")" "401" "no auth is 401"
assert_contains "$(curl -s -D - -o /dev/null -X POST -d '{"action":"backup"}' "$U/api/jobs")" \
  "WWW-Authenticate" "unauthenticated POST still gets a challenge"
# a bad password with a *good* token is still 401: the token is an extra factor,
# never a substitute for authentication.
assert_eq "$(code -u "admin:wrong-password" -H "$TOKHDR" -X POST \
  -d '{"action":"backup"}' "$U/api/jobs")" "401" "token does not replace the password"

# --- with both factors it enqueues ----------------------------------------
enq="$(post_body '{"action":"backup"}')"
assert_contains "$enq" '"id"' "token header enqueues"
BACKUP_ID="$(printf '%s' "$enq" | sed -n 's/.*"id": *"\([0-9a-f]*\)".*/\1/p')"
assert_eq "${#BACKUP_ID}" "32" "the response carries a 32-hex job id"
# the queue directory is created owner-only: job params can carry config values
assert_eq "$(stat -c %a "$WORK/jobs")" "700" "queue directory is 0700"

# --- cross-origin requests are refused even with both factors --------------
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Sec-Fetch-Site: cross-site' -X POST \
  -H 'Content-Type: application/json' -d '{"action":"backup"}' "$U/api/jobs")" "403" \
  "cross-site request refused"
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Sec-Fetch-Site: same-site' -X POST \
  -H 'Content-Type: application/json' -d '{"action":"backup"}' "$U/api/jobs")" "403" \
  "same-site (a sibling subdomain) is refused too"
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Origin: http://evil.example' -X POST \
  -H 'Content-Type: application/json' -d '{"action":"backup"}' "$U/api/jobs")" "403" \
  "foreign Origin refused"
# DNS rebinding: the attacker's name resolves to 127.0.0.1, so Host matches the
# tunnel — the Origin host is what gives it away.
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Origin: http://rebind.example:18097' \
  -H "Host: 127.0.0.1:$PORT" -X POST -H 'Content-Type: application/json' \
  -d '{"action":"backup"}' "$U/api/jobs")" "403" "rebound Origin refused despite a matching Host"
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Origin: null' -X POST \
  -H 'Content-Type: application/json' -d '{"action":"backup"}' "$U/api/jobs")" "403" \
  "opaque (null) Origin refused"
# a loopback Origin on any port is fine: an SSH tunnel remaps the port, so
# pinning it would break the documented access path.
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" \
  -H "Origin: http://localhost:9999" -H 'Sec-Fetch-Site: same-origin' -X POST \
  -H 'Content-Type: application/json' -d '{"action":"backup"}' "$U/api/jobs")" "202" \
  "loopback Origin on a tunnelled port is accepted"

# --- bad requests are 400, with a reason -----------------------------------
assert_eq "$(post_json '{"action":"nope"}')" "400" "unknown action rejected"
assert_contains "$(post_body '{"action":"nope"}')" "not an allowed action" "400 says why"
assert_eq "$(post_json 'not json')" "400" "malformed body rejected"
assert_eq "$(post_json '[]')" "400" "a non-object body is rejected"
assert_eq "$(post_json '{"action":123}')" "400" "a non-string action is rejected"
assert_eq "$(post_json '{"action":"backup","params":[]}')" "400" "non-object params rejected"
assert_eq "$(post_json '{"action":"snapshot_create","params":{"label":"; rm -rf /"}}')" "400" \
  "hostile label rejected at the API"
assert_eq "$(post_json '{"action":"mark","params":{"text":"ok"},"confirm":true}')" "202" \
  "a valid non-disruptive action is accepted"
# the API uses the worker's own validators, so a forged rollback name dies here
assert_eq "$(post_json '{"action":"engine_rollback","params":{"backup":"../../etc/shadow","confirm":true}}')" \
  "400" "forged rollback source rejected at the API"
# settings values may be str/int/float but never bool (contract settled with the worker)
assert_eq "$(post_json '{"action":"engine_save","params":{"settings":{"NET_SERVER_MAX_TICK_RATE":true}}}')" \
  "400" "a boolean setting value is rejected"
assert_eq "$(post_json '{"action":"engine_save","params":{"settings":{"NET_SERVER_MAX_TICK_RATE":60}}}')" \
  "202" "a numeric setting value is accepted"
assert_eq "$(post_json '{"action":"engine_save","params":{"settings":{"NOT_A_SETTING":60}}}')" \
  "400" "an unknown setting key is rejected"

# --- disruptive actions need confirm, then serialise ----------------------
assert_eq "$(post_json '{"action":"graceful_restart","params":{"wait":30}}')" "400" \
  "disruptive action needs confirm"
assert_eq "$(post_json '{"action":"graceful_restart","params":{"wait":30,"confirm":true}}')" "202" \
  "confirmed disruptive action accepted"
assert_eq "$(post_json '{"action":"graceful_restart","params":{"wait":30,"confirm":true}}')" "409" \
  "only one pending disruptive job at a time"
# wait is optional: the invoked tool's own default applies when it is absent
assert_eq "$(post_json '{"action":"graceful_stop","params":{"confirm":true}}')" "409" \
  "any pending disruptive job blocks another disruptive action"
# a pending disruptive job must NOT block a harmless file-only one
assert_eq "$(post_json '{"action":"backup"}')" "202" \
  "a pending disruptive job does not block a non-disruptive one"

# --- job status is readable, and ids cannot traverse ----------------------
assert_eq "$(code -u "$CREDS" "$U/api/jobs")" "200" "job list readable"
listing="$(body -u "$CREDS" "$U/api/jobs")"
assert_contains "$listing" '"ok": true' "list uses the API envelope"
assert_contains "$listing" "$BACKUP_ID" "list contains the enqueued job"
assert_contains "$listing" '"queued"' "enqueued jobs are queued, not run by the web process"
one="$(body -u "$CREDS" "$U/api/jobs/$BACKUP_ID")"
assert_contains "$one" '"action": "backup"' "single job readable"
assert_eq "$(code "$U/api/jobs")" "401" "the job list still requires auth"
assert_eq "$(code -u "$CREDS" "$U/api/jobs/$(printf '0%.0s' $(seq 32))")" "404" "unknown job is 404"
assert_eq "$(code -u "$CREDS" "$U/api/jobs/..%2f..%2fetc%2fpasswd")" "404" "crafted job id refused"
assert_not_contains "$(body -u "$CREDS" "$U/api/jobs/..%2f..%2fetc%2fpasswd")" "root:" "traversal leaks nothing"
assert_eq "$(code --path-as-is -u "$CREDS" "$U/api/jobs/../../etc/passwd")" "404" "raw traversal refused"
assert_eq "$(code -u "$CREDS" "$U/api/jobs/x%00")" "404" "a NUL in the id is refused"

# --- adversarial: none of these may raise or kill the server --------------
# a non-ASCII token header must be a refusal, not a UnicodeError/TypeError
nonascii="$(printf 'X-Palwarden-Token: t\303\251k-\377')"
assert_eq "$(code -u "$CREDS" -H "$nonascii" -X POST \
  -H 'Content-Type: application/json' -d '{"action":"backup"}' "$U/api/jobs")" "403" \
  "non-ASCII token is refused without raising"

# a duplicated token header must not let a good value smuggle past a bad one,
# in either order
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: wrong\r\nX-Palwarden-Token: tok-for-tests\r\nContent-Length: 20\r\nConnection: close\r\n\r\n{"action":"backup"}\n' \
  "$PORT" "$B64" > "$WORK/dup1.req"
assert_eq "$(raw "$WORK/dup1.req")" "403" "duplicate token header (bad first) refused"
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Token: wrong\r\nContent-Length: 20\r\nConnection: close\r\n\r\n{"action":"backup"}\n' \
  "$PORT" "$B64" > "$WORK/dup2.req"
assert_eq "$(raw "$WORK/dup2.req")" "403" "duplicate token header (good first) refused"

# a missing, negative or non-numeric Content-Length is a 400, never a hang
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nConnection: close\r\n\r\n' \
  "$PORT" "$B64" > "$WORK/nolen.req"
assert_eq "$(raw "$WORK/nolen.req")" "400" "missing Content-Length is 400"
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nContent-Length: -5\r\nConnection: close\r\n\r\n' \
  "$PORT" "$B64" > "$WORK/neglen.req"
assert_eq "$(raw "$WORK/neglen.req")" "400" "negative Content-Length is 400"
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nContent-Length: abc\r\nConnection: close\r\n\r\n' \
  "$PORT" "$B64" > "$WORK/badlen.req"
assert_eq "$(raw "$WORK/badlen.req")" "400" "non-integer Content-Length is 400"
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nContent-Length: 99999999\r\nConnection: close\r\n\r\n{}\n' \
  "$PORT" "$B64" > "$WORK/hugelen.req"
assert_eq "$(raw "$WORK/hugelen.req")" "400" "oversized Content-Length is refused before reading"

# a Content-Length that overstates the body must not wedge the connection
# forever; we do not care what it answers, only that the server survives.
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n{"action":"backup"}' \
  "$PORT" "$B64" > "$WORK/short.req"
short_code="$(raw "$WORK/short.req")"
assert_ne "$short_code" "202" "a truncated body is never enqueued"

# the cap boundary: exactly 64 KiB is accepted, one byte more is refused
python3 - "$WORK" <<'EOF'
import json
import sys
work = sys.argv[1]
for name, size in (("atcap", 65536), ("overcap", 65537)):
    body = '{"action":"backup","params":{"pad":""}}'
    pad = "x" * (size - len(body))
    doc = '{"action":"backup","params":{"pad":"%s"}}' % pad
    assert len(doc) == size, (len(doc), size)
    json.loads(doc)
    with open(f"{work}/{name}.json", "w") as fh:
        fh.write(doc)
EOF
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
  --data-binary "@$WORK/atcap.json" "$U/api/jobs")" "202" "a body of exactly 64 KiB is accepted"
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
  --data-binary "@$WORK/overcap.json" "$U/api/jobs")" "400" "one byte over the cap is refused"

# POST to an unknown API path is a 404, not a 501 or a stray enqueue
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -X POST -d '{}' "$U/api/nope")" "404" \
  "POST to an unknown endpoint is 404"

# --- after every rejection above, the server is STILL SERVING -------------
assert_eq "$(code -u "$CREDS" "$U/api/jobs")" "200" "server still serving after hostile input"
assert_eq "$(code -u "$CREDS" "$U/")" "200" "static serving still works too"
assert_eq "$(code -u "$CREDS" "$U/api/health")" "200" "the read API still works too"

# --- an unwritable queue directory is a clear 500, not a traceback --------
if [ "$(id -u)" != "0" ]; then
  mkdir -p "$WORK/nowrite"
  chmod 0500 "$WORK/nowrite"
  start_server "$PORT_RO" "$WORK/nowrite/jobs" "$WORK/server-ro.log"
  PID_RO=$!
  ro_code="$(code -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
    -d '{"action":"backup"}' "http://127.0.0.1:$PORT_RO/api/jobs")"
  assert_eq "$ro_code" "500" "an unwritable queue directory is a 500"
  ro_body="$(body -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
    -d '{"action":"backup"}' "http://127.0.0.1:$PORT_RO/api/jobs")"
  assert_contains "$ro_body" "job queue directory" "the 500 names the problem"
  assert_contains "$ro_body" "owned by the web UI user" "the 500 says how to fix it"
  assert_eq "$(code -u "$CREDS" "http://127.0.0.1:$PORT_RO/api/jobs")" "200" \
    "reads still work with an unwritable queue"
  assert_not_contains "$(cat "$WORK/server-ro.log")" "Traceback" "no traceback on the unwritable path"
  chmod u+w "$WORK/nowrite"
else
  echo "  (skipping the unwritable-queue check: running as root)" >&2
fi

# --- nothing sensitive in the log ----------------------------------------
assert_not_contains "$(cat "$WORK/server.log")" "tok-for-tests" "token never logged"
assert_not_contains "$(cat "$WORK/server.log")" "pw-for-tests" "password never logged"
assert_not_contains "$(cat "$WORK/server.log")" "Traceback" "no traceback reached the log"

# --- the web process never executed anything -----------------------------
# Every accepted job is still queued: the unprivileged HTTP handler writes job
# files and nothing else. If it had run one, the state would have moved on.
states="$(python3 -c '
import json, pathlib, sys
seen = set()
for p in pathlib.Path(sys.argv[1]).glob("*.json"):
    seen.add(json.loads(p.read_text())["state"])
print(",".join(sorted(seen)))' "$WORK/jobs")"
assert_eq "$states" "queued" "the web process only ever queued jobs, never ran one"

assert_report
