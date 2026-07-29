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
FAKE_REST="$REPO/tests/fixtures/fake-server-rest"
NET="palwarden-itest-net"
CIDS=()
# Scratch server trees for the scenarios that let the tooling *rewrite* the world
# (the restore loop renames Pal/Saved aside and extracts a new one). The other
# scenarios bind-mount the fixture directly, which is fine because they only ever
# read it; a restore would leave debris in the repo.
TMPDIRS=()

cleanup() {
  for c in "${CIDS[@]:-}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
  for d in "${TMPDIRS[@]:-}"; do
    if [ -n "$d" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

run_c() { local name="$1"; shift; CIDS+=("$name"); docker rm -f "$name" >/dev/null 2>&1 || true; docker run -d --name "$name" "$@" >/dev/null; }
wait_up() { docker exec "$1" sh -c 'i=0; until s6-svstat /run/service/'"$2"' 2>/dev/null | grep -q "^up"; do i=$((i+1)); [ $i -gt 25 ] && exit 1; sleep 1; done'; }
services_of() { docker exec "$1" ls /etc/s6-overlay/s6-rc.d/user/contents.d/ 2>/dev/null | tr '\n' ' '; }

echo "  building $IMG ..."
# PALWARDEN_DOCKER_BUILD_OPTS: extra `docker build` options, word-split on
# purpose (e.g. --network=host on hosts whose bridge-network DNS cannot resolve).
read -ra BUILD_OPTS <<< "${PALWARDEN_DOCKER_BUILD_OPTS:-}"
if ! docker build "${BUILD_OPTS[@]}" -q -f "$REPO/docker/Dockerfile" -t "$IMG" "$REPO" >/dev/null 2>&1; then
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
# A private copy of the fixture, like scenarios L and M. pw-it-g is the container
# scenarios H-K all reuse, and scenario K writes a SaveGames tree into the server
# path: with the repo's fixture bind-mounted that landed in the *working tree*, so
# every run pre-seeded the next one and the suite passed only on a polluted
# checkout (on a fresh clone Pal/Saved does not exist at all — it is gitignored
# apart from the one tracked save).
GWORK="$(mktemp -d)"; TMPDIRS+=("$GWORK")
cp -r "$FAKE" "$GWORK/server"
run_c pw-it-g -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false -e ADMIN_PASSWORD=x \
  -v "$GWORK/server":/opt/palworld/server "$IMG"
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

# Scheduled backups are on by default, and this container set no BACKUP_* variable
# at all, so the `backup-auto` service's very first tick already made an archive:
# no archive exists on a fresh host, which makes a backup due immediately rather
# than one interval from now. That is the intended behaviour on a rebuilt host, and
# it is asserted here because it means the directory is NOT empty when the explicit
# `backup` action below runs — the assertions after it therefore name one archive
# instead of globbing, which used to match exactly one file.
#
# Counting files is not enough, and that is not hypothetical: a tar run against a
# Saved tree with no SaveGames exits 2 and — before palworld-backup wrote through a
# `.partial` — still left a Config-only archive at the final name. The count was
# green over a *failed* backup, and the archive was root-owned because the chown
# only happens on the success path. So assert what the tick actually reported: the
# if-due decision and the path palworld-backup printed on success.
bk_logs="$(docker logs pw-it-g 2>&1)"
assert_contains "$bk_logs" "[periodic:backup-auto]" "K: the scheduled tick is running"
assert_contains "$bk_logs" "if-due: due - no archive exists" \
  "K: ...and found a backup due on first boot (no archive yet)"
assert_contains "$bk_logs" "/opt/palworld/backups/palworld-save-" \
  "K: ...and palworld-backup printed the archive it finished writing"
assert_not_contains "$bk_logs" "backup failed with exit code" "K: the boot tick did not fail"
bk_boot="$(docker exec pw-it-g sh -c 'ls -1 /opt/palworld/backups | wc -l')"
if [ "${bk_boot:-0}" -ge 1 ]; then pass; else
  fail "K: the scheduled tick should have made a backup on first boot, found $bk_boot"
fi
# No half-written archive is left in the directory either — the partial is
# dot-prefixed, so a plain `ls -1` above would not have counted one.
assert_eq "$(docker exec pw-it-g sh -c 'ls -1A /opt/palworld/backups | grep -c "^\." || true')" "0" \
  "K: and no .partial is left behind"

# Refresh the SaveGames tree the tick just archived. The fixture ships
# SaveGames/0/Level.sav (tracked, so a fresh clone has it — that is what the boot
# tick tarred); this only re-states it as steam-owned for the explicit job below,
# and never touches the repository: pw-it-g mounts a private copy.
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
# ...and it really produced an archive, not just a zero exit. The newest by name
# (the name carries a UTC stamp that sorts lexically) is the one this job wrote;
# the boot tick's archive is older. Named rather than globbed because the glob now
# matches more than one file, and `tar -tzf` with two operands is an error.
bk_name="$(docker exec pw-it-g sh -c 'ls -1 /opt/palworld/backups | sort | tail -1')"
assert_contains "$bk_name" "palworld-save-" "K: the job produced an archive ($bk_name)"
bk_after="$(docker exec pw-it-g sh -c 'ls -1 /opt/palworld/backups | wc -l')"
assert_eq "$bk_after" "$((bk_boot + 1))" "K: ...one more than before the job ran"
assert_rc 0 docker exec pw-it-g sh -c "tar -tzf '/opt/palworld/backups/$bk_name' | grep -q ."
# The archive is handed to the service account (safe: the directory is root-owned,
# so the name cannot be substituted), and the unprivileged /api/backups sees it.
# sort -u over every archive, so this covers the scheduled tick's as well as this
# job's: both run as root through the same tool, and either one leaving a root-owned
# archive behind is the same bug.
assert_eq "$(docker exec pw-it-g sh -c 'stat -c %U /opt/palworld/backups/palworld-save-*.tar.gz | sort -u | tr "\n" ","')" \
  "steam," "K: every archive's owner comes from PALWORLD_USER, which is steam here"
bk_api="$(docker exec pw-it-g sh -c "curl -s -u '$webui_user:$webui_pass' \
  http://127.0.0.1:8088/api/backups")"
assert_contains "$bk_api" "palworld-save-" "K: /api/backups is no longer permanently empty"

# --- Scenario L: the full recovery loop, through the real API ----------------
# Everything the backup panel promises, in one chain and with nothing stubbed:
#
#   create a backup -> download it -> DELETE the archive -> upload the downloaded
#   bytes back -> import -> restore -> the world is the one we backed up.
#
# Each link was unit-tested against fakes in tasks 1-7 and none of them had ever
# run against the other links, a real jobd, a real webui, or a real supervisor.
# The chain is the feature; this is the only place it exists.
#
# A private copy of the REST-serving fixture, for two reasons. (1) A restore
# rewrites Pal/Saved (renames the old tree aside and extracts a new one), so
# bind-mounting the repo's fixture would leave debris in the working tree.
# (2) palworld-restore only deletes the replaced tree on a *confirmed* startup —
# `palworld-api info` answering — and the plain fake server serves no REST, which
# would leave the restore permanently "unverifiable" and hide the confirmed-startup
# branch entirely.
LWORK="$(mktemp -d)"; TMPDIRS+=("$LWORK")
cp -r "$FAKE_REST" "$LWORK/server"
# BACKUP_ENABLED=false so the scheduled tick (scenario M's subject) cannot slip an
# extra archive into the directory between "delete the only archive" and "check it
# is gone". The panel's own actions are all explicit here.
run_c pw-it-l -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false \
  -e ADMIN_PASSWORD=not-a-real-admin-password -e BACKUP_ENABLED=false \
  -v "$LWORK/server":/opt/palworld/server "$IMG"
wait_up pw-it-l palworld-server || fail "L: server did not come up"

# The two directories this feature adds, with deliberately OPPOSITE ownership.
# Both are packaged (Dockerfile) and re-created by the entrypoint, and both are
# 0700 — but for opposite reasons, so they are asserted separately rather than in
# one loop.
#
# The staging dir belongs to the *web* user: palwarden-webui streams uploads into
# it and refuses an upload outright unless it owns the directory with no
# group/other bits, so a root-owned one breaks every upload. Before this it existed
# only because the web handler mkdir'd it on demand.
assert_eq "$(docker exec pw-it-l stat -c '%U %a' /var/lib/palworld/uploads)" "steam 700" \
  "L: the upload staging dir is web-owned 0700 (packaged, not created on demand)"
# The scratch dir is root:root, and so is its parent. palworld-restore validates
# its *copy* of an archive there because archives in the backups directory are
# chowned to the service account and are therefore web-writable — validating one
# in place would prove the name and not the bytes. Under /var/lib/palworld (which
# steam owns, 0755) steam could rename root's directory aside and substitute its
# own between the copy and the read, and a swapped archive would restore while
# reporting success. Hence /opt/palworld, which is root-owned.
assert_eq "$(docker exec pw-it-l stat -c '%U %a' /opt/palworld/restore-scratch)" "root 700" \
  "L: the restore scratch dir is root:root 0700"
assert_eq "$(docker exec pw-it-l stat -c '%U' /opt/palworld)" "root" \
  "L: ...and so is its parent, which is the half that makes it root-only"

# Privilege split, read off the *running processes* rather than the service
# definitions: s6-svstat needs root, so anything asked through `docker exec` (which
# is root) could agree with the service file while the service itself ran as the
# wrong user. Same bracket trick as scenario J against pgrep matching its own shell.
assert_eq "$(proc_user pw-it-l 'palwarden-job[d]')" "root" "L: jobd runs as root"
assert_eq "$(proc_user pw-it-l 'palwarden-webu[i]')" "steam" "L: webui runs unprivileged"

l_user="$(docker exec pw-it-l sh -c 'sed -n "s/^WEBUI_USER=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"
l_pass="$(docker exec pw-it-l sh -c 'sed -n "s/^WEBUI_PASSWORD=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"
l_tok="$(docker exec pw-it-l sh -c 'sed -n "s/^WEBUI_TOKEN=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"

# Enqueue one job through the real endpoint with the real gate (Basic + token) and
# wait for the root worker to finish it. Sets JOB_ID/JOB_STATE/JOB_BODY. Every poll
# is bounded, so a worker that wedges fails the suite instead of hanging it.
l_job() {  # l_job <json-body> <tries>
  local body="$1" tries="$2" enq i
  JOB_ID=""; JOB_STATE=""; JOB_BODY=""
  enq="$(docker exec pw-it-l sh -c "curl -s -w '\n%{http_code}' -X POST \
    -u '$l_user:$l_pass' -H 'X-Palwarden-Token: $l_tok' \
    -H 'Content-Type: application/json' -d '$body' \
    http://127.0.0.1:8088/api/jobs")"
  if [ "$(printf '%s' "$enq" | tail -1)" != "202" ]; then
    JOB_STATE="not-accepted"; JOB_BODY="$enq"; return 0
  fi
  JOB_ID="$(printf '%s' "$enq" | grep -oE '[0-9a-f]{32}' | head -1)"
  for ((i = 0; i < tries; i++)); do
    JOB_BODY="$(docker exec pw-it-l sh -c "curl -s -u '$l_user:$l_pass' \
      http://127.0.0.1:8088/api/jobs/$JOB_ID")"
    JOB_STATE="$(printf '%s' "$JOB_BODY" | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' | head -1)"
    case "$JOB_STATE" in queued|running|"") sleep 1 ;; *) break ;; esac
  done
}

# A world with a marker we can recognise later: the whole point of a restore is
# that the bytes come back, and "a tree exists" would pass even if the archive were
# empty.
docker exec pw-it-l sh -c 'install -d -o steam -g steam /opt/palworld/server/Pal/Saved/SaveGames/0 \
  && printf "world-marker-ORIGINAL\n" > /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav'

# 1. Create a backup through the API.
l_job '{"action":"backup","params":{}}' 60
assert_eq "$JOB_STATE" "succeeded" "L1: a backup job runs to success (body: $JOB_BODY)"
l_name="$(docker exec pw-it-l sh -c 'ls -1 /opt/palworld/backups | head -1')"
assert_contains "$l_name" "palworld-save-" "L1: it produced an archive ($l_name)"

# 2. Download it, byte for byte. This is the operator's off-host copy, and it is
#    the only thing that survives step 3.
dl_code="$(docker exec pw-it-l sh -c "curl -s -o /tmp/dl.tar.gz -w '%{http_code}' \
  -u '$l_user:$l_pass' http://127.0.0.1:8088/api/backups/$l_name/download")"
assert_eq "$dl_code" "200" "L2: GET /api/backups/<name>/download answers 200"
# Byte-identical, not merely non-empty: a truncated download would still import and
# still restore *something*, and the failure would surface as a corrupt world.
# Both hashes are captured and compared as values. The earlier form piped the two
# through `sort -u | wc -l` and asserted "1", which cannot tell "the two hashes
# agree" from "only one hash was produced" — a sha256sum that failed outright would
# have passed it.
dl_sum="$(docker exec pw-it-l sh -c "sha256sum < /tmp/dl.tar.gz" | awk '{print $1}')"
ar_sum="$(docker exec pw-it-l sh -c "sha256sum < '/opt/palworld/backups/$l_name'" | awk '{print $1}')"
if [ "${#dl_sum}" -eq 64 ]; then pass; else fail "L2: no hash for the downloaded copy (got '$dl_sum')"; fi
assert_eq "$dl_sum" "$ar_sum" "L2: the downloaded bytes are identical to the archive"

# 3. Delete the archive through the API. Disruptive, so it needs confirm: true —
#    and after this the downloaded bytes are the only copy in existence.
l_job "{\"action\":\"backup_delete\",\"params\":{\"backup\":\"$l_name\",\"confirm\":true}}" 45
assert_eq "$JOB_STATE" "succeeded" "L3: backup_delete runs to success (body: $JOB_BODY)"
assert_rc 1 docker exec pw-it-l test -e "/opt/palworld/backups/$l_name"
l_api="$(docker exec pw-it-l sh -c "curl -s -u '$l_user:$l_pass' \
  http://127.0.0.1:8088/api/backups")"
assert_not_contains "$l_api" "$l_name" "L3: and /api/backups no longer lists it"

# Now break the live world, so a restore that silently did nothing cannot pass.
docker exec pw-it-l sh -c \
  'printf "world-marker-CORRUPTED\n" > /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav'

# 4. Upload the downloaded bytes back. The body IS the archive (no multipart) and
#    the name travels in X-Palwarden-Filename; 202, because the archive is only
#    *accepted for import* — nothing has been promoted or restored yet.
up_code="$(docker exec pw-it-l sh -c "curl -s -o /tmp/up.json -w '%{http_code}' -X POST \
  -u '$l_user:$l_pass' -H 'X-Palwarden-Token: $l_tok' \
  -H 'X-Palwarden-Filename: $l_name' -H 'Content-Type: application/octet-stream' \
  -H 'Expect:' --data-binary @/tmp/dl.tar.gz \
  http://127.0.0.1:8088/api/backups/upload")"
assert_eq "$up_code" "202" "L4: the upload is accepted (202)"
# Written by the unprivileged process, into its own directory, owner-only.
assert_eq "$(docker exec pw-it-l stat -c '%U %a' "/var/lib/palworld/uploads/$l_name")" \
  "steam 600" "L4: the staged upload is web-owned 0600"

# 5. Import: root promotes the staged upload into the root-owned backups dir,
#    validating a copy rather than the web-writable original.
l_job "{\"action\":\"backup_import\",\"params\":{\"staged\":\"$l_name\"}}" 60
assert_eq "$JOB_STATE" "succeeded" "L5: backup_import runs to success (body: $JOB_BODY)"
assert_rc 0 docker exec pw-it-l test -f "/opt/palworld/backups/$l_name"
assert_rc 1 docker exec pw-it-l test -e "/var/lib/palworld/uploads/$l_name"

# 6. Restore. Stops the server, takes a safety archive of the (corrupted) world,
#    extracts beside the target, swaps by rename, restarts and confirms readiness.
l_job "{\"action\":\"backup_restore\",\"params\":{\"backup\":\"$l_name\",\"wait\":0,\"confirm\":true}}" 150
assert_eq "$JOB_STATE" "succeeded" "L6: backup_restore runs to success (body: $JOB_BODY)"

# 7. The world came back. This single assertion is what the whole chain is for.
assert_eq "$(docker exec pw-it-l cat /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav)" \
  "world-marker-ORIGINAL" "L7: the restored world is the one that was backed up"
assert_eq "$(docker exec pw-it-l stat -c '%U' /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav)" \
  "steam" "L7: and the restored tree belongs to the service account, not root"
assert_eq "$(docker exec pw-it-l systemctl is-active palworld.service)" "active" \
  "L7: the server is running again after the restore"

# The safety net actually fired: the corrupted world was archived before being
# replaced, so there are two archives now and the operator can undo the undo.
l_count="$(docker exec pw-it-l sh -c 'ls -1 /opt/palworld/backups | wc -l')"
assert_eq "$l_count" "2" "L7: a pre-restore safety archive was taken as well"
assert_contains "$JOB_BODY" "safety backup:" "L7: ...and the job output names it"
# Deleting the replaced tree hangs on a *positive* readiness confirmation, never on
# the absence of an error. The REST-serving fixture is what lets that branch run at
# all, so assert it ran rather than assuming it.
assert_contains "$JOB_BODY" "cleaned up: removed the replaced world" \
  "L7: the replaced tree is removed only on a confirmed startup"
assert_eq "$(docker exec pw-it-l sh -c 'ls -d /opt/palworld/server/Pal/Saved.replaced-* 2>/dev/null | wc -l')" \
  "0" "L7: ...so none is left behind"

# --- Scenario M: the scheduled tick is wired to the supervisor ---------------
# The tick is what makes backups happen without an operator, and it is enabled on
# every embedded boot. What it does on each tick is the *tool's* decision, read
# from /etc/palworld/backup.env — which is why the service stays enabled even with
# backups switched off.
MWORK="$(mktemp -d)"; TMPDIRS+=("$MWORK")
cp -r "$FAKE" "$MWORK/server"
run_c pw-it-m -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false -e ADMIN_PASSWORD=x \
  -e BACKUP_ENABLED=false -e BACKUP_INTERVAL_HOURS=1 -e BACKUP_TICK_SECONDS=2 \
  -v "$MWORK/server":/opt/palworld/server "$IMG"
wait_up pw-it-m palworld-server || fail "M: server did not come up"
assert_contains "$(services_of pw-it-m)" "backup-auto" "M: the scheduled-backup service is enabled"
# ...and it is not one of the opt-in services: scenario A ran with no BACKUP_* env
# at all and must still have it, because switching backups off is BACKUP_ENABLED's
# job, not a service to disable.
assert_contains "$svcA" "backup-auto" "M: enabled by default, not gated on a BACKUP_* variable"

# Root, like memory-watch and jobd and unlike config-webui: the backups directory
# is root-owned, palworld-backup reads the whole world tree, and --prune unlinks in
# a root-owned directory. Asserted on the running process for scenario J's reason.
assert_eq "$(proc_user pw-it-m 'run-periodic 2 backup-aut[o]')" "root" \
  "M: the scheduled-backup service runs as root"

# The schedule was seeded from BACKUP_* env into the file the tool reads.
assert_rc 0 docker exec pw-it-m grep -qx 'BACKUP_ENABLED=false' /etc/palworld/backup.env
assert_rc 0 docker exec pw-it-m grep -qx 'BACKUP_INTERVAL_HOURS=1' /etc/palworld/backup.env
# Unset keys are left out entirely, so the tool's own defaults apply rather than
# being frozen into the file by the container that happened to start first.
assert_rc 1 docker exec pw-it-m grep -q 'BACKUP_RETENTION_DAYS' /etc/palworld/backup.env
# The unprivileged half sees the same effective schedule the tick will use.
m_user="$(docker exec pw-it-m sh -c 'sed -n "s/^WEBUI_USER=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"
m_pass="$(docker exec pw-it-m sh -c 'sed -n "s/^WEBUI_PASSWORD=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"
m_sched="$(docker exec pw-it-m sh -c "curl -s -u '$m_user:$m_pass' \
  http://127.0.0.1:8088/api/backup-schedule")"
assert_contains "$m_sched" '"BACKUP_ENABLED": false' "M: /api/backup-schedule reports the seeded schedule"
assert_contains "$m_sched" '"BACKUP_RETENTION_DAYS": 14' "M: ...with the tool's default for the keys the file omits"

# A world worth backing up, so "nothing was created" cannot pass for the trivial
# reason that there was nothing to tar.
docker exec pw-it-m sh -c 'install -d -o steam -g steam /opt/palworld/server/Pal/Saved/SaveGames/0 \
  && printf "unscheduled\n" > /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav'
# Two ticks at BACKUP_TICK_SECONDS=2, plus slack.
docker exec pw-it-m sh -c 'sleep 8'
m_logs="$(docker logs pw-it-m 2>&1)"
# The tick really ran — without this the assertion below would also pass on a
# service that never started.
assert_contains "$m_logs" "[periodic:backup-auto]" "M: the tick is running"
assert_contains "$m_logs" "scheduled backups are disabled" "M: ...and reports why it created nothing"
assert_eq "$(docker exec pw-it-m sh -c 'ls -1 /opt/palworld/backups | wc -l')" "0" \
  "M: BACKUP_ENABLED=false creates nothing"

# --- Scenario N: restore where Pal/Saved is its own mount point ---------------
# **This is the layout every real deployment uses, and no tier had ever tested
# it.** `/opt/palworld/server/Pal/Saved` is a separate mount in both compose files
# — a named volume in `docker/compose.yaml`, a bind mount in
# `docker/compose.live.yaml` — and the restore's swap was two renames of the
# directories themselves. `rename(2)` on a mount point is EBUSY (errno 16), so
# `--restore` could not succeed in any Docker deployment at all.
#
# Nothing caught it because nothing had met a mount point: the unit suite points
# PALWORLD_SAVED_DIR at a plain `mktemp -d`, and scenario L above — which runs a
# genuine end-to-end restore and asserts the world comes back — mounts only
# `/opt/palworld/server`, which leaves `Pal/Saved` an ordinary subdirectory. The
# suite proved the restore worked in a layout no deployment uses.
#
# So this is scenario L's shape (real backup, real corruption, real restore through
# the real jobd, world asserted back) over the *deliberate* mount layout, and L is
# left exactly as it was: the two layouts are different risks and both are now
# covered. Verified to fail with EBUSY when the swap is reverted to renaming the
# directory.
NWORK="$(mktemp -d)"; TMPDIRS+=("$NWORK")
cp -r "$FAKE_REST" "$NWORK/server"
# The mount source is its own directory on the host, which is what makes Pal/Saved
# a separate *mount* inside the container. Note "mount", not "filesystem": both
# bind mounts come off the same host filesystem and report the same st_dev, and
# rename(2) across the boundary is refused anyway — see the probe below.
# Anything the fixture ships under
# Pal/Saved has to be seeded into it rather than left underneath the mount, where
# it would be invisible — the fixture ships nothing there today, so this is
# conditional rather than a `|| true` that would also swallow a real copy failure.
mkdir -p "$NWORK/saved"
if [ -d "$NWORK/server/Pal/Saved" ]; then
  cp -r "$NWORK/server/Pal/Saved/." "$NWORK/saved/" \
    || fail "N: could not seed the Pal/Saved mount source"
fi
run_c pw-it-n -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false \
  -e ADMIN_PASSWORD=not-a-real-admin-password -e BACKUP_ENABLED=false \
  -v "$NWORK/server":/opt/palworld/server \
  -v "$NWORK/saved":/opt/palworld/server/Pal/Saved "$IMG"
wait_up pw-it-n palworld-server || fail "N: server did not come up"

# The premise of the whole scenario, asserted rather than assumed. If this is not a
# mount point the test is worthless — it silently degrades into a second copy of L,
# which is exactly the failure mode that let the bug ship. Read from
# /proc/self/mountinfo, which is the kernel's own answer and needs no tooling in
# the image.
assert_rc 0 docker exec pw-it-n sh -c \
  "grep -qE ' /opt/palworld/server/Pal/Saved ' /proc/self/mountinfo"
# And the premise stated as the syscall itself, which is stronger than any
# structural reading of the mount table: `rename(2)` on this directory must fail
# with EBUSY. This is the exact call the restore used to make, so if this probe ever
# starts succeeding the scenario has stopped testing anything and says so here
# rather than by quietly passing.
#
# Note it is NOT enough to compare st_dev with the parent's: two bind mounts from
# the same host filesystem report the *same* device number, and the rename is still
# refused — measured. A device comparison would have silently passed as "not a
# mount point".
n_probe="$(docker exec pw-it-n python3 -c '
import os
try:
    os.rename("/opt/palworld/server/Pal/Saved",
              "/opt/palworld/server/Pal/Saved.rename-probe")
except OSError as exc:
    print("errno=%d" % exc.errno)
else:
    os.rename("/opt/palworld/server/Pal/Saved.rename-probe",
              "/opt/palworld/server/Pal/Saved")
    print("errno=0")
')"
assert_eq "$n_probe" "errno=16" \
  "N: renaming Pal/Saved really is EBUSY here - the premise of this whole scenario"

n_user="$(docker exec pw-it-n sh -c 'sed -n "s/^WEBUI_USER=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"
n_pass="$(docker exec pw-it-n sh -c 'sed -n "s/^WEBUI_PASSWORD=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"
n_tok="$(docker exec pw-it-n sh -c 'sed -n "s/^WEBUI_TOKEN=\"\(.*\)\"$/\1/p" /etc/palworld/webui.env')"

# Same bounded enqueue-and-wait as scenario L, against this container.
n_job() {  # n_job <json-body> <tries>
  local body="$1" tries="$2" enq i
  JOB_ID=""; JOB_STATE=""; JOB_BODY=""
  enq="$(docker exec pw-it-n sh -c "curl -s -w '\n%{http_code}' -X POST \
    -u '$n_user:$n_pass' -H 'X-Palwarden-Token: $n_tok' \
    -H 'Content-Type: application/json' -d '$body' \
    http://127.0.0.1:8088/api/jobs")"
  if [ "$(printf '%s' "$enq" | tail -1)" != "202" ]; then
    JOB_STATE="not-accepted"; JOB_BODY="$enq"; return 0
  fi
  JOB_ID="$(printf '%s' "$enq" | grep -oE '[0-9a-f]{32}' | head -1)"
  for ((i = 0; i < tries; i++)); do
    JOB_BODY="$(docker exec pw-it-n sh -c "curl -s -u '$n_user:$n_pass' \
      http://127.0.0.1:8088/api/jobs/$JOB_ID")"
    JOB_STATE="$(printf '%s' "$JOB_BODY" | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' | head -1)"
    case "$JOB_STATE" in queued|running|"") sleep 1 ;; *) break ;; esac
  done
}

# A recognisable world inside the mount, so "a tree exists" cannot pass for "the
# bytes came back".
docker exec pw-it-n sh -c 'install -d -o steam -g steam /opt/palworld/server/Pal/Saved/SaveGames/0 \
  && printf "mounted-world-ORIGINAL\n" > /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav'
# The inode of the mount point itself, which the swap must NOT change. A restore
# that replaced the directory would either fail (EBUSY, the bug) or — on some other
# filesystem — shadow the mount, and either way this number moves.
n_ino_before="$(docker exec pw-it-n stat -c %i /opt/palworld/server/Pal/Saved)"

n_job '{"action":"backup","params":{}}' 60
assert_eq "$JOB_STATE" "succeeded" "N1: a backup job runs to success (body: $JOB_BODY)"
n_name="$(docker exec pw-it-n sh -c 'ls -1 /opt/palworld/backups | head -1')"
assert_contains "$n_name" "palworld-save-" "N1: it produced an archive ($n_name)"

# Break the world, so a restore that silently did nothing cannot pass.
docker exec pw-it-n sh -c \
  'printf "mounted-world-CORRUPTED\n" > /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav'

# The assertion this scenario exists for: the restore has to finish across a mount
# point. Before the contents swap this job failed with
# "cannot swap the restored tree into ...: [Errno 16] Device or resource busy".
n_job "{\"action\":\"backup_restore\",\"params\":{\"backup\":\"$n_name\",\"wait\":0,\"confirm\":true}}" 150
assert_eq "$JOB_STATE" "succeeded" \
  "N2: backup_restore succeeds with Pal/Saved as a mount point (body: $JOB_BODY)"
assert_not_contains "$JOB_BODY" "Device or resource busy" \
  "N2: ...and specifically not EBUSY, which is how renaming the mount point failed"
assert_eq "$(docker exec pw-it-n cat /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav)" \
  "mounted-world-ORIGINAL" "N2: the restored world is the one that was backed up"
assert_eq "$(docker exec pw-it-n stat -c '%U' /opt/palworld/server/Pal/Saved/SaveGames/0/Level.sav)" \
  "steam" "N2: and the restored tree belongs to the service account, not root"
# The mount survived the restore as a mount: the swap moved contents, so the
# directory the volume is attached to is still the same one.
assert_eq "$(docker exec pw-it-n stat -c %i /opt/palworld/server/Pal/Saved)" \
  "$n_ino_before" "N2: Pal/Saved is still the same directory - its inode is unchanged"
assert_rc 0 docker exec pw-it-n sh -c \
  "grep -qE ' /opt/palworld/server/Pal/Saved ' /proc/self/mountinfo"
# The write landed in the *volume*, not in a directory shadowing the mount — read
# it back from the host side of the bind mount, which is the only place that can
# tell the difference.
assert_eq "$(cat "$NWORK/saved/SaveGames/0/Level.sav" 2>/dev/null)" \
  "mounted-world-ORIGINAL" "N2: ...and the restored bytes are inside the mounted volume"
assert_eq "$(docker exec pw-it-n systemctl is-active palworld.service)" "active" \
  "N2: the server is running again after the restore"
# No debris of either kind: the replaced tree goes on a confirmed startup, and the
# staging tree is emptied and removed by the swap itself.
assert_eq "$(docker exec pw-it-n sh -c 'ls -d /opt/palworld/server/Pal/Saved.replaced-* 2>/dev/null | wc -l')" \
  "0" "N2: no replaced tree is left behind"
assert_eq "$(docker exec pw-it-n sh -c 'ls -d /opt/palworld/server/Pal/Saved.restore-* 2>/dev/null | wc -l')" \
  "0" "N2: no staging tree is left behind either"

assert_report
