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
  -e ADMIN_PASSWORD=secret123 -e "PALWORLD_CFG_SERVER_NAME=Yggdrasil" \
  -v "$FAKE":/opt/palworld/server "$IMG"
wait_up pw-it-b palworld-server || fail "B: server did not come up"
docker exec pw-it-b sh -c 'sleep 2'
svcB="$(services_of pw-it-b)"
assert_contains "$svcB" "fps-sample" "B: telemetry enabled with password"
# settings.env was rendered in-container from env (values are shell-quoted)
assert_rc 0 docker exec pw-it-b grep -qF 'REST_API_ENABLED="True"' /etc/palworld/settings.env
assert_rc 0 docker exec pw-it-b grep -qF 'SERVER_NAME="Yggdrasil"' /etc/palworld/settings.env
assert_rc 0 docker exec pw-it-b grep -qF 'ADMIN_PASSWORD="secret123"' /etc/palworld/settings.env
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
  -e ADMIN_PASSWORD=secret123 -e FPS_SAMPLE_INTERVAL=1 "$IMG"
svcC="$(services_of pw-it-c)"
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

assert_report
