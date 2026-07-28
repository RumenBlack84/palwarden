#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# The backup panel's three HTTP endpoints, in the UNPRIVILEGED web process:
#
#   POST /api/backups/upload          a mutation: Basic + token + Origin
#   GET  /api/backups/<name>/download a read: Basic only
#   GET  /api/backup-schedule         a read: Basic only
#
# Upload is the first endpoint in this project that writes attacker-supplied bytes
# to disk, so most of this suite is about what must be refused *before* a file
# exists: a bad filename, an over-cap or wrongly-framed Content-Length, a full
# volume. Download is the first that streams a file chosen by name, so the rest is
# about names that must never reach the filesystem and a symlink planted under a
# name that passes the pattern (the archives directory is chowned to the service
# account, so that is a real possibility, not a theoretical one).
#
# Two existing constants must NOT apply to the upload path, and both directions are
# pinned here: a POST /api/jobs body over MAX_BODY_BYTES (64 KiB) is still refused,
# an upload well over 64 KiB still succeeds, and a trickled body that outlives a
# short PALWARDEN_UPLOAD_TIMEOUT is cut off (which can only happen if the upload
# handler really applies its own timeout instead of inheriting REQUEST_TIMEOUT).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
REPO="$DIR/../.."
WEBUI="$REPO/sbin/palwarden-webui"

WORK="$(mktemp -d)"
# The served directories live one level deeper than $WORK on purpose: `../../` out
# of $WORK/vol/backups then lands *inside* the temp tree, so the traversal
# assertions can plant a real, readable file at the exact path a working traversal
# would reach. Without that, a traversal that genuinely worked would still 404 and
# the "leaks nothing" assertions could never fire.
BACKUPS="$WORK/vol/backups"
UPLOADS="$WORK/vol/uploads"    # deliberately NOT pre-created: the server makes it
JOBS="$WORK/queue/jobs"
PORT=18099
PORT_SLOW=18098
PORT_FULL=18095
PID=""
PID_SLOW=""
PID_FULL=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  [ -n "$PID_SLOW" ] && kill "$PID_SLOW" 2>/dev/null
  [ -n "$PID_FULL" ] && kill "$PID_FULL" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

ARCHIVE="palworld-save-20260101T000000Z.tar.gz"
ARCHIVE2="palworld-save-20260102T000000Z.tar.gz"

# --- fixture ---------------------------------------------------------------
mkdir -p "$WORK/webroot" "$WORK/sbin" "$WORK/cfg" "$WORK/vol" "$BACKUPS" "$WORK/etc"
echo '<html><body>PALWARDEN DASHBOARD</body></html>' > "$WORK/webroot/palwarden.html"
printf 'WEBUI_USER="admin"\nWEBUI_PASSWORD="pw-for-tests"\nWEBUI_TOKEN="tok-for-tests"\n' \
  > "$WORK/webui.env"
printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(ServerName="Ygg")\n' \
  > "$WORK/cfg/PalWorldSettings.ini"

cat > "$WORK/sbin/palworld-health-report" <<'EOF'
#!/usr/bin/env bash
echo '{"service":{"active_state":"active"}}'
EOF
chmod +x "$WORK/sbin/palworld-health-report"
# The REAL schedule tool, not a stub: /api/backup-schedule's contract is "whatever
# palworld-backups --show-schedule prints", and a stub would let the two drift.
ln -s "$REPO/sbin/palworld-backups" "$WORK/sbin/palworld-backups"
printf 'BACKUP_ENABLED=true\nBACKUP_INTERVAL_HOURS=6\nBACKUP_RETENTION_DAYS=30\nBACKUP_KEEP_MIN=5\n' \
  > "$WORK/backup.env"

# Traversal bait: `$BACKUPS/../../etc/passwd` is exactly $WORK/etc/passwd, so a
# name validation that failed to hold would serve this sentinel.
SENTINEL="root:x:0:0:PLANTED-TRAVERSAL-TARGET:/root:/bin/sh"
printf '%s\n' "$SENTINEL" > "$WORK/etc/passwd"

# Payloads. The good upload is well over MAX_BODY_BYTES (64 KiB) so that its
# success is itself proof the job cap does not apply here.
python3 - "$WORK" "$BACKUPS/$ARCHIVE" <<'EOF'
import sys
work, existing = sys.argv[1], sys.argv[2]
# Not random: the assertions compare bytes, and a reproducible pattern makes a
# mismatch readable in a diff.
with open(f"{work}/good.bin", "wb") as fh:
    fh.write(bytes(range(256)) * 586 + b"TAIL")          # 150,020 bytes
with open(f"{work}/second.bin", "wb") as fh:
    fh.write(b"SECOND-UPLOAD" * 6000)                    # 78,000 bytes
with open(f"{work}/overcap.bin", "wb") as fh:
    fh.write(b"z" * 200001)                              # one byte over the cap
with open(existing, "wb") as fh:
    fh.write(b"EXISTING-ARCHIVE-BYTES" * 5000)
EOF
GOOD_BYTES="$(wc -c < "$WORK/good.bin" | tr -d ' ')"

# Debris in the backups directory that /api/backups must not list: palworld-restore
# --import's in-flight temp file, and anything else off-pattern.
IMPORT_TEMP=".palworld-save-20260103T000000Z.tar.gz.import.deadbeef"
printf 'half a copy' > "$BACKUPS/$IMPORT_TEMP"
printf 'notes' > "$BACKUPS/operator-notes.txt"
printf 'not ours' > "$BACKUPS/$ARCHIVE.bak"

# --- raw senders -----------------------------------------------------------
# curl builds Content-Length itself, so a missing, lying, chunked or duplicated
# header can only be exercised by writing the request out by hand.
cat > "$WORK/raw.py" <<'EOF'
import socket
import sys

# raw.py <port> <request-file> [shutdown]
# "shutdown" half-closes after sending, which is how a body shorter than
# Content-Length reaches the server as EOF instead of as a stall.
port, path = int(sys.argv[1]), sys.argv[2]
half_close = len(sys.argv) > 3
with open(path, "rb") as fh:
    request = fh.read()
data = b""
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=8)
except OSError:
    print("000")
    raise SystemExit(0)
try:
    sock.sendall(request)
    if half_close:
        sock.shutdown(socket.SHUT_WR)
    while b"\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
except OSError:
    pass
finally:
    sock.close()
parts = data.split(b"\r\n")[0].decode("latin-1", "replace").split(" ")
print(parts[1] if len(parts) > 1 else "000")
EOF

# trickle.py <port> <name> <size> <chunk> <delay> <b64>: a well-formed upload sent
# slowly. The only way to observe *which* socket timeout the upload path uses.
cat > "$WORK/trickle.py" <<'EOF'
import socket
import sys
import time

port, name, size = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
chunk, delay, b64 = int(sys.argv[4]), float(sys.argv[5]), sys.argv[6]
head = (
    f"POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
    f"Authorization: Basic {b64}\r\nX-Palwarden-Token: tok-for-tests\r\n"
    f"X-Palwarden-Filename: {name}\r\n"
    f"Content-Type: application/octet-stream\r\n"
    f"Content-Length: {size}\r\nConnection: close\r\n\r\n"
).encode()
data = b""
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=30)
except OSError:
    print("000")
    raise SystemExit(0)
try:
    sock.sendall(head)
    sent = 0
    while sent < size:
        n = min(chunk, size - sent)
        sock.sendall(b"x" * n)
        sent += n
        if sent < size:
            time.sleep(delay)
    while b"\r\n" not in data:
        got = sock.recv(4096)
        if not got:
            break
        data += got
except OSError:
    pass
finally:
    sock.close()
parts = data.split(b"\r\n")[0].decode("latin-1", "replace").split(" ")
print(parts[1] if len(parts) > 1 else "000")
EOF

start_server() {  # start_server <port> <logfile> [KEY=VALUE ...]
  local port="$1" log="$2"
  shift 2
  env PALWARDEN_WEBUI_ENV="$WORK/webui.env" \
      PALWARDEN_WEBUI_ROOT="$WORK/webroot" \
      PALWARDEN_WEBUI_BIND=127.0.0.1 \
      PALWARDEN_WEBUI_PORT="$port" \
      PALWARDEN_JOBS_DIR="$JOBS" \
      PALWARDEN_SBIN_DIR="$WORK/sbin" \
      PALWARDEN_PARSER_BIN="$REPO/bin/palworld-config-parser" \
      PALWORLD_CONFIG_FILE="$WORK/cfg/PalWorldSettings.ini" \
      PALWORLD_ENGINE_ENV="$WORK/engine.env" \
      PALWARDEN_SAVE_BACKUP_DIR="$BACKUPS" \
      PALWARDEN_SNAPSHOT_DIR="$WORK/snapshots" \
      PALWARDEN_UPLOAD_DIR="$UPLOADS" \
      PALWORLD_BACKUP_SCHEDULE="$WORK/backup.env" \
      "$@" python3 "$WEBUI" --serve >"$log" 2>&1 &
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" && return 0
    sleep 0.25
  done
}

# The cap is lowered to 200000 so the boundary can be crossed with a real body
# while still sitting far above the 64 KiB job cap. The upload timeout is 5s so a
# trickled body survives here and dies on the PORT_SLOW server below.
start_server "$PORT" "$WORK/server.log" \
  PALWARDEN_MAX_UPLOAD_BYTES=200000 PALWARDEN_UPLOAD_TIMEOUT=5
PID=$!

U="http://127.0.0.1:$PORT"
CREDS="admin:pw-for-tests"
TOKHDR="X-Palwarden-Token: tok-for-tests"
B64="$(printf 'admin:pw-for-tests' | base64 | tr -d '\n')"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }
raw() { python3 "$WORK/raw.py" "$PORT" "$@"; }

# A fully-credentialled upload of <file> as <name>. `Expect:` disables curl's
# 100-continue for large bodies, which this HTTP/1.0 server never answers.
upload() {  # upload <file> <name> [extra curl args...]
  local file="$1" name="$2"
  shift 2
  code -u "$CREDS" -H "$TOKHDR" -H "X-Palwarden-Filename: $name" -H 'Expect:' \
    -H 'Content-Type: application/octet-stream' --data-binary "@$file" \
    "$@" "$U/api/backups/upload"
}
# Everything in the staging dir, dotfiles included (an abandoned temp file starts
# with a dot, so a plain glob would miss exactly what these assertions look for),
# on one line. `find -printf` rather than `ls`: shellcheck's SC2012, and it is also
# the spelling that cannot be confused by an odd name.
staged() {
  [ -d "$UPLOADS" ] || return 0
  find "$UPLOADS" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '
}
# After every rejection: the server must still be answering requests.
serving() { code -u "$CREDS" "$U/api/health"; }

# --- upload: the mutation gates, in order ----------------------------------
assert_eq "$(code -X POST -H "X-Palwarden-Filename: $ARCHIVE" --data-binary '@'"$WORK/good.bin" \
  -H 'Expect:' "$U/api/backups/upload")" "401" "an unauthenticated upload is 401"
assert_contains "$(curl -s -D - -o /dev/null -X POST -H 'Expect:' \
  -H "X-Palwarden-Filename: $ARCHIVE" --data-binary '@'"$WORK/second.bin" \
  "$U/api/backups/upload")" "WWW-Authenticate" "an unauthenticated upload gets a challenge"
assert_eq "$(serving)" "200" "still serving after an unauthenticated upload"

assert_eq "$(code -u "$CREDS" -H "X-Palwarden-Filename: $ARCHIVE" -H 'Expect:' \
  --data-binary '@'"$WORK/good.bin" "$U/api/backups/upload")" "403" \
  "Basic alone cannot upload (the browser attaches it cross-origin for free)"
assert_eq "$(code -u "$CREDS" -H 'X-Palwarden-Token: wrong' -H 'Expect:' \
  -H "X-Palwarden-Filename: $ARCHIVE" --data-binary '@'"$WORK/good.bin" \
  "$U/api/backups/upload")" "403" "a wrong token cannot upload"
assert_eq "$(code -u "admin:wrong-password" -H "$TOKHDR" -H 'Expect:' \
  -H "X-Palwarden-Filename: $ARCHIVE" --data-binary '@'"$WORK/good.bin" \
  "$U/api/backups/upload")" "401" "the token does not replace the password"
assert_eq "$(upload "$WORK/good.bin" "$ARCHIVE" -H 'Sec-Fetch-Site: cross-site')" "403" \
  "a cross-site upload is refused"
assert_eq "$(upload "$WORK/good.bin" "$ARCHIVE" -H 'Sec-Fetch-Site: same-site')" "403" \
  "a same-site (sibling subdomain) upload is refused"
assert_eq "$(upload "$WORK/good.bin" "$ARCHIVE" -H 'Origin: http://evil.example')" "403" \
  "a foreign Origin is refused"
assert_eq "$(upload "$WORK/good.bin" "$ARCHIVE" -H "Origin: http://rebind.example:$PORT" \
  -H "Host: rebind.example:$PORT")" "403" "a rebound Origin is refused despite a matching Host"
# Nothing above may have created a file: every gate runs before the staging dir
# is even touched.
assert_eq "$(staged)" "" "no gate rejection stages a file"
assert_eq "$(serving)" "200" "still serving after the gate rejections"

# --- upload: the filename is validated before any file exists ---------------
for bad in "evil.tar.gz" "../../etc/passwd" "$ARCHIVE.bak" "palworld-save-2026.tar.gz" \
           "palworld-save-20260101t000000z.tar.gz" "palworld-save-20260101T000000Z.tar" \
           "sub/$ARCHIVE" ""; do
  assert_eq "$(upload "$WORK/good.bin" "$bad")" "400" "a bad filename is refused: '$bad'"
done
assert_contains "$(body -u "$CREDS" -H "$TOKHDR" -H 'X-Palwarden-Filename: evil.tar.gz' \
  -H 'Expect:' --data-binary '@'"$WORK/good.bin" "$U/api/backups/upload")" \
  "palworld-save-" "the filename rejection says what shape is expected"
# Two filename headers must not let a good value smuggle past a bad one.
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: evil.tar.gz\r\nX-Palwarden-Filename: %s\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/dupname.req"
assert_eq "$(raw "$WORK/dupname.req")" "400" "a duplicated filename header is refused"
# ...in either order. With the good value first, taking "the first one" would accept
# the request, so this is the spelling that pins "exactly one" rather than merely
# re-testing the pattern.
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nX-Palwarden-Filename: evil.tar.gz\r\nContent-Length: 4\r\nConnection: close\r\n\r\nabcd' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/dupname2.req"
assert_eq "$(raw "$WORK/dupname2.req")" "400" \
  "a duplicated filename header is refused with the good value first, too"
assert_eq "$(staged)" "" "no filename rejection stages a file"
assert_eq "$(serving)" "200" "still serving after the filename rejections"

# --- upload: Content-Length framing ---------------------------------------
# Over the cap, refused before a byte is read (there is no body in this request at
# all, which is exactly how we know nothing was read).
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nContent-Length: 3221225472\r\nConnection: close\r\n\r\n' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/overcap.req"
assert_eq "$(raw "$WORK/overcap.req")" "413" "an over-cap Content-Length is 413, before any read"
assert_eq "$(staged)" "" "an over-cap upload stages nothing"
# One byte over the cap, with the body actually present.
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nContent-Length: 200001\r\nConnection: close\r\n\r\n' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/overcap1.req"
cat "$WORK/overcap.bin" >> "$WORK/overcap1.req"
assert_eq "$(raw "$WORK/overcap1.req")" "413" "one byte over the cap is refused"
assert_eq "$(staged)" "" "the one-byte-over upload stages nothing"
# PEP 515 underscores and a leading sign parse in int() but are not HTTP: a proxy
# would frame such a request differently, which is the smuggling case.
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nContent-Length: 1_0\r\nConnection: close\r\n\r\nabcdefghij' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/uslen.req"
assert_eq "$(raw "$WORK/uslen.req")" "400" "an underscored Content-Length is 400"
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nContent-Length: +10\r\nConnection: close\r\n\r\nabcdefghij' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/pluslen.req"
assert_eq "$(raw "$WORK/pluslen.req")" "400" "a signed Content-Length is 400"
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nConnection: close\r\n\r\n' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/nolen.req"
assert_eq "$(raw "$WORK/nolen.req")" "400" "a missing Content-Length is 400"
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/zerolen.req"
assert_eq "$(raw "$WORK/zerolen.req")" "400" "an empty body is 400, not an empty archive on disk"
# Chunked: no Content-Length at all. Must be a clean refusal, never a hang.
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nabcd\r\n0\r\n\r\n' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/chunked.req"
assert_eq "$(raw "$WORK/chunked.req")" "400" "a chunked upload is refused, not left hanging"
# Both headers at once, which is the request-smuggling shape RFC 9112 exists to
# forbid: a proxy in front of us frames this as chunked while a Content-Length
# reader frames it as 4 bytes, and the difference is a request the proxy never saw.
# It is also the *only* case the Transfer-Encoding refusal alone catches — with
# only the chunked-without-length spelling tested, the "exactly one
# Content-Length" check would shield it and the check could be deleted unnoticed.
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\nConnection: close\r\n\r\n4\r\nabcd\r\n0\r\n\r\n' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/chunked-and-length.req"
assert_eq "$(raw "$WORK/chunked-and-length.req")" "400" \
  "an upload with both Transfer-Encoding and Content-Length is refused"
assert_eq "$(staged)" "" "no framing rejection stages a file"
assert_eq "$(serving)" "200" "still serving after the framing rejections"

# --- upload: the happy path ------------------------------------------------
assert_eq "$(upload "$WORK/good.bin" "$ARCHIVE" -H 'Sec-Fetch-Site: same-origin')" "202" \
  "a good upload is accepted"
assert_eq "$(staged)" "$ARCHIVE " "the upload is staged under exactly the validated name"
assert_rc 0 cmp -s "$WORK/good.bin" "$UPLOADS/$ARCHIVE"
assert_eq "$(stat -c %a "$UPLOADS/$ARCHIVE")" "600" "the staged file is owner-only"
assert_eq "$(stat -c %a "$UPLOADS")" "700" "the staging directory is created 0700"
assert_contains "$(body -u "$CREDS" -H "$TOKHDR" -H "X-Palwarden-Filename: $ARCHIVE2" \
  -H 'Expect:' --data-binary '@'"$WORK/second.bin" "$U/api/backups/upload")" \
  "\"staged\": \"$ARCHIVE2\"" "the response names the staged archive"
assert_rc 0 cmp -s "$WORK/second.bin" "$UPLOADS/$ARCHIVE2"
# The staged upload is only ever a file: this process must not have imported it.
assert_path_absent "$BACKUPS/$ARCHIVE2" "the web process never promotes an upload itself"

# Whitespace *around* a header value is OWS, not part of the value (RFC 9110), so
# it is stripped and the upload succeeds — the same rule check_token applies. An
# internal space would still fail the pattern (fullmatch), as would any suffix.
assert_eq "$(upload "$WORK/second.bin" "  $ARCHIVE  ")" "202" \
  "surrounding whitespace in the filename header is stripped, not rejected"
assert_rc 0 cmp -s "$WORK/second.bin" "$UPLOADS/$ARCHIVE"

# Re-uploading the same name replaces it atomically with the *whole* new body —
# never a half-and-half file, because each attempt writes its own unique temp.
assert_eq "$(upload "$WORK/second.bin" "$ARCHIVE")" "202" "re-uploading the same name is accepted"
assert_rc 0 cmp -s "$WORK/second.bin" "$UPLOADS/$ARCHIVE"
assert_eq "$(staged)" "$ARCHIVE $ARCHIVE2 " "no temp files are left behind"

# --- two uploads of the same archive, overlapping --------------------------
# The temp name is unique *per request*, and this is what needs it: a slow upload
# and a fast one of the same archive are in flight at the same time. With a shared
# temp name the second O_EXCL open would fail (500) and the two bodies could
# interleave into a file root would later import. Both must succeed, and the file
# must end up as one whole body — never a mix.
( python3 "$WORK/trickle.py" "$PORT" "$ARCHIVE" 3000 1000 1.5 "$B64" \
    > "$WORK/overlap.code" ) &
OVERLAP_BG=$!
sleep 0.6
assert_eq "$(upload "$WORK/second.bin" "$ARCHIVE")" "202" \
  "an upload accepted while another of the same name is in flight"
wait "$OVERLAP_BG"
assert_eq "$(cat "$WORK/overlap.code")" "202" "the overlapping upload also succeeds"
overlap_size="$(wc -c < "$UPLOADS/$ARCHIVE" | tr -d ' ')"
if [ "$overlap_size" = "3000" ] || [ "$overlap_size" = "78000" ]; then
  pass
else
  fail "overlapping uploads produced a mixed file: $overlap_size bytes"
fi
assert_eq "$(staged)" "$ARCHIVE $ARCHIVE2 " "overlapping uploads leave no temp files"

# --- upload: a body shorter than Content-Length stages nothing --------------
rm -f "$UPLOADS/$ARCHIVE" "$UPLOADS/$ARCHIVE2"
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nContent-Length: 5000\r\nConnection: close\r\n\r\nonly-ten!!' \
  "$PORT" "$B64" "$ARCHIVE" > "$WORK/short.req"
short_code="$(raw "$WORK/short.req" shutdown)"
assert_ne "$short_code" "202" "a truncated body is never accepted"
assert_eq "$(staged)" "" "a truncated upload leaves no staged file and no temp"
assert_eq "$(serving)" "200" "still serving after a truncated upload"

# --- neither existing constant leaked into the other -----------------------
# The 64 KiB job cap still applies to POST /api/jobs...
python3 - "$WORK" <<'EOF'
import json
import sys
head = '{"action":"backup","params":{}'
doc = head + " " * (65537 - len(head) - 1) + "}"
assert len(doc) == 65537 and json.loads(doc)["action"] == "backup"
open(f"{sys.argv[1]}/overcap-job.json", "w").write(doc)
EOF
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
  --data-binary "@$WORK/overcap-job.json" "$U/api/jobs")" "400" \
  "a job body over 64 KiB is still refused (the upload cap did not leak into it)"
assert_contains "$(body -u "$CREDS" -H "$TOKHDR" -H 'Content-Type: application/json' \
  --data-binary "@$WORK/overcap-job.json" "$U/api/jobs")" "at most 65536 bytes" \
  "the job cap is still 64 KiB"
# ...and an upload far above it succeeds (asserted with the happy path above).
assert_eq "$GOOD_BYTES" "150020" "the accepted upload really is well over 64 KiB"

# The upload path's own socket timeout: a body trickled with 1.5s gaps survives
# PALWARDEN_UPLOAD_TIMEOUT=5 here...
assert_eq "$(python3 "$WORK/trickle.py" "$PORT" "$ARCHIVE" 3000 1000 1.5 "$B64")" "202" \
  "a slowly trickled upload survives the upload timeout"
rm -f "$UPLOADS/$ARCHIVE"
# ...and is cut off on a server whose upload timeout is 1s. If the handler
# inherited REQUEST_TIMEOUT (10s) instead of applying its own, this would be a 202.
start_server "$PORT_SLOW" "$WORK/server-slow.log" \
  PALWARDEN_MAX_UPLOAD_BYTES=200000 PALWARDEN_UPLOAD_TIMEOUT=1
PID_SLOW=$!
assert_ne "$(python3 "$WORK/trickle.py" "$PORT_SLOW" "$ARCHIVE" 3000 1000 1.5 "$B64")" "202" \
  "a trickle slower than PALWARDEN_UPLOAD_TIMEOUT is cut off"
assert_eq "$(staged)" "" "the timed-out upload leaves nothing behind"
assert_eq "$(code -u "$CREDS" "http://127.0.0.1:$PORT_SLOW/api/health")" "200" \
  "still serving after a timed-out upload"

# --- upload: no free space is a 507, not a filled volume -------------------
start_server "$PORT_FULL" "$WORK/server-full.log" \
  PALWARDEN_MAX_UPLOAD_BYTES=200000 PALWARDEN_UPLOAD_FREE_MARGIN=1125899906842624
PID_FULL=$!
full_code="$(code -u "$CREDS" -H "$TOKHDR" -H "X-Palwarden-Filename: $ARCHIVE" \
  -H 'Expect:' --data-binary '@'"$WORK/good.bin" \
  "http://127.0.0.1:$PORT_FULL/api/backups/upload")"
assert_eq "$full_code" "507" "an upload with too little free space is 507"
assert_contains "$(body -u "$CREDS" -H "$TOKHDR" -H "X-Palwarden-Filename: $ARCHIVE" \
  -H 'Expect:' --data-binary '@'"$WORK/good.bin" \
  "http://127.0.0.1:$PORT_FULL/api/backups/upload")" "free space" \
  "the 507 says what is wrong"
assert_eq "$(staged)" "" "a 507 stages nothing"
assert_eq "$(code -u "$CREDS" "http://127.0.0.1:$PORT_FULL/api/health")" "200" \
  "still serving after a 507"

# --- the listing hides in-flight and off-pattern files ---------------------
listing="$(body -u "$CREDS" "$U/api/backups")"
assert_contains "$listing" "$ARCHIVE" "the listing shows a real archive"
assert_not_contains "$listing" "$IMPORT_TEMP" \
  "an in-flight import temp file is not listed as a backup"
assert_not_contains "$listing" "operator-notes.txt" "an off-pattern file is not listed"
assert_not_contains "$listing" "$ARCHIVE.bak" "a near-miss name is not listed"

# --- download --------------------------------------------------------------
assert_eq "$(code "$U/api/backups/$ARCHIVE/download")" "401" "download requires auth"
assert_eq "$(code -u "$CREDS" "$U/api/backups/$ARCHIVE/download")" "200" \
  "a valid archive downloads"
curl -s -u "$CREDS" -o "$WORK/downloaded.bin" "$U/api/backups/$ARCHIVE/download"
assert_rc 0 cmp -s "$BACKUPS/$ARCHIVE" "$WORK/downloaded.bin"
hdrs="$(curl -s -D - -o /dev/null -u "$CREDS" "$U/api/backups/$ARCHIVE/download")"
assert_contains "$hdrs" "application/gzip" "the download is served as gzip"
assert_contains "$hdrs" "attachment; filename=\"$ARCHIVE\"" \
  "the download is an attachment named after the archive"
assert_contains "$hdrs" "no-store" "the download is not cached"
assert_contains "$hdrs" "Content-Length: $(wc -c < "$BACKUPS/$ARCHIVE" | tr -d ' ')" \
  "Content-Length comes from the file itself"

# crafted names: 404 every time, and never the planted sentinel
for bad in "evil.tar.gz" "$ARCHIVE.bak" "$IMPORT_TEMP" "operator-notes.txt" \
           "..%2f..%2fetc%2fpasswd" "%2e%2e%2f%2e%2e%2fetc%2fpasswd" "$ARCHIVE%00" \
           "$ARCHIVE%0d%0aX-Injected:%20yes"; do
  assert_eq "$(code -u "$CREDS" "$U/api/backups/$bad/download")" "404" \
    "a crafted download name is 404: '$bad'"
  assert_not_contains "$(body -u "$CREDS" "$U/api/backups/$bad/download")" \
    "PLANTED-TRAVERSAL-TARGET" "'$bad' never serves the planted target"
done
assert_eq "$(code --path-as-is -u "$CREDS" "$U/api/backups/../../etc/passwd/download")" "404" \
  "the un-encoded traversal spelling is refused too"
assert_not_contains "$(body --path-as-is -u "$CREDS" "$U/api/backups/../../etc/passwd/download")" \
  "PLANTED-TRAVERSAL-TARGET" "nor does it serve the planted target"
# A header the response must never have grown from a crafted name.
assert_not_contains "$(curl -s -D - -o /dev/null -u "$CREDS" \
  "$U/api/backups/$ARCHIVE%0d%0aX-Injected:%20yes/download")" "X-Injected" \
  "a CRLF in the name cannot inject a header"

# A symlink planted under a perfectly valid archive name. The backups directory is
# chowned to the service account, so whoever can write there could otherwise choose
# what this endpoint reads.
ln -s "$WORK/etc/passwd" "$BACKUPS/palworld-save-20260104T000000Z.tar.gz"
assert_eq "$(code -u "$CREDS" "$U/api/backups/palworld-save-20260104T000000Z.tar.gz/download")" \
  "404" "a symlink under a valid archive name is refused"
assert_not_contains "$(body -u "$CREDS" \
  "$U/api/backups/palworld-save-20260104T000000Z.tar.gz/download")" \
  "PLANTED-TRAVERSAL-TARGET" "the symlink's target is never served"
# ...and a directory under a valid name is not a file either.
mkdir -p "$BACKUPS/palworld-save-20260105T000000Z.tar.gz"
assert_eq "$(code -u "$CREDS" "$U/api/backups/palworld-save-20260105T000000Z.tar.gz/download")" \
  "404" "a directory under a valid archive name is refused"
# a name that is valid but simply absent
assert_eq "$(code -u "$CREDS" "$U/api/backups/palworld-save-20991231T235959Z.tar.gz/download")" \
  "404" "a well-formed but absent archive is 404"
assert_eq "$(serving)" "200" "still serving after the download rejections"

# a cancelled download is routine, not an error (no traceback, server survives)
curl -s -u "$CREDS" --max-time 0.001 -o /dev/null "$U/api/backups/$ARCHIVE/download" 2>/dev/null
assert_eq "$(serving)" "200" "still serving after an abandoned download"

# --- schedule --------------------------------------------------------------
assert_eq "$(code "$U/api/backup-schedule")" "401" "the schedule requires auth"
assert_eq "$(code -u "$CREDS" "$U/api/backup-schedule")" "200" "the schedule is readable"
sched="$(body -u "$CREDS" "$U/api/backup-schedule")"
assert_contains "$sched" '"ok": true' "the schedule uses the API envelope"
shape="$(printf '%s' "$sched" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
data = doc["data"]
print(",".join(sorted(data)))
print(",".join(type(data[k]).__name__ for k in sorted(data)))
print(data["BACKUP_INTERVAL_HOURS"])')"
assert_eq "$(printf '%s' "$shape" | sed -n 1p)" \
  "BACKUP_ENABLED,BACKUP_INTERVAL_HOURS,BACKUP_KEEP_MIN,BACKUP_RETENTION_DAYS" \
  "the schedule has exactly the four keys"
assert_eq "$(printf '%s' "$shape" | sed -n 2p)" "bool,int,int,int" \
  "the schedule's types are bool,int,int,int"
assert_eq "$(printf '%s' "$shape" | sed -n 3p)" "6" \
  "the schedule reflects the file, not the defaults"

# --- nothing sensitive, and no traceback, in any log ----------------------
for log in "$WORK/server.log" "$WORK/server-slow.log" "$WORK/server-full.log"; do
  assert_not_contains "$(cat "$log")" "tok-for-tests" "token never logged ($log)"
  assert_not_contains "$(cat "$log")" "pw-for-tests" "password never logged ($log)"
  assert_not_contains "$(cat "$log")" "Traceback" "no traceback reached the log ($log)"
done

# --- and the whole surface still works ------------------------------------
assert_eq "$(code -u "$CREDS" "$U/")" "200" "static serving still works"
assert_eq "$(code -u "$CREDS" "$U/api/backups")" "200" "the backups listing still works"
assert_eq "$(code -u "$CREDS" "$U/api/jobs")" "200" "the job API still works"
assert_eq "$(code -u "$CREDS" -X POST -H "$TOKHDR" -d '{}' "$U/api/nope")" "404" \
  "POST to an unknown endpoint is still 404"

assert_report
