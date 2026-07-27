#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Integration tests: build the palwarden image and exercise container scenarios
# with a dummy server (tests/fixtures/fake-server) and a REST stub. Codifies the
# behaviors verified by hand while building the Docker increments.
#
# Requires docker. Slow (builds the image + starts several containers).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/assert.sh"

IMG="palwarden:test"
FAKE="$REPO/tests/fixtures/fake-server"
STUB="$REPO/tests/fixtures/rest-stub.py"
NET="palwarden-itest-net"
CIDS=()

cleanup() {
  for c in "${CIDS[@]:-}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_c() { local name="$1"; shift; CIDS+=("$name"); docker rm -f "$name" >/dev/null 2>&1 || true; docker run -d --name "$name" "$@" >/dev/null; }
wait_up() { docker exec "$1" sh -c 'i=0; until s6-svstat /run/service/'"$2"' 2>/dev/null | grep -q "^up"; do i=$((i+1)); [ $i -gt 25 ] && exit 1; sleep 1; done'; }
services_of() { docker exec "$1" ls /etc/s6-overlay/s6-rc.d/user/contents.d/ 2>/dev/null | tr '\n' ' '; }

echo "  building $IMG ..."
if ! docker build -q -f "$REPO/docker/Dockerfile" -t "$IMG" "$REPO" >/dev/null 2>&1; then
  fail "image build failed"; assert_report; exit 1
fi

# --- Scenario A: embedded, no ADMIN_PASSWORD --------------------------------
run_c pw-it-a -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false -v "$FAKE":/opt/palworld/server "$IMG"
wait_up pw-it-a palworld-server || fail "A: server did not come up"
svcA="$(services_of pw-it-a)"
assert_contains "$svcA" "palworld-server" "A: server enabled"
assert_contains "$svcA" "config-webui" "A: webui enabled"
assert_contains "$svcA" "memory-watch" "A: watchdog enabled"
assert_not_contains "$svcA" "fps-sample" "A: no telemetry without password"
assert_not_contains "$svcA" "daily-report" "A: no report without webhook"

# systemctl shim reports the server active
assert_eq "$(docker exec pw-it-a systemctl is-active palworld.service)" "active" "A: shim is-active"

# --- Scenario B: embedded, ADMIN_PASSWORD + PALWORLD_CFG_* -------------------
run_c pw-it-b -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false \
  -e ADMIN_PASSWORD=not-a-real-admin-password -e "PALWORLD_CFG_SERVER_NAME=Yggdrasil" \
  -v "$FAKE":/opt/palworld/server "$IMG"
wait_up pw-it-b palworld-server || fail "B: server did not come up"
docker exec pw-it-b sh -c 'sleep 2'
svcB="$(services_of pw-it-b)"
assert_contains "$svcB" "fps-sample" "B: telemetry enabled with password"
# settings.env was rendered in-container from env (values are shell-quoted)
assert_rc 0 docker exec pw-it-b grep -qF 'REST_API_ENABLED="True"' /etc/palworld/settings.env
assert_rc 0 docker exec pw-it-b grep -qF 'SERVER_NAME="Yggdrasil"' /etc/palworld/settings.env
assert_rc 0 docker exec pw-it-b grep -qF 'ADMIN_PASSWORD="not-a-real-admin-password"' /etc/palworld/settings.env
# and the config was actually applied to the server's INI (REST enabled)
assert_rc 0 docker exec pw-it-b grep -qF 'RESTAPIEnabled=True' /opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
# config apply was attempted at boot
assert_contains "$(docker logs pw-it-b 2>&1)" "Applying settings.env" "B: config apply attempted"
# telemetry DB is steam-owned (not root), so the sampler can write it
owner="$(docker exec pw-it-b stat -c '%U' /var/lib/palworld/metrics.sqlite3 2>/dev/null)"
assert_eq "$owner" "steam" "B: metrics DB owned by steam"

# --- Scenario C: external mode against the REST stub ------------------------
docker network create "$NET" >/dev/null 2>&1 || true
CIDS+=(pw-it-stub); docker rm -f pw-it-stub >/dev/null 2>&1 || true
docker run -d --name pw-it-stub --network "$NET" -v "$STUB":/stub.py:ro --entrypoint python3 "$IMG" /stub.py >/dev/null
run_c pw-it-c --network "$NET" -e PALWARDEN_MODE=external -e PALWORLD_TARGET_HOST=pw-it-stub \
  -e ADMIN_PASSWORD=not-a-real-admin-password -e FPS_SAMPLE_INTERVAL=1 "$IMG"
# Poll briefly: the entrypoint (credential bootstrap + config render) needs a
# moment before the s6 user-bundle marker appears.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  svcC="$(services_of pw-it-c)"
  [[ "$svcC" == *fps-sample* ]] && break
  sleep 0.5
done
assert_contains "$svcC" "fps-sample" "C: telemetry enabled"
assert_not_contains "$svcC" "palworld-server" "C: no server in external mode"
docker exec pw-it-c sh -c 'sleep 6'
okrows="$(docker exec pw-it-c python3 -c "import sqlite3;print(sqlite3.connect('/var/lib/palworld/metrics.sqlite3').execute('select count(*) from fps_samples where ok=1').fetchone()[0])" 2>/dev/null)"
if [ "${okrows:-0}" -gt 0 ]; then pass; else fail "C: expected ok telemetry rows from stub, got '${okrows:-0}'"; fi

# --- Scenario D: container graceful restart cycles the server ---------------
rp1="$(docker exec pw-it-b s6-svstat /run/service/palworld-server | grep -oE 'pid [0-9]+' | grep -oE '[0-9]+')"
docker exec pw-it-b palworld-graceful-restart --startup-timeout 3 >/dev/null 2>&1
docker exec pw-it-b sh -c 'sleep 4'
rp2="$(docker exec pw-it-b s6-svstat /run/service/palworld-server | grep -oE 'pid [0-9]+' | grep -oE '[0-9]+')"
assert_ne "$rp1" "$rp2" "D: graceful restart cycled the server service"

# --- Scenario E: graceful shutdown saves the world --------------------------
run_c pw-it-e -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false -v "$FAKE":/opt/palworld/server "$IMG"
wait_up pw-it-e palworld-server || fail "E: server did not come up"
docker exec pw-it-e sh -c 'sleep 1'
docker stop --time 60 pw-it-e >/dev/null 2>&1
assert_eq "$(docker inspect -f '{{.State.ExitCode}}' pw-it-e)" "0" "E: clean exit (graceful, not SIGKILL)"
assert_contains "$(docker logs pw-it-e 2>&1)" "world saved, exiting cleanly" "E: server saved on stop"

# --- Scenario F: opt-in services (update-check, public-info-watch) -----------
# PALWORLD_STEAMCMD=/bin/true keeps the update checker from attempting a real
# multi-GB update against the dummy (remote buildid comes back empty -> no-op).
run_c pw-it-f -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false -e ADMIN_PASSWORD=x \
  -e UPDATE_CHECK=true -e PALWORLD_STEAMCMD=/bin/true -e PUBLIC_HOSTNAME=pal.example \
  -v "$FAKE":/opt/palworld/server "$IMG"
wait_up pw-it-f palworld-server || fail "F: server did not come up"
docker exec pw-it-f sh -c 'sleep 1'
svcF="$(services_of pw-it-f)"
assert_contains "$svcF" "update-check" "F: update-check enabled by UPDATE_CHECK=true"
assert_contains "$svcF" "public-info-watch" "F: public-info-watch enabled by PUBLIC_HOSTNAME"
# and they are NOT enabled by default (scenario A had neither flag)
assert_not_contains "$svcA" "update-check" "F: update-check off by default"
assert_not_contains "$svcA" "public-info-watch" "F: public-info-watch off by default"

# --- Scenario G: managed config is left mutable, and engine-config works ------
# We deliberately do NOT lock config (chattr +i): a real-server test showed
# Palworld v1.0.1 rewrites both files but preserves every value, so protection is
# unnecessary. engine-config apply must work regardless (it used to crash here on
# a missing lsattr).
run_c pw-it-g -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false -e ADMIN_PASSWORD=x \
  -v "$FAKE":/opt/palworld/server "$IMG"
wait_up pw-it-g palworld-server || fail "G: server did not come up"
docker exec pw-it-g sh -c 'sleep 1'
# nothing should be immutable (and the image no longer even ships chattr)
out="$(docker exec pw-it-g sh -c 'command -v chattr || true' 2>/dev/null)"
assert_eq "$out" "" "G: chattr not installed (no immutability machinery)"
out="$(docker exec --user root pw-it-g palworld-config-apply-env 2>&1)"; rc=$?
assert_eq "$rc" "0" "G: config apply succeeds"
assert_not_contains "$out" "Operation not permitted" "G: no permission error"
# engine-config apply writes its value and does not traceback
docker exec --user root pw-it-g sh -c '
  mkdir -p /etc/palworld
  printf "[/Script/Engine.Engine]\nNetServerMaxTickRate=30\n" > /opt/palworld/server/Pal/Saved/Config/LinuxServer/Engine.ini
  printf "NET_SERVER_MAX_TICK_RATE=60\n" > /etc/palworld/engine.env' >/dev/null 2>&1
out="$(docker exec --user root pw-it-g palworld-engine-config apply 2>&1)"; rc=$?
assert_eq "$rc" "0" "G: engine-config apply exits 0"
assert_not_contains "$out" "Traceback" "G: engine-config apply does not traceback"
assert_rc 0 docker exec pw-it-g grep -qF "NetServerMaxTickRate=60" \
  /opt/palworld/server/Pal/Saved/Config/LinuxServer/Engine.ini
# and the drift check agrees the applied values are in place
out="$(docker exec --user root pw-it-g palworld-engine-config status --check 2>&1)"; rc=$?
assert_eq "$rc" "0" "G: drift check passes right after apply"

# --- Scenario H: the daily health report knows the service state in-container -
# It asks systemctl for five properties in one call; before the shim handled
# multi -p this line read `unknown/unknown` with a blank PID every day.
out="$(docker exec pw-it-g palworld-health-report report 2>&1)"
assert_contains "$out" "active/running" "H: health report sees the service as active/running"
assert_not_contains "$out" "unknown/unknown" "H: no unknown service state"
assert_contains "$out" "restarts \`n/a\`" "H: unknown restart count reads n/a, not blank"
# the crash/restart watchdog runs and feeds the report a count that IS meaningful
assert_contains "$(services_of pw-it-g)" "service-events" "H: service-events watchdog enabled"
assert_contains "$out" "Detected in" "H: report includes detected restarts/outages"
# a restart the tooling performed is classified as planned, not a crash
docker exec --user root pw-it-g palworld-graceful-restart --startup-timeout 3 >/dev/null 2>&1
docker exec pw-it-g sh -c 'sleep 2; palworld-service-events sample' >/dev/null 2>&1
out="$(docker exec pw-it-g palworld-service-events summary --since 24h 2>&1)"
assert_contains "$out" "restarts detected" "H: service-events summary reports restarts"
assert_not_contains "$out" "Traceback" "H: service-events summary does not crash"
# palworld-status agrees
out="$(docker exec pw-it-g palworld-status 2>&1)"
assert_contains "$out" "state: active" "H: status reports active"

# --- Scenario I: the web UI is authenticated and read-only -----------------
# Basic auth guards every path (the vendored editors included), the API returns
# real JSON, and the server does not run as root.
creds="$(docker exec pw-it-g cat /etc/palworld/webui.env 2>/dev/null)"
assert_contains "$creds" "WEBUI_PASSWORD=" "I: entrypoint generated web UI credentials"
webui_user="$(docker exec pw-it-g sh -c 'sed -n "s/^WEBUI_USER=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"
webui_pass="$(docker exec pw-it-g sh -c 'sed -n "s/^WEBUI_PASSWORD=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"

code() { docker exec pw-it-g sh -c "curl -s -o /dev/null -w '%{http_code}' $1"; }
assert_eq "$(code 'http://127.0.0.1:8088/')" "401" "I: dashboard requires auth"
assert_eq "$(code 'http://127.0.0.1:8088/PalWorldSettingsEditor.html')" "401" "I: editor requires auth"
assert_eq "$(code "-u '$webui_user:$webui_pass' http://127.0.0.1:8088/")" "200" "I: authenticated dashboard loads"
body="$(docker exec pw-it-g sh -c "curl -s -u '$webui_user:$webui_pass' http://127.0.0.1:8088/api/health")"
assert_contains "$body" '"ok"' "I: /api/health returns JSON"
# a POST with Basic auth only is refused: the token header is a separate gate
# (scenario J drives the accepted path end to end).
assert_eq "$(code "-u '$webui_user:$webui_pass' -X POST http://127.0.0.1:8088/api/jobs")" "403" "I: POST without the token header is refused"
# and the server is unprivileged
owner="$(docker exec pw-it-g sh -c 'ps -o user= -p $(pgrep -f palwarden-webui | head -1)' | tr -d " ")"
assert_eq "$owner" "steam" "I: webui runs as steam, not root"

# --- Scenario J: the control plane's privilege split, end to end -------------
# The unprivileged web UI only writes job files; the root worker (jobd) executes
# them. Everything here is observed through the real services in pw-it-g.
assert_contains "$(services_of pw-it-g)" "jobd" "J: job worker enabled in embedded mode"

# Ownership comes from the *running processes*, not the service definitions:
# s6-svstat needs root, so anything asked via `docker exec` (which is root)
# could agree with the service file while the service itself ran as the wrong
# user. The `job[d]` bracket keeps pgrep -f from matching the `sh -c` that
# invokes it — it matches its own command line otherwise.
proc_user() { docker exec "$1" sh -c "ps -o user= -p \$(pgrep -f '$2' | head -1)" | tr -d ' '; }
assert_eq "$(proc_user pw-it-g 'palwarden-job[d]')" "root" "J: jobd runs as root"
assert_eq "$(proc_user pw-it-g 'palwarden-webu[i]')" "steam" "J: webui runs unprivileged"

# The queue is the only channel between them, and it belongs to the web user.
assert_eq "$(docker exec pw-it-g stat -c '%U %a' /var/lib/palworld/jobs)" "steam 700" \
  "J: queue dir owned by the web user, owner-only"

# Basic auth alone must not be able to enqueue: a browser attaches it to a
# cross-origin POST for free, so the token header is the CSRF defence.
csrf_body='{"action":"snapshot_create","params":{"label":"itest-csrf"}}'
csrf_code="$(docker exec pw-it-g sh -c "curl -s -o /dev/null -w '%{http_code}' -X POST \
  -u '$webui_user:$webui_pass' -H 'Content-Type: application/json' \
  -d '$csrf_body' http://127.0.0.1:8088/api/jobs")"
assert_eq "$csrf_code" "403" "J: POST with Basic auth only is refused"

# With both credentials the job is queued (202) and the worker runs it.
# snapshot_create is file-only, needs no confirmation and does not touch the
# running server.
webui_token="$(docker exec pw-it-g sh -c 'sed -n "s/^WEBUI_TOKEN=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"
enq="$(docker exec pw-it-g sh -c "curl -s -w '\n%{http_code}' -X POST \
  -u '$webui_user:$webui_pass' -H 'X-Palwarden-Token: $webui_token' \
  -H 'Content-Type: application/json' \
  -d '{\"action\":\"snapshot_create\",\"params\":{\"label\":\"itest-jobd\"}}' \
  http://127.0.0.1:8088/api/jobs")"
assert_eq "$(printf '%s' "$enq" | tail -1)" "202" "J: POST with both credentials is accepted"
job_id="$(printf '%s' "$enq" | grep -oE '[0-9a-f]{32}' | head -1)"
if [ "${#job_id}" -eq 32 ]; then pass; else fail "J: enqueue returned no job id (response: $enq)"; fi

# Bounded poll: a stuck worker must fail the suite, not hang it.
state=""
for _ in {1..45}; do
  jbody="$(docker exec pw-it-g sh -c "curl -s -u '$webui_user:$webui_pass' \
    http://127.0.0.1:8088/api/jobs/$job_id")"
  state="$(printf '%s' "$jbody" | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' | head -1)"
  case "$state" in
    queued|running|"") sleep 1 ;;
    *) break ;;
  esac
done
assert_eq "$state" "succeeded" "J: the root worker ran the queued job to success"
# and the job's actual effect landed
assert_rc 0 docker exec pw-it-g sh -c 'ls -d /opt/palworld/config-snapshots/*itest-jobd'

# The snapshot root is root-owned and the tool hands out no ownership at all.
# It used to be the reverse — steam-owned root, and the tool chowned each finished
# tree to PALWORLD_USER — which made a root-run snapshot_create an arbitrary root
# write and an arbitrary chown: the directory name is derived from the
# attacker-chosen label, and the tool holds it open across six subprocesses, so the
# owner of the root could rename it and drop a symlink in its place. The container
# is where that ownership is actually decided (Dockerfile `install -d`), so it is
# asserted here rather than only in the unit suite.
assert_eq "$(docker exec pw-it-g stat -c '%U %a' /opt/palworld/config-snapshots)" "root 755" \
  "J: the snapshot root is root-owned 0755, not writable by the web user"
assert_eq "$(docker exec pw-it-g sh -c 'stat -c %U $(ls -d /opt/palworld/config-snapshots/*itest-jobd)')" \
  "root" "J: a root-run snapshot_create leaves the snapshot root-owned"
assert_eq "$(docker exec pw-it-g sh -c 'stat -c %U /opt/palworld/config-snapshots/*itest-jobd/* | sort -u | tr "\n" ","')" \
  "root," "J: ...and every file inside it, so nothing was handed to a lesser account"
# The unprivileged side must still be able to *list* them, which is all it does.
snap_api="$(docker exec pw-it-g sh -c "curl -s -u '$webui_user:$webui_pass' \
  http://127.0.0.1:8088/api/snapshots")"
assert_contains "$snap_api" "itest-jobd" "J: /api/snapshots still lists it as the unprivileged user"

# --- Scenario K: the `backup` action end to end ------------------------------
# Nothing covered this action anywhere, and it could not possibly have worked in
# the container: palworld-backup hardcoded `-o palworld -g palworld`, and there is
# no `palworld` account in this image, so install's owner flag failed with
# "invalid user" before tar ever ran. The container is the only place that is
# exercised, so the assertion belongs here.
#
# /opt/palworld/backups was also missing from the Dockerfile's `install -d` list,
# so /api/backups was permanently empty until the first successful backup.
assert_eq "$(docker exec pw-it-g stat -c '%U %a' /opt/palworld/backups)" "root 755" \
  "K: the save-backup root exists in the image, root-owned 0755"

# Seed a SaveGames tree: the tool tars exactly SaveGames + Config, and the fake
# server fixture ships neither (Pal/Saved is gitignored precisely because the tests
# write into it), so without this the tar would fail for an unrelated reason and
# hide whatever the action actually does.
docker exec pw-it-g sh -c 'install -d -o steam -g steam /opt/palworld/server/Pal/Saved/SaveGames/0 \
  && printf "fake level data\n" > /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav'

bk_enq="$(docker exec pw-it-g sh -c "curl -s -w '\n%{http_code}' -X POST \
  -u '$webui_user:$webui_pass' -H 'X-Palwarden-Token: $webui_token' \
  -H 'Content-Type: application/json' \
  -d '{\"action\":\"backup\",\"params\":{}}' \
  http://127.0.0.1:8088/api/jobs")"
assert_eq "$(printf '%s' "$bk_enq" | tail -1)" "202" "K: a backup job is accepted"
bk_id="$(printf '%s' "$bk_enq" | grep -oE '[0-9a-f]{32}' | head -1)"
if [ "${#bk_id}" -eq 32 ]; then pass; else fail "K: enqueue returned no job id (response: $bk_enq)"; fi

bk_state=""; bk_body=""
for _ in {1..60}; do
  bk_body="$(docker exec pw-it-g sh -c "curl -s -u '$webui_user:$webui_pass' \
    http://127.0.0.1:8088/api/jobs/$bk_id")"
  bk_state="$(printf '%s' "$bk_body" | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' | head -1)"
  case "$bk_state" in
    queued|running|"") sleep 1 ;;
    *) break ;;
  esac
done
assert_eq "$bk_state" "succeeded" "K: the backup action reaches succeeded through jobd"
# The specific pre-fix failure, named, so a future regression is unmistakable.
assert_not_contains "$bk_body" "invalid user" "K: no 'invalid user' from a hardcoded account name"
# ...and it really produced an archive, not just a zero exit.
assert_rc 0 docker exec pw-it-g sh -c 'ls /opt/palworld/backups/palworld-save-*.tar.gz'
assert_rc 0 docker exec pw-it-g sh -c 'tar -tzf /opt/palworld/backups/palworld-save-*.tar.gz | grep -q .'
# The archive is handed to the service account (safe: the directory is root-owned,
# so the name cannot be substituted), and the unprivileged /api/backups sees it.
assert_eq "$(docker exec pw-it-g sh -c 'stat -c %U /opt/palworld/backups/palworld-save-*.tar.gz')" \
  "steam" "K: the archive owner comes from PALWORLD_USER, which is steam here"
bk_api="$(docker exec pw-it-g sh -c "curl -s -u '$webui_user:$webui_pass' \
  http://127.0.0.1:8088/api/backups")"
assert_contains "$bk_api" "palworld-save-" "K: /api/backups is no longer permanently empty"

assert_report
