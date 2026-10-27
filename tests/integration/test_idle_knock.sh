#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Integration acceptance: idle-shutdown & knock-wake (plan Task 11, spec §9).
#
# Isolated scenarios with disposable container/volume names (pw-it11-*,
# pw-it11-ops-<run>): never production names. Reuses the inspected fixtures:
# the fake game (which really binds UDP 8211 while running) and the REST stub
# (schema-correct /v1/api/players; PALWORLD_STUB_PLAYERS=0 = positive empty
# evidence). Requires docker + docker compose. Slow by design: the idle
# scenario waits on REAL elapsed eligibility (uptime AND observed-empty both
# covering the seeded minute) — aging identity rows is not sufficient.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/assert.sh"

IMG="palwarden:test"
FAKE="$REPO/tests/fixtures/fake-server"
STUB="$REPO/tests/fixtures/rest-stub.py"
RUN_TAG="$(date +%s)-$$"
PW_IT="not-a-real-admin-password"
CIDS=()
VOLS=("pw-it11-ops-$RUN_TAG")

cleanup() {
  for c in "${CIDS[@]:-}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  for v in "${VOLS[@]:-}"; do docker volume rm "$v" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

run_c() { local name="$1"; shift; CIDS+=("$name"); docker rm -f "$name" >/dev/null 2>&1 || true; docker run -d --name "$name" "$@" >/dev/null; }
svc_state() { docker exec "$1" s6-svstat /run/service/"$2" 2>/dev/null | awk '{print $1}'; }
wait_svc() { # name svc up|down deadline_s
  local i=0; until [ "$(svc_state "$1" "$2")" = "$3" ]; do i=$((i+1)); [ "$i" -gt "$4" ] && return 1; sleep 1; done; }
knock_holds() { # container: is the knock daemon's pid the UDP 8211 holder?
  local kp; kp="$(docker exec -u root "$1" s6-svstat /run/service/palworld-knock 2>/dev/null | sed -n 's/.*pid \([0-9]*\).*/\1/p')"
  [ -n "$kp" ] && port_holders "$1" 8211 | grep -q "pid=${kp}[,)]"
}
udp_send() { python3 -c "import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2); s.sendto(sys.argv[3].encode(),('127.0.0.1',int(sys.argv[2])))" _ "$1" "$2"; }
port_holders() { docker exec -u root "$1" python3 -c 'import subprocess,re,sys
out=subprocess.run(["ss","-lunp"],capture_output=True,text=True).stdout
print(" ".join(l for l in out.splitlines() if re.search(r":"+sys.argv[1]+r"\s", l)))' "$2" 2>/dev/null || true; }
webui_creds() { # name -> sets WU WP WT
  WU="$(docker exec "$1" sed -n 's/^WEBUI_USER="\(.*\)"$/\1/p' /etc/palworld/webui.env)"
  WP="$(docker exec "$1" sed -n 's/^WEBUI_PASSWORD="\(.*\)"$/\1/p' /etc/palworld/webui.env)"
  WT="$(docker exec "$1" sed -n 's/^WEBUI_TOKEN="\(.*\)"$/\1/p' /etc/palworld/webui.env)"
}
api() { local name="$1"; shift; docker exec "$name" curl -s "$@"; }
wait_job() { # name job_id deadline -> final state
  local st=""
  for _ in $(seq 1 "$3"); do
    st="$(api "$1" -u "$WU:$WP" "http://127.0.0.1:8088/api/jobs/$2" | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p' | head -1)"
    case "$st" in queued|running|"") sleep 1 ;; *) echo "$st"; return ;; esac
  done
  echo "$st"; }

head -c 2 "$FAKE/Pal/Binaries/Linux/PalServer-Linux-Shipping" | grep -q '#!' \
  || { fail "fixture is not the fake script (SteamCMD debris in $FAKE? git clean that dir)"; assert_report; exit 1; }

echo "  building $IMG ..."
docker build -t "$IMG" -f "$REPO/docker/Dockerfile" "$REPO" >/dev/null 2>&1 \
  || { fail "image build failed"; assert_report; exit 1; }

# =============================================================================
# Scenario 2 — idle stop -> UDP wake, with REAL eligibility and REAL sockets.
# Fresh ops volume seeded with IDLE_TIMEOUT=1 minute. The fake game really
# binds UDP 8211 (conflict with the helper by design); the REST stub answers
# the sampler with the schema-valid EMPTY players list.
# =============================================================================
run_c pw-it11-a -v "$FAKE":/opt/palworld/server -v "pw-it11-ops-$RUN_TAG":/var/lib/palwarden-ops \
  -e ADMIN_PASSWORD="$PW_IT" -e FPS_SAMPLE_INTERVAL=2 \
  -e UPDATE_ON_START=false \
  -e IDLE_TIMEOUT=1 -e IDLE_CHECK_INTERVAL=5 \
  -p 127.0.0.1:18211:8211/udp "$IMG"
wait_svc pw-it11-a palworld-server up 120 || fail "2: fake game did not come up"
docker cp "$STUB" pw-it11-a:/stub.py >/dev/null
docker exec -d pw-it11-a env PALWORLD_STUB_PLAYERS=0 python3 /stub.py >/dev/null 2>&1
# The stub must answer before evidence counts; bounded poll through the API
# helper exactly as the sampler uses it.
ok=0
for _ in $(seq 1 30); do
  api pw-it11-a -u "admin:$PW_IT" http://127.0.0.1:8212/v1/api/players | grep -q '"players"' && { ok=1; break; }
  sleep 1
done
assert_eq "$ok" "1" "2: REST stub answering /v1/api/players inside the container"

# While the game runs it owns UDP 8211: the knock listener must NOT hold it.
docker exec pw-it11-a sh -c 'sleep 8'   # several lease attempts
holders="$(port_holders pw-it11-a 8211)"
if knock_holds pw-it11-a; then fail "2: knock stole the port from the running game"
elif [ -z "$holders" ]; then fail "2: nobody holds UDP 8211 (fixture bind failed?)"
else pass "2: UDP 8211 held by the running game, never by knock"; fi

# Positive empty evidence must be accumulating (not merely identity rows).
ok=0
for _ in $(seq 1 40); do
  row="$(docker exec pw-it11-a python3 -c "import sqlite3;r=sqlite3.connect('/var/lib/palworld/metrics.sqlite3').execute('select valid,empty_since_ms from presence_state where id=1').fetchone();print(r)" 2>/dev/null)"
  printf '%s' "$row" | grep -qE '^\(1, [0-9]+\)$' && { ok=1; break; }
  sleep 1
done
assert_eq "$ok" "1" "2: presence_state valid with a real empty_since_ms (empty sampling running)"

# No premature stop: the tick cannot fire before BOTH real service uptime and
# observed-empty duration cover the seeded minute. Sample early on purpose.
docker exec pw-it11-a sh -c 'sleep 20'
assert_eq "$(svc_state pw-it11-a palworld-server)" "up" "2: no premature stop before the eligibility window closes"

# Bounded wait for the real stop (tick every 5s + graceful SIGINT save).
if wait_svc pw-it11-a palworld-server down 180; then
  pass "2: idle tick stopped the server after real elapsed eligibility"
else
  fail "2: server never stopped within the bounded deadline"
fi
state_json="$(docker exec pw-it11-a python3 -m palwarden_lifecycle state --json 2>/dev/null)"
assert_contains "$state_json" '"status": "idle"' "2: idle marker written to the lifecycle state"

# UDP to the PUBLISHED HOST port must wake exactly once: one start, REST
# ready, game owns the socket again. The lease gap (port closed ~0.15s
# between leases) can drop a single datagram by design, so ring like a real
# client: repeatedly, bounded, until the wake lands.
ok=0
for _ in $(seq 1 60); do
  udp_send 18211 knock-from-host
  [ "$(svc_state pw-it11-a palworld-server)" = up ] && { ok=1; break; }
  sleep 0.5
done
if [ "$ok" = 1 ]; then pass "2: UDP knock on the host port woke the server"
else fail "2: UDP knock did not wake the server"; fi
docker exec pw-it11-a sh -c 'sleep 6'   # readiness + game bind settle
if knock_holds pw-it11-a; then fail "2: knock kept the port after the wake"
else pass "2: the woken game owns UDP 8211 again"; fi
assert_contains "$(docker logs pw-it11-a 2>&1)" "wake started" "2: the wake is recorded in the service log"

# =============================================================================
# Scenario 3 — stale sampler with healthy info: NO stop, ever.
# Halt presence sampling while /v1/api/info keeps answering; with old identity
# rows and ample uptime the tick must still refuse (evidence is UNKNOWN).
# The supervised loop is frozen first: with the 0-player stub it would
# legitimately re-stop the just-woken server after another full idle minute,
# racing the stale window we are trying to create.
# =============================================================================
docker exec pw-it11-a s6-svc -d /run/service/idle-watch
docker exec pw-it11-a rm -f /var/lib/palwarden-ops/knock.cooldown
if [ "$(svc_state pw-it11-a palworld-server)" = down ]; then
  docker exec pw-it11-a systemctl start palworld.service
  wait_svc pw-it11-a palworld-server up 60 || fail "3: could not restart for the stale test"
fi
docker exec pw-it11-a s6-svc -d /run/service/fps-sample
docker exec pw-it11-a sh -c 'sleep 70'   # > MAX_GAP_MS (60s) with sampling dead
if api pw-it11-a -u "admin:$PW_IT" http://127.0.0.1:8212/v1/api/info | grep -q servername; then
  pass "3: info endpoint still healthy while the sampler is dead"
else
  fail "3: info endpoint died with the sampler (fixture problem)"
fi
# One-shot tick against a temp copy pinned to the 1-minute rule (the real ops
# file gets a long timeout below so the loop cannot re-stop the world mid-run).
docker exec pw-it11-a sh -c 'sed s/IDLE_TIMEOUT="1"/IDLE_TIMEOUT="1"/ /var/lib/palwarden-ops/palwarden.env > /tmp/ops-stale.env'
tick="$(docker exec pw-it11-a env PALWARDEN_OPS_FILE=/tmp/ops-stale.env \
  python3 /usr/local/sbin/palworld-idle-watch 2>&1)"
assert_eq "$(svc_state pw-it11-a palworld-server)" "up" "3: stale evidence never stops the server (tick: $tick)"
assert_contains "$tick" "stale" "3: tick names the stale evidence"
# Long timeout for the remainder of the run: the 0-player stub would keep
# re-stopping every woken server after one idle minute.
docker exec -u root pw-it11-a sed -i 's/^IDLE_TIMEOUT="1"/IDLE_TIMEOUT="999"/' /var/lib/palwarden-ops/palwarden.env
docker exec pw-it11-a s6-svc -u /run/service/idle-watch

# =============================================================================
# Scenario 4 — maintenance windows and wake races.
# =============================================================================
webui_creds pw-it11-a
# The wake fence admits only against a CONFIRMED idle lifecycle; re-establish
# idle (init-runtime rotates an idle generation) before submitting fresh
# maintenance. The worker may start that maintenance before the wake request.
docker exec pw-it11-a python3 -m palwarden_lifecycle init-runtime --json >/dev/null
# Stop via a queued disruptive job (the supported manual path).
stop_id="$(api pw-it11-a -X POST -u "$WU:$WP" -H "X-Palwarden-Token: $WT" \
  -H 'Content-Type: application/json' -d '{"action":"graceful_stop","params":{"wait":0,"confirm":true}}' \
  http://127.0.0.1:8088/api/jobs | grep -oE '[0-9a-f]{32}' | head -1)"
# (4a) API wake while a disruptive job is queued/running -> 409 naming the
# blocker (the wake is never even enqueued).
resp="$(api pw-it11-a -w '\n%{http_code}' -X POST -u "$WU:$WP" \
  -H "X-Palwarden-Token: $WT" -H 'Content-Type: application/json' \
  -d '{"action":"server_wake","params":{"reason":"itest-race"}}' http://127.0.0.1:8088/api/jobs)"
assert_eq "$(printf '%s' "$resp" | tail -1)" "409" "4a: wake behind a queued maintenance job is refused with 409"
case "$resp" in
  *"disruptive job is queued or running"*|*"lifecycle status is active, not idle"*)
    pass "4a: the 409 names queued or active maintenance" ;;
  *) fail "4a: the 409 did not name a maintenance blocker: $resp" ;;
esac
assert_eq "$(wait_job pw-it11-a "$stop_id" 60)" "succeeded" "4: graceful_stop job completed"

# (4b) crash wanted-up: down WITHOUT the wanted-down marker = crash-backoff;
# knock must not arm and an explicit wake must refuse.
docker exec pw-it11-a s6-svc -d /run/service/palworld-server
wait_svc pw-it11-a palworld-server down 60 || fail "4b: server did not stop"
docker exec pw-it11-a rm -f /run/service/palworld-server/down
code=""
for _ in $(seq 1 40); do
  code="$(docker exec pw-it11-a python3 /usr/local/sbin/palworld-knock wake --reason itest-crash 2>&1; echo "rc=$?")"
  # rc=75 with "busy" is the daemon mid-lease; retry for the real verdict.
  case "$code" in *"rc=75"*) case "$code" in *busy*) sleep 0.5; continue;; esac;; esac
  break
done
assert_contains "$code" "refused" "4b: wake refused in crash-backoff (never start blind)"
assert_contains "$code" "crash" "4b: the refusal names crash-backoff"
assert_eq "$(svc_state pw-it11-a palworld-server)" "down" "4b: crash-backoff wake did not start the service"
docker exec pw-it11-a sh -c 'mkdir -p /run/service/palworld-server && touch /run/service/palworld-server/down'

# (4c) maintenance window under ownership: UDP must neither bind nor wake.
docker exec -d pw-it11-a python3 -c '
import socket, subprocess, sys
p = subprocess.Popen([sys.executable, "-c",
  "import socket,time; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);"
  "s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((\"0.0.0.0\",8211));"
  "print(s.recvfrom(64))"], stdout=subprocess.PIPE, text=True)
rc = subprocess.run(["python3","-m","palwarden_lifecycle","acquire","--","sleep","12"]).returncode
sys.exit(rc)' >/dev/null 2>&1
docker exec pw-it11-a sh -c 'sleep 3'   # holder owns lock + port
udp_send 18211 knock-during-maintenance
docker exec pw-it11-a sh -c 'sleep 3'
assert_eq "$(svc_state pw-it11-a palworld-server)" "down" "4c: UDP during a maintenance window does not wake"
if knock_holds pw-it11-a; then fail "4c: knock bound the port inside the maintenance window"
else pass "4c: knock never binds while maintenance owns the port"; fi

# (4d) concurrent supported manual start waits for the lock (socket released):
# the maintenance holder above still has ~6s of lock left.
t0=$(date +%s)
docker exec pw-it11-a systemctl start palworld.service
t1=$(date +%s)
if [ $((t1 - t0)) -ge 3 ]; then pass "4d: manual start blocked on the lifecycle lock ($((t1-t0))s)"
else fail "4d: manual start did not wait for the maintenance window ($((t1-t0))s)"; fi
wait_svc pw-it11-a palworld-server up 30 || fail "4d: start proceeded after the window"

# (4e) interrupted maintenance: an unsafe marker inhibits wake until an
# operator acknowledges it (root, service stopped). Stop FIRST: wake reports
# already-running while the service is up and never consults the state file.
docker exec pw-it11-a palworld-graceful-stop --wait 0 >/dev/null 2>&1
wait_svc pw-it11-a palworld-server down 60 || fail "4e: could not stop for the unsafe test"
docker exec pw-it11-a rm -f /var/lib/palwarden-ops/knock.cooldown   # isolate the unsafe verdict from the scenario-2 cooldown
docker exec pw-it11-a python3 -c 'import sys; sys.path.insert(0,"/usr/local/lib"); import palwarden_lifecycle as lc; lc.write_state("unsafe","update")'
code=""
for _ in $(seq 1 40); do
  code="$(docker exec pw-it11-a python3 /usr/local/sbin/palworld-knock wake --reason itest-unsafe 2>&1; echo "rc=$?")"
  case "$code" in *"rc=75"*) case "$code" in *busy*) sleep 0.5; continue;; esac;; esac
  break
done
assert_contains "$code" "refused" "4e: wake refused while maintenance is unacknowledged"
ack="$(docker exec pw-it11-a python3 -m palwarden_lifecycle acknowledge-maintenance --confirm 2>&1; echo "rc=$?")"
assert_contains "$ack" "rc=0" "4e: acknowledge-maintenance succeeds once the service is stopped"

# (4f) fence expiry: a job file whose wake window lapsed is refused by the
# worker (crafted queue file — the queue is the only writer path anyway).
docker exec pw-it11-a python3 -c '
import json, os, time
jid = "a"*32
job = {"id": jid, "action": "server_wake",
       "params": {"reason": "itest-expired", "wake_generation": "b"*32,
                  "wake_expires_at": int(time.time()) - 5},
       "state": "queued", "created_at": int(time.time()), "seq": time.time_ns(),
       "started_at": None, "finished_at": None, "exit_code": None, "output": ""}
p = f"/var/lib/palworld/jobs/{jid}.json"
with open(p, "w") as f: json.dump(job, f)
# The queue readers run as steam; a root-owned 0600 file is unreadable and
# therefore "not a job". Hand it to the directory owner, exactly as the
# real writers do.
os.chown(p, os.stat("/var/lib/palworld/jobs").st_uid, os.stat("/var/lib/palworld/jobs").st_gid)
os.chmod(p, 0o600)'
docker exec pw-it11-a test -f /var/lib/palworld/jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json \
  || fail "4f: crafted job file missing; queue: $(docker exec pw-it11-a ls /var/lib/palworld/jobs/ 2>&1 | head -5)"
body=""
for _ in $(seq 1 40); do
  body="$(api pw-it11-a -u "$WU:$WP" http://127.0.0.1:8088/api/jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
  printf '%s' "$body" | grep -qE '"state": "(succeeded|failed)"' && break
  sleep 1
done
assert_contains "$body" "expired" "4f: expired wake refused by the worker fence"
assert_eq "$(svc_state pw-it11-a palworld-server)" "down" "4f: expired wake did not start the service"

# (4g) changed generation: a wake admitted for generation X must not execute
# after maintenance rotated to Y (worker-side fence half). Crafted job file
# pinned to an all-f generation that no real state can hold.
docker exec pw-it11-a python3 -c "
import json, os, time
jid = 'c'*32
job = {'id': jid, 'action': 'server_wake',
       'params': {'reason': 'itest-stalegen', 'wake_generation': 'f'*32,
                  'wake_expires_at': int(time.time()) + 3600},
       'state': 'queued', 'created_at': int(time.time()), 'seq': time.time_ns(),
       'started_at': None, 'finished_at': None, 'exit_code': None, 'output': ''}
with open(f'/var/lib/palworld/jobs/{jid}.json', 'w') as f: json.dump(job, f)
st = os.stat('/var/lib/palworld/jobs')
os.chown(f'/var/lib/palworld/jobs/{jid}.json', st.st_uid, st.st_gid)
os.chmod(f'/var/lib/palworld/jobs/{jid}.json', 0o600)"
docker exec pw-it11-a test -f /var/lib/palworld/jobs/cccccccccccccccccccccccccccccccc.json \
  || fail "4g: crafted job file missing; queue: $(docker exec pw-it11-a ls /var/lib/palworld/jobs/ 2>&1 | head -5)"
body=""
for _ in $(seq 1 40); do
  body="$(api pw-it11-a -u "$WU:$WP" http://127.0.0.1:8088/api/jobs/cccccccccccccccccccccccccccccccc)"
  printf '%s' "$body" | grep -qE '"state": "(succeeded|failed)"' && break
  sleep 1
done
assert_contains "$body" "generation" "4g: wake with a changed generation refused by the worker fence"

# =============================================================================
# Scenario 5 — force-recreate persistence vs changed seeds; fresh-volume reset.
# =============================================================================
CC=pw-it11-a   # docker-run container until compose takes ownership below
webui_creds "$CC"
put_id="$(api "$CC" -X PUT -u "$WU:$WP" -H "X-Palwarden-Token: $WT" \
  -H 'Content-Type: application/json' \
  -d '{"IDLE_TIMEOUT":30,"KNOCK_TOKEN":"synthetic-itest-token-0123456789"}' \
  http://127.0.0.1:8088/api/palwarden-config | grep -oE '[0-9a-f]{32}' | head -1)"
assert_eq "$(wait_job "$CC" "$put_id" 40)" "succeeded" "5: config-save job completed"
before_bytes="$(docker exec "$CC" cat /var/lib/palwarden-ops/palwarden.env)"
before_mode="$(docker exec "$CC" stat -c '%U:%G:%a' /var/lib/palwarden-ops/palwarden.env)"

# Changed env seeds + SAME ops volume, via compose --force-recreate.
COMPOSE="$DIR/fixture-compose-$RUN_TAG.yaml"
cat > "$COMPOSE" <<EOF
name: pw-it11-$RUN_TAG
services:
  palwarden:
    image: $IMG
    container_name: pw-it11-a
    environment:
      ADMIN_PASSWORD: "$PW_IT"
      FPS_SAMPLE_INTERVAL: "2"
      UPDATE_ON_START: "false"
      IDLE_TIMEOUT: "999"
      IDLE_CHECK_INTERVAL: "77"
      KNOCK_ENABLED: "false"
      KNOCK_COOLDOWN: "4321"
      KNOCK_TOKEN: "seed-must-not-override"
      PALWARDEN_OPS_FILE: /var/lib/palwarden-ops/palwarden.env
    volumes:
      - $FAKE:/opt/palworld/server
      - pw-it11-ops-$RUN_TAG:/var/lib/palwarden-ops
    ports:
      - "127.0.0.1:18211:8211/udp"
volumes:
  pw-it11-ops-$RUN_TAG:
    external: true
EOF
trap 'cleanup; rm -f "$COMPOSE"' EXIT
docker rm -f "$CC" >/dev/null 2>&1   # compose must own the container it recreates
CC="$(docker compose -f "$COMPOSE" ps -q palwarden 2>/dev/null)"
[ -n "$CC" ] && docker rm -f "$CC" >/dev/null 2>&1
co_err="$(docker compose -f "$COMPOSE" up -d --force-recreate 2>&1)" \
  || fail "5: compose force-recreate failed: $co_err"
CC="$(docker compose -f "$COMPOSE" ps -q palwarden)"
[ -n "$CC" ] && CIDS+=("$CC")
wait_svc "$CC" palworld-server up 120 || fail "5: server did not come back after recreate"
# The stub lived in the writable layer, which the recreate wiped; the wake
# readiness path needs it again later, so restore it now.
docker cp "$STUB" "$CC":/stub.py >/dev/null
docker exec -d "$CC" env PALWORLD_STUB_PLAYERS=0 python3 /stub.py >/dev/null 2>&1
after_bytes="$(docker exec "$CC" cat /var/lib/palwarden-ops/palwarden.env)"
after_mode="$(docker exec "$CC" stat -c '%U:%G:%a' /var/lib/palwarden-ops/palwarden.env)"
assert_eq "$after_bytes" "$before_bytes" "5: saved ops file byte-identical across force-recreate with CHANGED seeds"
assert_eq "$after_mode" "$before_mode" "5: ops file ownership/mode preserved across recreate"
assert_contains "$after_bytes" "synthetic-itest-token-0123456789" "5: saved token survived the recreate"
assert_contains "$after_bytes" 'IDLE_TIMEOUT="30"' "5: saved IDLE_TIMEOUT (30) beat the new seed (999)"

# Fresh-volume reset is the documented, explicit alternative.
docker compose -f "$COMPOSE" down >/dev/null 2>&1
vrm_err="$(docker volume rm "pw-it11-ops-$RUN_TAG" 2>&1)" \
  || fail "5: fresh-volume case could not remove the ops volume: $vrm_err"
docker volume create "pw-it11-ops-$RUN_TAG" >/dev/null
co_err="$(docker compose -f "$COMPOSE" up -d 2>&1)" \
  || fail "5: fresh-volume recreate failed: $co_err"
CC="$(docker compose -f "$COMPOSE" ps -q palwarden)"
[ -n "$CC" ] && CIDS+=("$CC")
docker cp "$STUB" "$CC":/stub.py >/dev/null
docker exec -d "$CC" env PALWORLD_STUB_PLAYERS=0 python3 /stub.py >/dev/null 2>&1
fresh="$(docker exec "$CC" cat /var/lib/palwarden-ops/palwarden.env)"
assert_contains "$fresh" 'IDLE_TIMEOUT="999"' "5: deleted volume re-seeds from the environment"
assert_contains "$fresh" 'KNOCK_TOKEN="seed-must-not-override"' "5: fresh seed carries the new token"

# =============================================================================
# Scenario 6 — live configuration edits, no service/container restart, and
# secret handling across the queue.
# =============================================================================
docker exec "$CC" sh -c 'sleep 5'
docker cp "$STUB" "$CC":/stub.py >/dev/null
docker exec -d "$CC" env PALWORLD_STUB_PLAYERS=0 python3 /stub.py >/dev/null 2>&1
webui_creds "$CC"

save_and_wait() { local body="$1"; local jid
  jid="$(api "$CC" -X PUT -u "$WU:$WP" -H "X-Palwarden-Token: $WT" \
    -H 'Content-Type: application/json' -d "$body" \
    http://127.0.0.1:8088/api/palwarden-config | grep -oE '[0-9a-f]{32}' | head -1)"
  wait_job "$CC" "$jid" 40 >/dev/null; }

# The fresh volume above seeded KNOCK_ENABLED=false, so the listener is
# CORRECTLY closed at first; enable it explicitly before the handoff tests.
save_and_wait '{"KNOCK_ENABLED":true}'
# Stop the game so the listener CAN hold the port (handoff), then edit live.
docker exec "$CC" palworld-graceful-stop --wait 0 >/dev/null 2>&1
wait_svc "$CC" palworld-server down 60 || fail "6: could not stop the server for the listener tests"
ok=0; for _ in $(seq 1 20); do knock_holds "$CC" && { ok=1; break; }; sleep 1; done
assert_eq "$ok" "1" "6: listener armed on the free port while the server is down"

save_and_wait '{"KNOCK_ENABLED":false}'
ok=0; for _ in $(seq 1 20); do knock_holds "$CC" || { ok=1; break; }; sleep 1; done
assert_eq "$ok" "1" "6: disabling knock closes the socket by the next lease (no restart)"
sv1="$(docker exec "$CC" s6-svstat /run/service/palworld-knock | grep -oE 'pid [0-9]+' | grep -oE '[0-9]+')"
save_and_wait '{"KNOCK_ENABLED":true}'
ok=0; for _ in $(seq 1 20); do knock_holds "$CC" && { ok=1; break; }; sleep 1; done
assert_eq "$ok" "1" "6: re-enabling knock re-arms live"
sv2="$(docker exec "$CC" s6-svstat /run/service/palworld-knock | grep -oE 'pid [0-9]+' | grep -oE '[0-9]+')"
assert_eq "$sv1" "$sv2" "6: enable/disable applied WITHOUT restarting the knock service"

# Live token edit: old token dead, new token wakes.
save_and_wait '{"KNOCK_TOKEN":"live-edit-token-42"}'
udp_send 18211 old-token-is-gone
docker exec "$CC" sh -c 'sleep 4'
assert_eq "$(svc_state "$CC" palworld-server)" "down" "6: the replaced token no longer wakes"
docker exec "$CC" rm -f /var/lib/palwarden-ops/knock.cooldown   # scenario 2's wake cooldown must not mask the token verdict
ok=0
for _ in $(seq 1 60); do
  udp_send 18211 live-edit-token-42
  [ "$(svc_state "$CC" palworld-server)" = up ] && { ok=1; break; }
  sleep 0.5
done
if [ "$ok" = 1 ]; then pass "6: the live-edited token wakes without any restart"
else fail "6: live-edited token did not wake"; fi

# Live idle-interval edit applies (file changed, watcher pid unchanged).
save_and_wait '{"IDLE_CHECK_INTERVAL":45}'
iw1="$(docker exec "$CC" s6-svstat /run/service/idle-watch | grep -oE 'pid [0-9]+' | grep -oE '[0-9]+')"
assert_contains "$(docker exec "$CC" cat /var/lib/palwarden-ops/palwarden.env)" 'IDLE_CHECK_INTERVAL="45"' "6: idle interval edit saved"
iw2="$(docker exec "$CC" s6-svstat /run/service/idle-watch | grep -oE 'pid [0-9]+' | grep -oE '[0-9]+')"
assert_eq "$iw1" "$iw2" "6: idle watcher not restarted for the edit (live reload)"

# Secret handling: the queue scrubs the token after the job finishes, and no
# public API surface carries it.
assert_eq "$(docker exec "$CC" sh -c 'grep -rl "live-edit-token-42" /var/lib/palworld/jobs/ 2>/dev/null | wc -l')" "0" \
    "6: no completed job file still contains the token"
get_cfg="$(api "$CC" -u "$WU:$WP" http://127.0.0.1:8088/api/palwarden-config)"
assert_contains "$get_cfg" '"token_configured": true' "6: public view reports token_configured"
case "$get_cfg" in *live-edit-token-42*) fail "6: token leaked in GET /api/palwarden-config";; *) pass "6: token absent from the public config view";; esac
case "$(docker exec "$CC" grep -c live-edit-token-42 /var/log/palworld/*.log 2>/dev/null; docker logs "$CC" 2>&1)" in
  *live-edit-token-42*) fail "6: token leaked into logs";; *) pass "6: token absent from container logs";; esac

assert_report