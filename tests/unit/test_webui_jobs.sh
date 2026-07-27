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
# One level deeper than $WORK on purpose: `../../` out of the queue directory
# then lands *inside* the temp tree, so the traversal assertions below can plant
# a real file at the exact path a working traversal would reach. With the queue
# at $WORK/jobs that target was /tmp/etc/passwd, which does not exist — so a
# traversal that genuinely worked would still have 404'd and "must not leak
# root:" could never have fired.
JOBS="$WORK/queue/jobs"
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

# Traversal bait. `/api/jobs/<id>` builds "$JOBS/<id>.json", so an id of
# ../../etc/passwd would resolve to $WORK/etc/passwd.json; plant both spellings
# with a sentinel so the "leaks nothing" assertions have something to detect.
mkdir -p "$WORK/etc"
SENTINEL="root:x:0:0:PLANTED-TRAVERSAL-TARGET:/root:/bin/sh"
printf '%s\n' "$SENTINEL" > "$WORK/etc/passwd"
printf '{"leak": "%s"}\n' "$SENTINEL" > "$WORK/etc/passwd.json"

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

start_server "$PORT" "$JOBS" "$WORK/server.log"
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
assert_eq "$(stat -c %a "$JOBS")" "700" "queue directory is 0700"

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
# DNS rebinding: the attacker's name resolves to 127.0.0.1, so the browser sends
# BOTH Host and Origin as that name and the two agree — which is what makes this
# different from the plain foreign-Origin case above, and what a naive
# Origin-equals-Host check would wave straight through. (Sending
# "Host: 127.0.0.1:$PORT" here, curl's own default for this URL, tested nothing:
# it disagreed with the Origin, so the naive check would have refused it too.)
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H "Origin: http://rebind.example:$PORT" \
  -H "Host: rebind.example:$PORT" -X POST -H 'Content-Type: application/json' \
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

# --- params are a whitelist, so junk never reaches the queue ---------------
# The worker's validate_params used to return a *copy* of params, so any key the
# caller invented was stored verbatim in the job file — up to the 64 KiB body
# cap of junk on disk per authenticated request — and a typo like `waitt` was
# silently ignored instead of reported.
assert_eq "$(post_json '{"action":"backup","params":{"pad":"xxxxx"}}')" "400" \
  "an unrecognised param key is rejected"
assert_contains "$(post_body '{"action":"backup","params":{"pad":"xxxxx"}}')" "'pad'" \
  "the rejection names the offending key"
assert_eq "$(post_json '{"action":"graceful_restart","params":{"waitt":30,"confirm":true}}')" \
  "400" "a near-miss param name is rejected, not silently dropped"
# (the recognised keys are proved to round-trip in the serialisation section
# below, where the one accepted disruptive job carries all of them)

# --- disruptive actions need confirm, then serialise ----------------------
assert_eq "$(post_json '{"action":"graceful_restart","params":{"wait":30}}')" "400" \
  "disruptive action needs confirm"
assert_eq "$(post_json '{"action":"graceful_restart","params":{"wait":30,"message":"maintenance","confirm":true}}')" \
  "202" "confirmed disruptive action accepted"
# every recognised key round-trips into the job file, and nothing else does: the
# queued params are exactly what the worker's validator normalised.
RESTART_ID="$(python3 -c '
import json, pathlib, sys
for p in pathlib.Path(sys.argv[1]).glob("*.json"):
    job = json.loads(p.read_text())
    if job["action"] == "graceful_restart":
        print(job["id"])
        print(json.dumps(job["params"], sort_keys=True))
        break' "$JOBS")"
assert_eq "$(printf '%s' "$RESTART_ID" | sed -n 2p)" \
  '{"confirm": true, "message": "maintenance", "wait": 30}' \
  "the queued params are exactly the recognised, normalised ones"
RESTART_ID="$(printf '%s' "$RESTART_ID" | sed -n 1p)"
assert_eq "$(post_json '{"action":"graceful_restart","params":{"wait":30,"confirm":true}}')" "409" \
  "only one pending disruptive job at a time"
# wait is optional: the invoked tool's own default applies when it is absent
assert_eq "$(post_json '{"action":"graceful_stop","params":{"confirm":true}}')" "409" \
  "any pending disruptive job blocks another disruptive action"
# ...and the 409 has to be actionable: a worker killed mid-job leaves its job
# `running` until a worker *starts* again, so "something is in the way" with no
# id would be a permanent refusal with nothing to inspect.
blocked="$(post_body '{"action":"graceful_stop","params":{"confirm":true}}')"
assert_contains "$blocked" '"blocked_by"' "the 409 identifies the blocker"
assert_contains "$blocked" '"action": "graceful_restart"' "the 409 names the blocking action"
assert_contains "$blocked" "$RESTART_ID" "the 409 names the blocking job id"
assert_contains "$(body -u "$CREDS" "$U/api/jobs/$RESTART_ID")" '"action": "graceful_restart"' \
  "the blocker named in the 409 can be fetched"
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
# The bait planted at the top of this file is what makes these load-bearing: the
# target of this traversal exists and is readable, so a working traversal would
# return its contents instead of a 404.
assert_not_contains "$(body -u "$CREDS" "$U/api/jobs/..%2f..%2fetc%2fpasswd")" \
  "PLANTED-TRAVERSAL-TARGET" "the planted traversal target is never served"
assert_not_contains "$(body -u "$CREDS" "$U/api/jobs/..%2f..%2fetc%2fpasswd")" "root:" "traversal leaks nothing"
assert_eq "$(code --path-as-is -u "$CREDS" "$U/api/jobs/../../etc/passwd")" "404" "raw traversal refused"
assert_not_contains "$(body --path-as-is -u "$CREDS" "$U/api/jobs/../../etc/passwd")" \
  "PLANTED-TRAVERSAL-TARGET" "nor by the un-encoded spelling"
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
# int() accepts PEP 515 underscores and a leading sign, so "1_0" would have been
# read as a length of 10 and "+19" as 19 — a framing a proxy would not agree
# with. Only ASCII digits count.
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nContent-Length: 1_0\r\nConnection: close\r\n\r\n{"action":"backup"}\n' \
  "$PORT" "$B64" > "$WORK/uslen.req"
assert_eq "$(raw "$WORK/uslen.req")" "400" "an underscored Content-Length is 400"
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nContent-Length: +19\r\nConnection: close\r\n\r\n{"action":"backup"}' \
  "$PORT" "$B64" > "$WORK/pluslen.req"
assert_eq "$(raw "$WORK/pluslen.req")" "400" "a signed Content-Length is 400"
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nContent-Length: 99999999\r\nConnection: close\r\n\r\n{}\n' \
  "$PORT" "$B64" > "$WORK/hugelen.req"
assert_eq "$(raw "$WORK/hugelen.req")" "400" "oversized Content-Length is refused before reading"

# a Content-Length that overstates the body must not wedge the connection
# forever; we do not care what it answers, only that the server survives.
printf 'POST /api/jobs HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n{"action":"backup"}' \
  "$PORT" "$B64" > "$WORK/short.req"
short_code="$(raw "$WORK/short.req")"
assert_ne "$short_code" "202" "a truncated body is never enqueued"

# the cap boundary: exactly 64 KiB is accepted, one byte more is refused.
# Padded with insignificant JSON whitespace rather than a junk param: params are
# a whitelist now, and padding with an unrecognised key would make the at-cap
# case a 400 for the wrong reason (and would be exactly the "64 KiB of junk on
# disk" the whitelist exists to prevent).
python3 - "$WORK" <<'EOF'
import json
import sys
work = sys.argv[1]
for name, size in (("atcap", 65536), ("overcap", 65537)):
    head = '{"action":"backup","params":{}'
    doc = head + " " * (size - len(head) - 1) + "}"
    assert len(doc) == size, (len(doc), size)
    assert json.loads(doc)["action"] == "backup"
    with open(f"{work}/{name}.json", "w") as fh:
        fh.write(doc)
EOF
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
  --data-binary "@$WORK/atcap.json" "$U/api/jobs")" "202" "a body of exactly 64 KiB is accepted"
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
  --data-binary "@$WORK/overcap.json" "$U/api/jobs")" "400" "one byte over the cap is refused"
assert_contains "$(body -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
  --data-binary "@$WORK/overcap.json" "$U/api/jobs")" "at most 65536 bytes" \
  "the over-cap 400 is about the size, not the content"

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
print(",".join(sorted(seen)))' "$JOBS")"
assert_eq "$states" "queued" "the web process only ever queued jobs, never ran one"

# --- the Engine.ini editor is the first browser-side consumer of this API ----
# Everything above proves the server's half of the contract. This section proves
# the page actually speaks it: the right two actions, the token header, the
# confirm gate on the disruptive one, and a payload the validators above accept.
EDITOR="$REPO/webui/EngineIniPerformanceEditor.html"
VENDORED="$REPO/webui/PalWorldSettingsEditor.html"

# provenance: first-party header on ours, byte-identical vendored file next to it
assert_file_contains "$EDITOR" "SPDX-License-Identifier: AGPL-3.0-or-later" \
  "the Engine editor carries the AGPL identifier"
assert_file_contains "$EDITOR" "SPDX-FileCopyrightText: 2026 Brian Grant" \
  "the Engine editor carries our copyright"
assert_file_contains "$EDITOR" "CREDITS.md" "the Engine editor notes its MIT derivation"
assert_rc 0 git -C "$REPO" diff --quiet -- webui/PalWorldSettingsEditor.html
assert_rc 0 test -f "$VENDORED"

# the two controls, and only those two: apply-without-restart is deliberately absent
assert_file_contains "$EDITOR" 'id="btn-save"' "the editor has a Save control"
assert_file_contains "$EDITOR" 'id="btn-save-apply"' "the editor has a Save and apply control"
assert_file_contains "$EDITOR" "'engine_save'" "Save enqueues engine_save"
assert_file_contains "$EDITOR" "'engine_save_apply_restart'" \
  "Save and apply enqueues engine_save_apply_restart"
assert_file_not_contains "$EDITOR" "'engine_apply'" \
  "apply-without-restart is not offered (Engine.ini only takes effect on restart)"

# mutations carry the token header, from sessionStorage and nowhere else
assert_file_contains "$EDITOR" "X-Palwarden-Token" "the editor sends the token header"
assert_file_contains "$EDITOR" "sessionStorage.getItem" "the token is read from sessionStorage"
assert_file_not_contains "$EDITOR" "localStorage" "the token never lands in localStorage"
assert_file_not_contains "$EDITOR" "document.cookie" "the token is never put in a cookie"
assert_file_not_contains "$EDITOR" "Authorization: Bearer" \
  "the token does not try to share the Basic auth header"

# the disruptive path goes through pw-confirm, with confirm: true in the body
assert_file_contains "$EDITOR" 'class="pw-confirm"' "the disruptive path has a pw-confirm dialog"
assert_file_contains "$EDITOR" "showModal" "the confirm dialog is modal (focus-trapped, Esc cancels)"
assert_file_contains "$EDITOR" "confirm: true" "the disruptive body carries confirm: true"
assert_file_contains "$EDITOR" 'aria-live="polite"' "the job log is announced politely"
assert_file_contains "$EDITOR" 'class="pw-log' "job progress goes in a pw-log region"
assert_file_contains "$EDITOR" 'id="toast"' "outcomes go in a pw-toast"

# structural checks a grep cannot express: no innerHTML on a page that renders
# server-supplied error/blocked_by/Origin text, only vocabulary tokens, and the
# two request bodies carrying no param key besides settings/confirm.
structural="$(python3 - "$EDITOR" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
bad = []

# 1. innerHTML is never assigned anything but the empty string.
for m in re.finditer(r"\.innerHTML\s*=\s*([^;\n]*)", src):
    if m.group(1).strip() not in ('""', "''"):
        bad.append("innerHTML assigned %r" % m.group(1).strip())

# 2. Raw hex colors only inside the :root token block.
style = re.search(r"<style>(.*?)</style>", src, re.S)
if not style:
    bad.append("no <style> block")
else:
    css = style.group(1)
    root = re.search(r":root\s*\{.*?\}", css, re.S)
    if not root:
        bad.append("no :root token block")
    outside = css.replace(root.group(0), "") if root else css
    for m in re.finditer(r"#[0-9a-fA-F]{3,8}\b", outside):
        bad.append("raw hex outside :root: %s" % m.group(0))

# 3. No inline style attributes.
if re.search(r"\sstyle=", src):
    bad.append("inline style attribute")

# 4. The POSTed params objects mention no key other than settings/confirm, and
#    no JSON boolean inside settings.
calls = re.findall(r"runJob\(\s*'([a-z_]+)'\s*,\s*\{([^}]*)\}", src)
if len(calls) != 2:
    bad.append("expected exactly 2 runJob call sites, found %d" % len(calls))
for action, params in calls:
    keys = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", params)
    for key in keys:
        if key not in ("settings", "confirm"):
            bad.append("%s passes an unrecognised param key: %s" % (action, key))
    if action == "engine_save_apply_restart" and "confirm: true" not in params:
        bad.append("engine_save_apply_restart is missing confirm: true")
    if action == "engine_save" and "confirm" in keys:
        bad.append("engine_save should not send confirm")
    if re.search(r"settings\s*:\s*(true|false)", params):
        bad.append("%s sends a boolean for settings" % action)

print("OK" if not bad else "; ".join(bad))
PY
)"
assert_eq "$structural" "OK" "the editor's DOM/CSS/payload invariants hold"

# --- exercise the real collectSettings() under node -------------------------
# A grep proving a button exists is weak; this runs the page's own payload
# builder against a stubbed form and checks the object the API would receive.
if command -v node >/dev/null 2>&1; then
  CS_JS="$WORK/collectSettings.js"
  awk '/^const SETTINGS = \[/{f=1} f{print} f && /^\];/{exit}' "$EDITOR" > "$CS_JS"
  awk '/^function collectSettings\(\)\{/{f=1} f{print} f && /^}/{exit}' "$EDITOR" >> "$CS_JS"
  cat >> "$CS_JS" <<'EOF'

// Stub form state: el(id) returns the input nodes collectSettings reads.
let STATE = {};
function el(id){ return STATE[id]; }
function form(rows){
  STATE = {};
  for (const s of SETTINGS) {
    STATE[s.env + "_enable"] = { checked: false };
    STATE[s.env] = s.type === "bool" ? { checked: false } : { value: "" };
  }
  for (const [env, spec] of Object.entries(rows)) {
    STATE[env + "_enable"].checked = spec.managed !== false;
    if ("checked" in spec) STATE[env].checked = spec.checked;
    if ("value" in spec) STATE[env].value = spec.value;
  }
}
const KNOWN = new Set(SETTINGS.map(s => s.env));
let failures = 0;
function check(desc, cond) { if (!cond) { failures++; console.log("FAIL: " + desc); } }

// nothing managed -> empty object (the API refuses an empty settings map, so the
// page must not post one)
form({});
check("no managed rows yields no settings", Object.keys(collectSettings()).length === 0);

// a managed row with a blank value is not sent (it would fail normalize_value)
form({ NET_SERVER_MAX_TICK_RATE: { value: "" } });
check("a blank managed number is omitted", Object.keys(collectSettings()).length === 0);

// an unmanaged row is never sent even with a value: engine_save merges, so an
// untouched key must stay whatever engine.env already says
form({ NET_SERVER_MAX_TICK_RATE: { managed: false, value: "60" } });
check("an unmanaged row is omitted", Object.keys(collectSettings()).length === 0);

form({
  NET_SERVER_MAX_TICK_RATE: { value: " 60 " },
  LEVEL_STREAMING_ACTORS_UPDATE_TIME_LIMIT: { value: "5.5" },
  ASYNC_LOADING_THREAD_ENABLED: { checked: true },
  EVENT_DRIVEN_LOADER_ENABLED: { checked: false },
});
const got = collectSettings();
check("only the managed rows are sent", Object.keys(got).length === 4);
check("every key is one the worker knows", Object.keys(got).every(k => KNOWN.has(k)));
check("every value is a string", Object.values(got).every(v => typeof v === "string"));
check("whitespace is trimmed", got.NET_SERVER_MAX_TICK_RATE === "60");
check("floats survive", got.LEVEL_STREAMING_ACTORS_UPDATE_TIME_LIMIT === "5.5");
check("a true bool is 1, not true", got.ASYNC_LOADING_THREAD_ENABLED === "1");
check("a false bool is 0, not false", got.EVENT_DRIVEN_LOADER_ENABLED === "0");

// the wire form: no JSON booleans anywhere inside settings, and the two bodies
// carry no param key the worker's whitelist would reject
const save = JSON.stringify({ action: "engine_save", params: { settings: got } });
const apply = JSON.stringify({ action: "engine_save_apply_restart", params: { settings: got, confirm: true } });
check("engine_save body has no boolean setting", !/:(true|false)/.test(JSON.stringify(got)));
check("engine_save sends only settings",
      JSON.stringify(Object.keys(JSON.parse(save).params).sort()) === '["settings"]');
check("engine_save_apply_restart sends only settings and confirm",
      JSON.stringify(Object.keys(JSON.parse(apply).params).sort()) === '["confirm","settings"]');
check("confirm is the only boolean in the disruptive body",
      JSON.parse(apply).params.confirm === true);
console.log(failures === 0 ? "OK" : "FAIL");
EOF
  cs_out="$(node "$CS_JS" 2>&1)"
  assert_eq "$cs_out" "OK" "collectSettings() extracted from the editor builds an acceptable payload"

else
  echo "  (skipping the node checks of collectSettings(): node not found)" >&2
fi

# ...and the exact wire shape the page builds is accepted by the real validators,
# strings for bools included (a shape check alone would not prove that).
assert_eq "$(post_json '{"action":"engine_save","params":{"settings":{"NET_SERVER_MAX_TICK_RATE":"60","ASYNC_LOADING_THREAD_ENABLED":"1","LEVEL_STREAMING_ACTORS_UPDATE_TIME_LIMIT":"5.5"}}}')" \
  "202" "the string-valued payload the page posts is accepted by the API"
assert_eq "$(post_json '{"action":"engine_save_apply_restart","params":{"settings":{"NET_SERVER_MAX_TICK_RATE":"60"},"confirm":true}}')" \
  "409" "the disruptive payload the page posts validates (and serialises behind the pending restart)"

assert_report
