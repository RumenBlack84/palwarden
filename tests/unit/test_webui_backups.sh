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
PORT_HUGE=18094
PORT_BADPERM=18093
PORT_INF=18092
PID=""
PID_SLOW=""
PID_FULL=""
PID_HUGE=""
PID_BADPERM=""
PID_INF=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  [ -n "$PID_SLOW" ] && kill "$PID_SLOW" 2>/dev/null
  [ -n "$PID_FULL" ] && kill "$PID_FULL" 2>/dev/null
  [ -n "$PID_HUGE" ] && kill "$PID_HUGE" 2>/dev/null
  [ -n "$PID_BADPERM" ] && kill "$PID_BADPERM" 2>/dev/null
  [ -n "$PID_INF" ] && kill "$PID_INF" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

ARCHIVE="palworld-save-20260101T000000Z.tar.gz"
ARCHIVE2="palworld-save-20260102T000000Z.tar.gz"
ARCHIVE3="palworld-save-20260106T000000Z.tar.gz"

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

# --- upload: a body longer than Content-Length is truncated, not overrun ----
# The success path is the one path in this handler that does not set
# close_connection, which is exactly the shape that would desync under the
# one-line `protocol_version = "HTTP/1.1"` switch this file promises three times
# is safe: only Content-Length bytes may ever be consumed from the socket, with
# the rest left for whatever request follows on a kept-alive connection.
python3 -c 'open("'"$WORK"'/longbody.bin", "wb").write(b"A" * 5000)'
{
  printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nContent-Length: 10\r\nConnection: close\r\n\r\n' \
    "$PORT" "$B64" "$ARCHIVE3"
  cat "$WORK/longbody.bin"
} > "$WORK/longbody.req"
assert_eq "$(raw "$WORK/longbody.req")" "202" \
  "a body longer than Content-Length is still accepted"
assert_eq "$(wc -c < "$UPLOADS/$ARCHIVE3" | tr -d ' ')" "10" \
  "the staged file is exactly the Content-Length, not the whole body sent"
assert_eq "$(serving)" "200" "still serving after a body longer than Content-Length"
rm -f "$UPLOADS/$ARCHIVE3"

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

# --- a non-finite PALWARDEN_UPLOAD_TIMEOUT falls back to the default, warned --
# float("inf") passes the old `> 0` check, but socket.settimeout(inf) raises
# OverflowError deep inside the upload path (turning every upload into a leaked
# fd, a leaked temp file, and a 500). The override must be rejected at
# module-load time instead, with the default used and a warning logged.
start_server "$PORT_INF" "$WORK/server-inf.log" \
  PALWARDEN_MAX_UPLOAD_BYTES=200000 PALWARDEN_UPLOAD_TIMEOUT=inf
PID_INF=$!
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H "X-Palwarden-Filename: $ARCHIVE2" \
  -H 'Expect:' --data-binary '@'"$WORK/second.bin" \
  "http://127.0.0.1:$PORT_INF/api/backups/upload")" "202" \
  "PALWARDEN_UPLOAD_TIMEOUT=inf falls back to the default instead of 500ing"
assert_contains "$(cat "$WORK/server-inf.log")" "warning:" \
  "the non-finite override is logged as a warning at startup"
assert_not_contains "$(cat "$WORK/server-inf.log")" "Traceback" \
  "the non-finite override never reaches a traceback"
assert_eq "$(code -u "$CREDS" "http://127.0.0.1:$PORT_INF/api/health")" "200" \
  "still serving with a non-finite upload timeout override"
rm -f "$UPLOADS/$ARCHIVE2"

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

# --- upload: the free-space check bounds the upload itself, not just the margin
# (the `free < length + UPLOAD_FREE_MARGIN` comparison at :937 has two terms that
# can each shield the other from a single-check mutation: dropping UPLOAD_FREE_MARGIN
# leaves this passing because `length` alone still bounds it, and dropping `length`
# leaves the PORT_FULL test above passing because the margin alone still bounds it).
# Default margin (no override) and a MAX_UPLOAD_BYTES far above anything a real disk
# could hold, so only `length` itself can be doing the work here: a Content-Length of
# "everything free, plus a spare gigabyte" must still 507, before a byte is read.
start_server "$PORT_HUGE" "$WORK/server-huge.log" \
  PALWARDEN_MAX_UPLOAD_BYTES=1125899906842624
PID_HUGE=$!
AVAIL="$(df --output=avail -B1 "$WORK" | tail -1 | tr -d ' ')"
HUGE_LEN=$((AVAIL + 1073741824))
printf 'POST /api/backups/upload HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nAuthorization: Basic %s\r\nX-Palwarden-Token: tok-for-tests\r\nX-Palwarden-Filename: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
  "$PORT_HUGE" "$B64" "$ARCHIVE" "$HUGE_LEN" > "$WORK/toobig.req"
assert_eq "$(python3 "$WORK/raw.py" "$PORT_HUGE" "$WORK/toobig.req")" "507" \
  "a Content-Length larger than free space is 507 even with a comfortable margin, no body sent"
assert_eq "$(staged)" "" "the oversized-length request stages nothing"
assert_eq "$(code -u "$CREDS" "http://127.0.0.1:$PORT_HUGE/api/health")" "200" \
  "still serving after the oversized-length 507"

# --- upload: an existing staging directory's mode and owner are checked ----
# mkdir(..., mode=0700) only applies the mode on *creation*; a directory a
# hand-rolled deploy left group/other-readable (or owned by someone else) would
# otherwise be accepted forever. Uses its own staging directory, pre-created 0755,
# so the shared $UPLOADS used by every other server in this file (created 0700 by
# the very first server) is untouched.
BADPERM_UPLOADS="$WORK/vol/uploads-badperm"
mkdir -p "$BADPERM_UPLOADS"
chmod 0755 "$BADPERM_UPLOADS"
start_server "$PORT_BADPERM" "$WORK/server-badperm.log" \
  PALWARDEN_UPLOAD_DIR="$BADPERM_UPLOADS" PALWARDEN_MAX_UPLOAD_BYTES=200000
PID_BADPERM=$!
assert_eq "$(code -u "$CREDS" -H "$TOKHDR" -H "X-Palwarden-Filename: $ARCHIVE" \
  -H 'Expect:' --data-binary '@'"$WORK/good.bin" \
  "http://127.0.0.1:$PORT_BADPERM/api/backups/upload")" "500" \
  "a pre-existing 0755 staging directory is refused, not silently accepted"
assert_eq "$(stat -c %a "$BADPERM_UPLOADS")" "755" \
  "the refusal does not itself fix the directory (that is the operator's job)"
assert_eq "$(find "$BADPERM_UPLOADS" -mindepth 1 | wc -l | tr -d ' ')" "0" \
  "the bad-permission refusal stages nothing"
assert_eq "$(code -u "$CREDS" "http://127.0.0.1:$PORT_BADPERM/api/health")" "200" \
  "still serving after the bad-permission refusal"

# --- the listing hides in-flight and off-pattern files ---------------------
# Debris that sorts *above* the real archive (a far-future date is lexically
# greater), planted past the 50-entry limit `_list_dir` applies: if the name filter
# ran after the limit instead of before it, these 51 entries alone would fill every
# slot and $ARCHIVE would never reach the response the assertions below check.
for i in $(seq 1 51); do
  printf 'debris' > "$BACKUPS/palworld-save-21000101T000000Z.tar.gz.import.fake$i"
done
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
for log in "$WORK/server.log" "$WORK/server-slow.log" "$WORK/server-full.log" \
           "$WORK/server-huge.log" "$WORK/server-badperm.log" "$WORK/server-inf.log"; do
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

# ===========================================================================
# The Backups page (Task 7)
#
# Everything above proves the server's half of the panel. This section proves the
# browser page speaks it: the right actions with the right params, the token from
# /api/token into sessionStorage, and — the reason this page exists in this suite
# rather than only in test_webui_jobs.sh — that DELETE really is three steps.
#
# Preferring node-executed checks over greps: a grep that "Delete" appears twice
# says nothing about *when* the request goes out, and the whole point of the flow
# is that the first two steps send nothing.
# ===========================================================================
PAGE="$REPO/webui/backups.html"
DASH="$REPO/webui/palwarden.html"
EDITOR="$REPO/webui/EngineIniPerformanceEditor.html"

assert_file_exists "$PAGE" "the Backups page exists"
assert_file_contains "$PAGE" "SPDX-License-Identifier: AGPL-3.0-or-later" \
  "the Backups page carries the AGPL identifier"
assert_file_contains "$PAGE" "SPDX-FileCopyrightText: 2026 Brian Grant" \
  "the Backups page carries our copyright"
assert_file_contains "$PAGE" "CREDITS.md" "the Backups page notes its MIT derivation"
# The vendored editor is MIT and byte-identical; it carries no palwarden nav at all
# (it never had one), so it is deliberately NOT given the Backups tab. The two
# first-party nav-bearing pages are.
assert_rc 0 git -C "$REPO" diff --quiet -- webui/PalWorldSettingsEditor.html
assert_file_not_contains "$REPO/webui/PalWorldSettingsEditor.html" "backups.html" \
  "the vendored editor is untouched, nav included"
for nav_page in "$PAGE" "$DASH" "$EDITOR"; do
  assert_file_contains "$nav_page" 'href="backups.html"' \
    "$(basename "$nav_page") links to the Backups tab"
  assert_file_contains "$nav_page" 'href="palwarden.html"' \
    "$(basename "$nav_page") links to the Dashboard tab"
  assert_file_contains "$nav_page" 'href="PalWorldSettingsEditor.html"' \
    "$(basename "$nav_page") links to the Server settings tab"
  assert_file_contains "$nav_page" 'href="EngineIniPerformanceEditor.html"' \
    "$(basename "$nav_page") links to the Engine.ini tab"
done
assert_file_contains "$PAGE" 'href="backups.html" aria-current="page"' \
  "the Backups page marks its own tab as current"

# the four actions this page is allowed to enqueue, and no other
for action in "'backup'" "'backup_import'" "'backup_restore'" "'backup_delete'" \
              "'backup_schedule_save'"; do
  assert_file_contains "$PAGE" "runJob($action" "the page enqueues $action"
done
assert_file_not_contains "$PAGE" "'graceful_stop'" \
  "the page does not stop the server behind the restore's back"
assert_file_not_contains "$PAGE" "palworld-backups --delete" \
  "the page never claims to run a tool itself"

# token handling, identical to the Engine editor's
assert_file_contains "$PAGE" "X-Palwarden-Token" "mutations send the token header"
assert_file_contains "$PAGE" "sessionStorage.getItem" "the token is read from sessionStorage"
assert_file_not_contains "$PAGE" "localStorage" "the token never lands in localStorage"
assert_file_contains "$PAGE" "'/api/token'" "the token comes from /api/token"
assert_file_not_contains "$PAGE" "document.cookie" "the token is never put in a cookie"
assert_file_not_contains "$PAGE" "Authorization: Bearer" \
  "the token does not try to share the Basic auth header"
# the upload's own two requirements
assert_file_contains "$PAGE" "'/api/backups/upload'" "the import uploads to the upload endpoint"
assert_file_contains "$PAGE" "X-Palwarden-Filename" "the upload names the file in the header"
assert_file_contains "$PAGE" "body: file" "the File is the raw request body"
assert_file_contains "$PAGE" "/download" "each row can download its archive"
# the vocabulary the design spec fixes
assert_file_contains "$PAGE" 'class="pw-confirm"' "confirmations use pw-confirm"
assert_file_contains "$PAGE" "showModal" "the dialogs are modal (focus-trapped, Esc cancels)"
assert_file_contains "$PAGE" "confirm: true" "the irreversible bodies carry confirm: true"
assert_file_contains "$PAGE" 'class="pw-log' "job progress goes in a pw-log region"
assert_file_contains "$PAGE" 'aria-live="polite"' "the job log is announced politely"
assert_file_contains "$PAGE" 'id="toast"' "outcomes go in a pw-toast"
assert_file_contains "$PAGE" "No backups yet" "the empty list says so"
assert_file_contains "$PAGE" "prefers-reduced-motion" "the transition respects reduced motion"
assert_file_not_contains "$PAGE" "WEBUI_PASSWORD" "no credential baked into the page"

# --- structural invariants a grep cannot express ---------------------------
# 1. no HTML-parsing sink, no raw colour outside :root, no inline style (the same
#    three the editor and the dashboard are held to, applied here as well; the
#    guard in tests/unit/test_webui_jobs.sh covers all three pages together, this
#    is the copy that fails in *this* suite when the page itself regresses).
# 2. every class the page uses already exists in the two sibling pages: the design
#    spec fixes the component vocabulary, and a new class here is a new component
#    nobody reviewed.
# 3. both delete dialogs (and the restore dialog) put Cancel first AND give it the
#    autofocus, so the destructive button is never the default target.
# 4. every runJob payload carries only params the *worker* recognises, read out of
#    palwarden-jobd's own ACTIONS table rather than duplicated here.
structural="$(python3 - "$PAGE" "$DASH" "$EDITOR" "$REPO/sbin/palwarden-jobd" <<'PY'
import re
import sys

page_path, dash_path, editor_path, jobd_path = sys.argv[1:5]
src = open(page_path, encoding="utf-8").read()
bad = []

# 1. sinks / colours / inline styles
SINKS = (
    (r"\.innerHTML\s*=\s*([^;\n]*)", "innerHTML"),
    (r"\.outerHTML\s*=\s*([^;\n]*)", "outerHTML"),
    (r"\.insertAdjacentHTML\s*\(([^;\n]*)", "insertAdjacentHTML"),
    (r"\bdocument\.write(?:ln)?\s*\(([^;\n]*)", "document.write"),
    (r"\.setHTMLUnsafe\s*\(([^;\n]*)", "setHTMLUnsafe"),
    (r"<template\b", "template element"),
)
COLOR_PATTERNS = (
    r"#[0-9a-fA-F]{3,8}\b",
    r"\b(?:rgb|rgba|hsl|hsla|hwb|lab|lch|oklab|oklch|color|color-mix)\s*\(",
)
for pattern, label in SINKS:
    for m in re.finditer(pattern, src):
        arg = (m.group(1).strip() if m.groups() else "")
        if label == "innerHTML" and arg in ('""', "''"):
            continue
        bad.append("HTML sink used: %s (%r)" % (label, arg or m.group(0)))
style = re.search(r"<style>(.*?)</style>", src, re.S)
if not style:
    bad.append("no <style> block")
else:
    css = style.group(1)
    root = re.search(r":root\s*\{.*?\}", css, re.S)
    if not root:
        bad.append("no :root token block")
    outside = css.replace(root.group(0), "") if root else css
    for pattern in COLOR_PATTERNS:
        for m in re.finditer(pattern, outside):
            bad.append("raw colour outside :root: %s" % m.group(0))
if re.search(r"\sstyle=", src):
    bad.append("inline style attribute")

# 2. no new class names
def classes(text):
    found = set()
    for m in re.finditer(r'class="([^"]*)"', text):
        found.update(m.group(1).split())
    for m in re.finditer(r"""\.className\s*=\s*['"]([^'"]*)['"]""", text):
        found.update(m.group(1).split())
    for m in re.finditer(r"""classList\.(?:add|remove|toggle)\(\s*['"]([^'"]*)['"]""", text):
        found.update(m.group(1).split())
    return found

known = classes(open(dash_path, encoding="utf-8").read())
known |= classes(open(editor_path, encoding="utf-8").read())
for cls in sorted(classes(src)):
    # A dynamic suffix ("pw-pill pw-pill--" + state) leaves a prefix token behind;
    # accept it only when it really is the prefix of a class the vocabulary has.
    if cls in known or any(k.startswith(cls) for k in known):
        continue
    bad.append("new class name: %s" % cls)

# 3. the dialogs
dialogs = re.findall(r"<dialog\b[^>]*id=\"([^\"]+)\"[^>]*>(.*?)</dialog>", src, re.S)
if len(dialogs) != 3:
    bad.append("expected 3 pw-confirm dialogs (restore + two delete steps), found %d"
               % len(dialogs))
for dlg_id, body in dialogs:
    buttons = re.findall(r"<button\b([^>]*)>", body)
    if len(buttons) != 2:
        bad.append("%s has %d buttons, expected Cancel + one confirm" % (dlg_id, len(buttons)))
        continue
    first, second = buttons
    autofocused = [attrs for attrs in buttons if "autofocus" in attrs]
    if len(autofocused) != 1:
        bad.append("%s has %d autofocus buttons, expected exactly 1" % (dlg_id, len(autofocused)))
    for attrs in autofocused:
        if "pw-btn--danger" in attrs:
            bad.append("%s: the DESTRUCTIVE button carries autofocus" % dlg_id)
        if "-cancel" not in attrs:
            bad.append("%s: autofocus is not on the cancel button" % dlg_id)
    # DOM order matters too: it decides the default target if a browser ever
    # ignores autofocus on a dialog that has already been shown once.
    if "pw-btn--danger" in first:
        bad.append("%s: the destructive button comes first in DOM order" % dlg_id)
    if "pw-btn--danger" not in second:
        bad.append("%s: the confirming button is not marked pw-btn--danger" % dlg_id)
    if "-cancel" not in first:
        bad.append("%s: the first button is not the cancel button" % dlg_id)

# 4. payload keys, against the worker's own table
jobd = open(jobd_path, encoding="utf-8").read()
table = re.search(r"^ACTIONS: dict\[str, dict\] = \{(.*?)^\}", jobd, re.S | re.M)
if not table:
    bad.append("could not find ACTIONS in palwarden-jobd")
    allowed = {}
else:
    allowed = {}
    for m in re.finditer(r'"([a-z_]+)":\s*\{(.*?)\},\n', table.group(1) + "\n", re.S):
        action, spec = m.group(1), m.group(2)
        params = re.search(r'"params":\s*\(([^)]*)\)', spec)
        names = set(re.findall(r'"([a-z_]+)"', params.group(1))) if params else set()
        if re.search(r'"disruptive":\s*True', spec):
            names.add("confirm")
        allowed[action] = names
    for needed in ("backup", "backup_import", "backup_restore", "backup_delete",
                   "backup_schedule_save"):
        if needed not in allowed:
            bad.append("ACTIONS parse missed %s" % needed)

calls = re.findall(r"runJob\(\s*'([a-z_]+)'\s*,\s*\{([^}]*)\}", src)
seen = set()
for action, params in calls:
    seen.add(action)
    keys = set(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", params))
    if action not in allowed:
        bad.append("%s is not an action the worker knows" % action)
        continue
    for key in sorted(keys - allowed[action]):
        bad.append("%s passes a param the worker does not recognise: %s" % (action, key))
    if action in ("backup_delete", "backup_restore") and "confirm: true" not in params:
        bad.append("%s is missing confirm: true" % action)
    if action in ("backup", "backup_import", "backup_schedule_save") and "confirm" in keys:
        bad.append("%s is not disruptive and must not send confirm" % action)
expected_actions = {"backup", "backup_import", "backup_restore", "backup_delete",
                    "backup_schedule_save"}
if seen != expected_actions:
    bad.append("the page enqueues %s, expected %s"
               % (sorted(seen), sorted(expected_actions)))

print("OK" if not bad else "; ".join(bad))
PY
)"
assert_eq "$structural" "OK" "the Backups page's DOM/CSS/dialog/payload invariants hold"

# --- node: the three-step delete, driven for real --------------------------
# Extracts the page's own deleteArchive() and the two message builders, then runs
# them against a stubbed openConfirm/runJob. This is the check that fails if the
# flow ever collapses into "one dialog, then send".
js_block() {  # js_block <file> <awk-start-regex> <awk-end-regex>
  awk -v s="$2" -v e="$3" '$0 ~ s {f=1} f{print} f && $0 ~ e {exit}' "$1"
}
if command -v node >/dev/null 2>&1; then
  DEL_JS="$WORK/delete-flow.js"
  {
    js_block "$PAGE" '^function formatBytes' '^}'
    js_block "$PAGE" '^function formatWhen' '^}'
    js_block "$PAGE" '^function deleteFirstMessage' '^}'
    js_block "$PAGE" '^function deleteFinalMessage' '^}'
    js_block "$PAGE" '^async function deleteArchive' '^}'
  } > "$DEL_JS"
  cat >> "$DEL_JS" <<'EOF'

let failures = 0;
function check(desc, cond) { if (!cond) { failures++; console.log("FAIL: " + desc); } }

// Stubs. Anything that would reach the network or the DOM is recorded instead.
let dialogs = [], answers = [], posted = [], logs = [], refreshed = 0;
function log(line) { logs.push(String(line)); }
async function loadArchives() { refreshed++; }
async function runJob(action, params) { posted.push({ action: action, params: params }); return { ok: true, id: "job-1" }; }
async function openConfirm(id, title, message, okLabel) {
  dialogs.push({ id: id, title: title, message: message, okLabel: okLabel });
  if (!answers.length) throw new Error("openConfirm called more often than the test allowed: " + id);
  return answers.shift();
}
function reset(replies) { dialogs = []; answers = replies.slice(); posted = []; logs = []; refreshed = 0; }

const ENTRY = { name: "palworld-save-20260101T000000Z.tar.gz", bytes: 150020, modified: 1767225600 };

(async () => {
  // formatting, pinned with literal expectations (the dialogs quote these)
  check("bytes under 1 KiB are plain", formatBytes(512) === "512 B");
  check("KiB gets one decimal under 10", formatBytes(1536) === "1.5 KiB");
  check("KiB is rounded over 10", formatBytes(150020) === "147 KiB");
  check("GiB scales", formatBytes(5 * 1024 * 1024 * 1024) === "5.0 GiB");
  check("a missing size is named, not NaN", formatBytes(undefined) === "unknown size");
  check("the date is rendered in UTC", formatWhen(1767225600) === "2026-01-01 00:00:00Z");
  check("a missing date is named", formatWhen(0) === "unknown date");

  // STEP 1 -> cancel: nothing is sent, and only the first dialog was opened.
  reset([false]);
  await deleteArchive(ENTRY, 3);
  check("cancelling the first dialog sends NOTHING", posted.length === 0);
  check("cancelling the first dialog opens exactly one dialog", dialogs.length === 1);
  check("the first dialog is the first delete dialog", dialogs[0].id === "confirm-delete-1");
  check("the first dialog names the archive in its title", String(dialogs[0].title).indexOf(ENTRY.name) !== -1);
  check("the first dialog names the archive in its body", dialogs[0].message.indexOf(ENTRY.name) !== -1);
  check("the first dialog names the size", dialogs[0].message.indexOf("147 KiB") !== -1);
  check("the first dialog names the date", dialogs[0].message.indexOf("2026-01-01 00:00:00Z") !== -1);
  check("a first-step cancel refreshes nothing", refreshed === 0);
  check("a first-step cancel is logged as sending nothing", logs.some(l => /nothing was sent/.test(l)));

  // STEP 2 -> cancel: the second dialog was reached, and still nothing is sent.
  reset([true, false]);
  await deleteArchive(ENTRY, 3);
  check("confirming ONLY the first dialog sends NOTHING", posted.length === 0);
  check("confirming the first dialog opens the second", dialogs.length === 2);
  check("the second dialog is the final one", dialogs[1].id === "confirm-delete-2");
  check("the final dialog says it cannot be recovered", /cannot be recovered/i.test(dialogs[1].message));
  check("the final dialog names the archive", dialogs[1].message.indexOf(ENTRY.name) !== -1);
  check("the final dialog does not cry 'only archive' when there are three",
        !/ONLY archive/.test(dialogs[1].message));
  check("a second-step cancel refreshes nothing", refreshed === 0);
  check("a second-step cancel is logged as sending nothing", logs.some(l => /nothing was sent/.test(l)));

  // BOTH confirmed: exactly one POST, with confirm: true and nothing else.
  reset([true, true]);
  await deleteArchive(ENTRY, 3);
  check("both confirmations send exactly one job", posted.length === 1);
  check("the job is backup_delete", posted[0].action === "backup_delete");
  check("the payload names the archive", posted[0].params.backup === ENTRY.name);
  check("the payload carries confirm: true", posted[0].params.confirm === true);
  check("the payload carries only backup and confirm",
        JSON.stringify(Object.keys(posted[0].params).sort()) === '["backup","confirm"]');
  check("the list refreshes after a real delete", refreshed === 1);
  check("two dialogs were shown, not one", dialogs.length === 2);

  // The only-archive case: the last backup there is must say so out loud.
  reset([true, true]);
  await deleteArchive(ENTRY, 1);
  check("the final dialog says it is the only archive", /ONLY archive/.test(dialogs[1].message));
  check("...and says there would then be no backup at all",
        /no backup of this world at all/.test(dialogs[1].message));
  check("deleteFinalMessage(entry, 1) says only", /ONLY archive/.test(deleteFinalMessage(ENTRY, 1)));
  check("deleteFinalMessage(entry, 2) does not", !/ONLY archive/.test(deleteFinalMessage(ENTRY, 2)));

  console.log(failures === 0 ? "OK" : "FAIL");
})();
EOF
  del_out="$(node "$DEL_JS" 2>&1)"
  assert_eq "$del_out" "OK" "deleteArchive() extracted from the page really is three steps"

  # --- node: the row renderer, against a hostile archive name --------------
  # The API would refuse this name, which is exactly why the renderer is driven
  # directly: the page's own escaping must not depend on the server's filter.
  REN_JS="$WORK/render-archives.js"
  {
    js_block "$PAGE" '^function formatBytes' '^}'
    js_block "$PAGE" '^function formatWhen' '^}'
    grep '^function el(' "$PAGE"
    js_block "$PAGE" '^function renderArchives' '^}'
  } > "$REN_JS"
  cat >> "$REN_JS" <<'EOF'

let failures = 0;
function check(desc, cond) { if (!cond) { failures++; console.log("FAIL: " + desc); } }

// A DOM stub that makes every HTML sink an immediate failure: if the renderer
// ever reaches for one, this throws instead of quietly "working".
function node(tag) {
  const self = {
    tag: tag, children: [], attrs: {}, props: {}, _text: "", listeners: 0,
    classList: {
      _c: new Set(),
      contains(c) { return this._c.has(c); },
      add(c) { this._c.add(c); },
      remove(c) { this._c.delete(c); },
      toggle(c, on) { if (on) this._c.add(c); else this._c.delete(c); },
    },
    append(...kids) { for (const k of kids) self.children.push(k); },
    appendChild(k) { self.children.push(k); },
    setAttribute(k, v) { self.attrs[k] = String(v); },
    addEventListener() { self.listeners++; },
  };
  Object.defineProperty(self, "textContent", {
    get() { return self._text; },
    set(v) { self._text = String(v); self.children = []; },
  });
  for (const sink of ["innerHTML", "outerHTML"]) {
    Object.defineProperty(self, sink, {
      set(v) { throw new Error("the renderer assigned " + sink); },
    });
  }
  self.insertAdjacentHTML = () => { throw new Error("the renderer used insertAdjacentHTML"); };
  self.setHTMLUnsafe = () => { throw new Error("the renderer used setHTMLUnsafe"); };
  return self;
}
const ROOT = node("div");
global.document = { createElement: node, getElementById: (id) => (id === "archives" ? ROOT : null) };
function walk(n, out) {
  out.push(n);
  for (const k of n.children) walk(k, out);
  return out;
}

const HOSTILE = '<img src=x onerror=alert(1)>';

// the empty case: the fresh-install message, marked pw-empty
renderArchives([]);
check("an empty list renders one node", ROOT.children.length === 1);
check("the empty list says 'No backups yet'", ROOT.children[0]._text === "No backups yet");
check("the empty placeholder is pw-empty", ROOT.children[0].className === "pw-empty");

renderArchives([
  { name: HOSTILE, bytes: 1536, modified: 1767225600 },
  { name: "palworld-save-20260102T000000Z.tar.gz", bytes: 150020, modified: 1785159909 },
]);
check("one row per archive", ROOT.children.length === 2);
const nodes = walk(ROOT, []);
const texts = nodes.map(n => n._text);
check("the hostile name is present as ONE literal text value", texts.indexOf(HOSTILE) !== -1);
check("no node holds an escaped or partial version of it",
      !texts.some(t => t !== HOSTILE && t.indexOf("<img") !== -1));
check("nothing double-escapes the name", !texts.some(t => t.indexOf("&lt;") !== -1));
check("the row shows the formatted size", texts.indexOf("1.5 KiB") !== -1);
check("the row shows the formatted date", texts.indexOf("2026-01-01 00:00:00Z") !== -1);
check("the second row shows its own date", texts.indexOf("2026-07-27 13:45:09Z") !== -1);

const links = nodes.filter(n => n.tag === "a");
check("each row has a download link", links.length === 2);
check("the hostile name is percent-encoded into the URL",
      links[0].href === "/api/backups/" + encodeURIComponent(HOSTILE) + "/download");
check("the download href carries no raw angle bracket", links[0].href.indexOf("<") === -1);
check("the download is an attachment named after the archive", links[0].download === HOSTILE);

const buttons = nodes.filter(n => n.tag === "button");
check("each row has Restore and Delete", buttons.length === 4);
check("Restore and Delete are marked destructive",
      buttons.every(b => String(b.className).indexOf("pw-btn--danger") !== -1));
check("every row control is wired to a handler", buttons.every(b => b.listeners === 1));
check("the row labels are plain text",
      buttons.map(b => b._text).join(",") === "Restore,Delete,Restore,Delete");

console.log(failures === 0 ? "OK" : "FAIL");
EOF
  ren_out="$(node "$REN_JS" 2>&1)"
  assert_eq "$ren_out" "OK" "renderArchives() renders a hostile archive name as literal text"

  # --- node: the schedule form --------------------------------------------
  # All four keys every time (the worker refuses a partial save on purpose), the
  # enabled flag as a real JSON boolean, and a refusal shown back verbatim.
  SCH_JS="$WORK/schedule.js"
  {
    js_block "$PAGE" '^const SCHEDULE_FIELDS' '^]'
    js_block "$PAGE" '^function collectSchedule' '^}'
    js_block "$PAGE" '^async function saveSchedule' '^}'
  } > "$SCH_JS"
  cat >> "$SCH_JS" <<'EOF'

let failures = 0;
function check(desc, cond) { if (!cond) { failures++; console.log("FAIL: " + desc); } }

let STATE = {};
function el(id) { return STATE[id]; }
function form(enabled, interval, retention, keepmin) {
  STATE = {
    "sched-enabled": { checked: enabled },
    "sched-interval": { value: interval },
    "sched-retention": { value: retention },
    "sched-keepmin": { value: keepmin },
  };
}
let status = [];
function setStatus(id, message, empty) { status.push({ id: id, message: message, empty: empty }); }
let posted = [], reply = { ok: true, id: "job-1" };
async function runJob(action, params) { posted.push({ action: action, params: params }); return reply; }

(async () => {
  form(true, "6", " 30 ", "5");
  const got = collectSchedule();
  check("all four keys are collected",
        JSON.stringify(Object.keys(got).sort()) ===
        '["BACKUP_ENABLED","BACKUP_INTERVAL_HOURS","BACKUP_KEEP_MIN","BACKUP_RETENTION_DAYS"]');
  check("BACKUP_ENABLED is a real JSON boolean", got.BACKUP_ENABLED === true);
  check("the numbers are digit strings", got.BACKUP_INTERVAL_HOURS === "6");
  check("whitespace is trimmed", got.BACKUP_RETENTION_DAYS === "30");
  check("no number is sent as a JSON boolean",
        !/"BACKUP_(INTERVAL_HOURS|RETENTION_DAYS|KEEP_MIN)":(true|false)/.test(JSON.stringify(got)));

  // off is still sent — an omitted BACKUP_ENABLED would be refused, and a
  // "false means leave it out" bug is exactly what that refusal exists for
  form(false, "1", "1", "1");
  check("disabling still posts BACKUP_ENABLED", collectSchedule().BACKUP_ENABLED === false);
  check("disabling still posts all four keys", Object.keys(collectSchedule()).length === 4);

  // the happy save
  form(true, "6", "30", "5");
  posted = []; status = []; reply = { ok: true, id: "job-1" };
  await saveSchedule();
  check("saving posts exactly one job", posted.length === 1);
  check("saving posts backup_schedule_save", posted[0].action === "backup_schedule_save");
  check("the payload carries only settings",
        JSON.stringify(Object.keys(posted[0].params)) === '["settings"]');
  check("the payload carries all four keys", Object.keys(posted[0].params.settings).length === 4);
  check("the success message says it takes effect on the next tick",
        /next scheduled tick/.test(status[status.length - 1].message));

  // the worker's refusal, verbatim
  const REFUSAL = "BACKUP_INTERVAL_HOURS must be an integer 1-720, got 0";
  form(true, "0", "30", "5");
  posted = []; status = []; reply = { ok: false, error: REFUSAL };
  await saveSchedule();
  check("an out-of-range value still reaches the worker (it is the authority)", posted.length === 1);
  check("the worker's refusal is shown verbatim",
        status[status.length - 1].message === REFUSAL);
  check("the refusal is not styled as an empty placeholder",
        !status[status.length - 1].empty);

  console.log(failures === 0 ? "OK" : "FAIL");
})();
EOF
  sch_out="$(node "$SCH_JS" 2>&1)"
  assert_eq "$sch_out" "OK" "the schedule form posts all four keys and shows a refusal verbatim"

  # --- node: the upload itself --------------------------------------------
  # The one request on this page that is not a job: the File goes out as the raw
  # body with the validated name in a header, and a 403 discards the cached token
  # so the operator's retry can just work.
  UP_JS="$WORK/upload.js"
  {
    grep '^const TOKEN_KEY' "$PAGE"
    js_block "$PAGE" '^function formatBytes' '^}'
    js_block "$PAGE" '^function errText' '^}'
    js_block "$PAGE" '^async function stageUpload' '^}'
  } > "$UP_JS"
  cat >> "$UP_JS" <<'EOF'

let failures = 0;
function check(desc, cond) { if (!cond) { failures++; console.log("FAIL: " + desc); } }

const logs = [], toasts = [];
let busy = [];
function log(l) { logs.push(String(l)); }
function toast(ok, m) { toasts.push({ ok: ok, message: String(m) }); }
function setBusy(b) { busy.push(b); }
async function token() { return "T-tok"; }
let store = { "palwarden-token": "T-tok" };
global.sessionStorage = {
  getItem(k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
  setItem(k, v) { store[k] = String(v); },
  removeItem(k) { delete store[k]; },
};
let seen = null, responder = null;
global.fetch = async (url, opts) => { seen = { url: url, opts: opts }; return responder(); };
function json(status, body) {
  return { status: status, ok: status >= 200 && status < 300, json: async () => body };
}
const FILE = { name: "palworld-save-20260101T000000Z.tar.gz", size: 150020 };
function reset(r) { logs.length = 0; toasts.length = 0; busy = []; seen = null; responder = r; }

(async () => {
  reset(() => json(202, { ok: true, data: { staged: FILE.name, bytes: FILE.size } }));
  let res = await stageUpload(FILE);
  check("a good upload reports the staged name", res.ok && res.staged === FILE.name);
  check("the upload POSTs to the upload endpoint", seen.url === "/api/backups/upload");
  check("the upload is a POST", seen.opts.method === "POST");
  check("the File itself is the request body", seen.opts.body === FILE);
  check("the filename travels in the header",
        seen.opts.headers["X-Palwarden-Filename"] === FILE.name);
  check("the upload carries the token header",
        seen.opts.headers["X-Palwarden-Token"] === "T-tok");
  check("the upload is not sent as form data",
        seen.opts.headers["Content-Type"] === "application/octet-stream");
  check("progress is reported while streaming", logs.some(l => /uploading .* to the staging area/.test(l)));
  check("the size is shown in the progress line", logs.some(l => l.indexOf("147 KiB") !== -1));
  check("the controls are re-enabled on the happy path",
        busy[0] === true && busy[busy.length - 1] === false);

  // a refusal: the reason is handed back (not written to the DOM here, where
  // setBusy's syncImport would overwrite it), and the controls come back
  reset(() => json(400, { ok: false, error: "X-Palwarden-Filename must be an archive name this project wrote" }));
  res = await stageUpload(FILE);
  check("a refused upload reports not-ok", res.ok === false);
  check("a refused upload hands back the server's reason verbatim",
        res.error === "X-Palwarden-Filename must be an archive name this project wrote");
  check("a refused upload toasts the failure", toasts.length === 1 && toasts[0].ok === false);
  check("the controls are re-enabled after a refusal", busy[busy.length - 1] === false);

  // a 403 discards the cached token so a retry re-fetches it
  reset(() => json(403, { ok: false, error: "origin not allowed" }));
  res = await stageUpload(FILE);
  check("a 403 upload fails", res.ok === false);
  check("a 403 discards the cached token", !("palwarden-token" in store));
  check("a 403 says the token was discarded", /discarded/.test(res.error));

  // a body that is not JSON at all must not throw past the caller
  reset(() => ({ status: 502, ok: false, json: async () => { throw new Error("not json"); } }));
  res = await stageUpload(FILE);
  check("an unparseable response is reported, not thrown", res.ok === false && /502/.test(res.error));
  check("the controls are re-enabled after a parse failure", busy[busy.length - 1] === false);

  // a hard network failure
  reset(() => { throw new Error("network down"); });
  res = await stageUpload(FILE);
  check("a network failure is reported", res.ok === false && /network down/.test(res.error));
  check("the controls are re-enabled after a network failure", busy[busy.length - 1] === false);

  console.log(failures === 0 ? "OK" : "FAIL");
})();
EOF
  up_out="$(node "$UP_JS" 2>&1)"
  assert_eq "$up_out" "OK" "stageUpload() streams the File with the validated name and recovers from every failure"
elif [ -n "${CI:-}" ]; then
  # These three are the only checks that execute the page's own code. Silently
  # skipping them when a runner image changes would delete the panel's behavioural
  # coverage — the three-step delete above all — without anyone noticing.
  fail "node is required in CI to execute the Backups page's delete flow, renderer and schedule form"
else
  echo "  (skipping the node checks of the Backups page: node not found)" >&2
fi

assert_report
