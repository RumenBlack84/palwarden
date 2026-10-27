#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Live acceptance for idle-shutdown & knock-wake (plan Task 12, spec §9's
# real-game line): the claims the stub server cannot make, asked of the REAL
# game on the marked disposable testbed.
#
#   1. REAL UDP OWNERSHIP. The fake server binds 8211 because a shell script
#      was told to; only the real game proves the knock listener and the game
#      genuinely contend for the same port the engine holds — and that the
#      handoff goes both ways (game -> listener on idle stop, listener -> game
#      on wake, with the game's bind winning once it is back).
#
#   2. IDLE STOP SAVED A REAL WORLD. The stub's "save" is a touch. Here the
#      SIGINT flush runs against a multi-hundred-megabyte world, and the
#      restart-from-that-save assertion (same world directories, REST answers,
#      this run's marker still in the tree) is the operator-facing claim:
#      nobody's progress is lost by an idle shutdown.
#
#   3. FIRST KNOCK / RETRY over a real published UDP socket: the first
#      token-bearing datagram wakes; a retry inside the cooldown does not;
#      after the cooldown expires, knock wakes again.
#
# SELF-CONTAINMENT, as in every live suite: fresh nonce in the world marker
# and in the knock token, world directories compared this-run-before against
# this-run-after, and the config restored to defaults on every exit path —
# the ops file lives on a volume that outlives `live_down`, so a suite that
# left IDLE_TIMEOUT=1 behind would idle-stop the NEXT suite's server.
#
# Off by default; needs a marked testbed with a real install. See
# tests/live/lib/testbed.sh and docker/compose.live.yaml.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
source "$DIR/lib/testbed.sh"

# Guard first, on its own line, before anything is built or started — this
# suite stops a real server; pointed at a deployment it must refuse first.
live_require_testbed

# Bounds. Eligibility is real elapsed time (uptime AND observed-empty each
# covering the seeded minute) plus a real save on SIGINT, so the idle-stop
# wait gets the same generous bound as the graceful stop in
# test_stop_consistency.sh; every one of them is still bounded.
IDLE_STOP_TIMEOUT="${PALWARDEN_LIVE_IDLE_TIMEOUT:-420}"
STOP_TIMEOUT="${PALWARDEN_LIVE_STOP_TIMEOUT:-420}"
WAKE_SETTLE="${PALWARDEN_LIVE_WAKE_SETTLE:-240}"

HOST_SAVED="$TESTBED/server/Pal/Saved"
OPS_COOLDOWN="/var/lib/palwarden-ops/knock.cooldown"
NONCE="$$-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}${RANDOM}"
MARKER_REL="SaveGames/.palwarden-live-knock-marker"
HOST_MARKER="$HOST_SAVED/$MARKER_REL"
MARKER_TEXT="palwarden-live-idle-knock $NONCE"
# A fresh token this run sets and this run clears. Synthetic by construction —
# nothing real anywhere in this file.
TOKEN="live-knock-$NONCE"
# Short enough that the post-cooldown wake is a bounded wait, long enough that
# the refused retry cannot race the expiry.
COOLDOWN_S=120

# --- host-side helpers (the integration suite's, re-pointed at compose) -----
# The published host port for the game's UDP mapping. `docker compose port`
# refuses the /udp suffix (ParseUint), so ask the running container's own port
# bindings, which key by protocol.
live_resolve_udp_port() {
  local cid
  cid="$(live_compose ps -q palwarden 2>/dev/null | head -1)"
  [ -n "$cid" ] || return 1
  LIVE_UDP_PORT="$(docker inspect "$cid" --format '{{range $k, $v := .NetworkSettings.Ports}}{{if eq $k "8211/udp"}}{{with $v}}{{(index . 0).HostPort}}{{end}}{{end}}{{end}}' 2>/dev/null)"
  [[ "$LIVE_UDP_PORT" =~ ^[0-9]+$ ]]
}
# One datagram, exactly the token bytes (matching is exact UTF-8 comparison).
udp_knock() {
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(2); s.sendto(sys.argv[2].encode(),("127.0.0.1",int(sys.argv[1])))' "$1" "$2"
}
svc_state() { live_exec s6-svstat /run/service/"$1" 2>/dev/null | awk '{print $1}'; }
wait_svc() { # svc up|down deadline_s
  local i=0; until [ "$(svc_state "$1")" = "$2" ]; do i=$((i+1)); [ "$i" -gt "$3" ] && return 1; sleep 1; done;
}
port_holders() { live_exec python3 -c 'import subprocess,re,sys
out=subprocess.run(["ss","-lunp"],capture_output=True,text=True).stdout
print(" ".join(l for l in out.splitlines() if re.search(r":"+sys.argv[1]+r"\s", l)))' "$1" 2>/dev/null || true; }
knock_holds() { # is the knock daemon's pid the UDP 8211 holder?
  local kp; kp="$(live_exec s6-svstat /run/service/palworld-knock 2>/dev/null | sed -n 's/.*pid \([0-9]*\).*/\1/p')"
  [ -n "$kp" ] && port_holders 8211 | grep -q "pid=${kp}[,)]"
}
# PUT /api/palwarden-config queues palwarden_config_save; wait for the job.
put_config() { # json -> 0 when the save job succeeds
  local body id st
  body="$(live_api PUT /api/palwarden-config "$1")"
  id="$(printf '%s' "$body" | grep -oE '[0-9a-f]{32}' | head -1)"
  [ "${#id}" -eq 32 ] || { live_log "config PUT returned no job id: $body"; return 1; }
  st="$(live_wait_job "$id" 60)"
  [ "$st" = succeeded ] || { live_log "config-save job $id ended $st"; return 1; }
}
# Restore the shipped defaults. The ops file outlives live_down on its volume,
# so this runs on EVERY exit path, before the stack goes down.
restore_config() {
  put_config '{"IDLE_TIMEOUT":0,"KNOCK_TOKEN":"","KNOCK_COOLDOWN":600}' >/dev/null 2>&1 || true
}

# --- bring the real thing up -------------------------------------------------
live_up || { fail "the live server did not become REST-ready"; assert_report; exit 1; }
# Trap after live_up and after the guard, exactly as the other live suites do:
# nothing to tear down before live_up, and the handler must not exit (so
# assert_report's status survives). Config first, then down.
trap 'restore_config
      live_down >/dev/null 2>&1 || true' EXIT

# =============================================================================
# Scenario 1 — UDP ownership while the game runs.
# The knock listener is supervised from container start; with the game up it
# must never hold the port. (The stub proved the protocol; this proves the
# protocol against the engine's own socket.)
# =============================================================================
sleep 8   # several lease attempts
holders="$(port_holders 8211)"
if knock_holds; then
  fail "1: knock stole UDP 8211 from the running real game"
elif [ -z "$holders" ]; then
  fail "1: nobody holds UDP 8211 — the real game should own it while running"
else
  pass "1: the running game holds UDP 8211; the knock listener does not"
fi

# World identity and this run's marker, taken while the server is up.
world_dirs() { (cd "$HOST_SAVED/SaveGames" && find . -mindepth 1 -maxdepth 2 -type d | sort); }
worlds_before="$(world_dirs)"
if [[ -n "$worlds_before" ]]; then pass; else
  fail "no world directories under $HOST_SAVED/SaveGames — the reload comparison would be vacuous"
  assert_report; exit 1
fi
printf '%s\n' "$MARKER_TEXT" > "$HOST_MARKER" \
  || { fail "cannot write the world marker $HOST_MARKER"; assert_report; exit 1; }
level_sav() { find "$HOST_SAVED/SaveGames" -name Level.sav -type f 2>/dev/null | head -1; }
SAV="$(level_sav)"
if [[ -n "$SAV" ]]; then pass "the world has a Level.sav to compare mtimes against"; else
  fail "no Level.sav under SaveGames — nothing to measure the save-on-stop against"
  assert_report; exit 1
fi
sav_mtime_before="$(stat -c %Y "$SAV")"

# =============================================================================
# Scenario 2 — enable through the panel API, and let real eligibility fire.
# One minute of idle, five-second ticks, a fresh token, short cooldown — all
# through the same PUT /api/palwarden-config job path the browser uses, so the
# live tier also exercises the API contract end to end against a real server.
# =============================================================================
if put_config "{\"IDLE_TIMEOUT\":1,\"IDLE_CHECK_INTERVAL\":5,\"KNOCK_ENABLED\":true,\"KNOCK_COOLDOWN\":$COOLDOWN_S,\"KNOCK_TOKEN\":\"$TOKEN\"}"; then
  pass "2: palwarden_config_save succeeded via the API"
else
  fail "2: could not enable idle/knock through the API"
  assert_report; exit 1
fi
cfg="$(live_api GET /api/palwarden-config)"
assert_contains "$cfg" '"IDLE_TIMEOUT": 1,' "2: GET reflects the saved idle timeout"
assert_contains "$cfg" '"token_configured": true' "2: GET reports the token as configured"
if printf '%s' "$cfg" | grep -q "$TOKEN"; then
  fail "2: GET /api/palwarden-config leaked the token itself"
else
  pass "2: GET never carries the token bytes"
fi

# The sampler must be producing positive empty evidence against the REAL REST
# API (the integration suite proved the schema against a stub; this proves the
# real endpoint classifies as empty with nobody online).
ok=0
for _ in $(seq 1 40); do
  row="$(live_exec python3 -c "import sqlite3;r=sqlite3.connect('/var/lib/palworld/metrics.sqlite3').execute('select valid,empty_since_ms from presence_state where id=1').fetchone();print(r)" 2>/dev/null)"
  printf '%s' "$row" | grep -qE '^\(1, [0-9]+\)$' && { ok=1; break; }
  sleep 1
done
assert_eq "$ok" "1" "2: presence_state valid with a real empty_since_ms from the live REST API"

# Bounded wait for the real idle stop: eligibility (uptime AND observed-empty
# covering the minute) then a real SIGINT save of a real world.
if wait_svc palworld-server down "$IDLE_STOP_TIMEOUT"; then
  pass "2: the idle tick stopped the real server after real eligibility"
else
  fail "2: the real server never idle-stopped within ${IDLE_STOP_TIMEOUT}s"
  assert_report; exit 1
fi
state_json="$(live_exec python3 -m palwarden_lifecycle state --json 2>/dev/null)"
assert_contains "$state_json" '"status": "idle"' "2: the lifecycle state records the idle stop"

# Disable idle IMMEDIATELY, before anything can wake the server: with the
# minute still armed, the watcher would legitimately re-stop every woken
# server a minute later and race scenarios 4-6.
if put_config '{"IDLE_TIMEOUT":0}'; then
  pass "2: idle disabled again before the wake scenarios"
else
  fail "2: could not disable idle after the stop — later scenarios may race a re-stop"
fi

# The save-on-stop measurement: the SIGINT flush must have rewritten the
# world's Level.sav (the game also autosaves, so this is a sanity bound; the
# load-the-same-world assertions in scenario 6 are the real proof).
sav_mtime_after="$(stat -c %Y "$(level_sav)")"
if [ "$sav_mtime_after" -ge "$sav_mtime_before" ]; then pass
else fail "Level.sav's mtime went backwards across the idle stop"; fi

# =============================================================================
# Scenario 3 — the listener takes the port the game released.
# =============================================================================
ok=0
for _ in $(seq 1 30); do knock_holds && { ok=1; break; }; sleep 1; done
assert_eq "$ok" "1" "3: with the server down-and-wanted-down, knock holds UDP 8211"

# =============================================================================
# Scenario 4 — the first knock wakes.
# The lease gap (~0.15s per second) can drop a single datagram by design, so
# ring like a real client: repeatedly, bounded, until the wake lands.
# =============================================================================
live_resolve_udp_port || { fail "4: could not resolve the published UDP port"; assert_report; exit 1; }
ok=0
for _ in $(seq 1 60); do
  udp_knock "$LIVE_UDP_PORT" "$TOKEN"
  [ "$(svc_state palworld-server)" = up ] && { ok=1; break; }
  sleep 0.5
done
if [ "$ok" = 1 ]; then pass "4: the first token-bearing knock on the host port woke the server"
else fail "4: UDP knock on the published port never woke the real server"; fi
# The cooldown stamp is written BEFORE the start (spec §6.2), so it must be
# there by now — but a compose exec racing the game's spawn can glitch, so
# this is a bounded wait with a diagnostic dump rather than a single probe.
ok=0
for _ in $(seq 1 30); do
  live_exec test -f "$OPS_COOLDOWN" >/dev/null 2>&1 && { ok=1; break; }
  sleep 1
done
if [ "$ok" = 1 ]; then pass "4: the cooldown timestamp was recorded"
else
  fail "4: no cooldown file 30s after the wake"
  live_exec ls -la /var/lib/palwarden-ops >&2 2>/dev/null || true
fi
# NOTE: the daemon logs "wake started" only AFTER its readiness poll completes
# (up to 180s), so that assertion lives in scenario 6, after REST readiness —
# grepping here would race the very poll the wake is inside.

# =============================================================================
# Scenario 5 — a retry inside the cooldown is refused.
# Stop through the supported job path (an administrative stop is a deliberate
# override of nothing here — it is exactly how an operator would stop it),
# then knock again well inside the cooldown window.
# =============================================================================
# The wake transaction from scenario 4 holds the lifecycle lock until its
# REST-readiness poll completes — with the REAL game that is the world load
# (~1 min, bounded by PALWARDEN_WAKE_READY_TIMEOUT_S), the window the Docker
# fake server never showed. jobd refuses wrapped jobs while the lock is busy
# (reviewed design: the operator retries); wait for the wake to finish before
# enqueueing the administrative stop.
ok=0
for _ in $(seq 1 $((WAKE_SETTLE / 5))); do
  live_exec palworld-api info 2>/dev/null | grep -q servername && { ok=1; break; }
  sleep 5
done
assert_eq "$ok" "1" "5: the wake transaction completed (REST-ready) before the stop"
s_id="$(live_enqueue graceful_stop '{"wait":0,"confirm":true}')" \
  || { fail "5: could not enqueue the graceful_stop job"; assert_report; exit 1; }
assert_eq "$(live_wait_job "$s_id" "$STOP_TIMEOUT")" "succeeded" \
  "5: graceful_stop of the woken server succeeded (job $s_id)"
# The first wake's cooldown has COOLDOWN_S seconds from before that start;
# the stop itself consumed part of it, so knock now must be refused for the
# remainder — at minimum, the server must stay down.
# Knock like a real client: the lease gap (~0.15s per second) can drop a
# single datagram by design (scenario 4's own reasoning), so ring until the
# daemon logs the cooldown no-op, bounded. Asserting "stayed down" before
# the packet was demonstrably handled would pass vacuously on a dropped
# datagram — which is exactly how this assertion failed once in the live
# tier while the cooldown refusal itself worked.
ok=0
for _ in $(seq 1 30); do
  udp_knock "$LIVE_UDP_PORT" "$TOKEN"
  if live_compose logs palwarden 2>/dev/null | grep -q "wake was a no-op (cooldown"; then
    ok=1; break
  fi
  sleep 1
done
if [ "$ok" = 1 ]; then pass "5: the daemon logged the refused retry as a cooldown no-op"
else
  fail "5: no cooldown no-op line for the refused retry"
  # Self-diagnostic dump: which refusal path did the knock take?
  live_log "diag: knock service state: $(live_exec s6-svstat /run/service/palworld-knock 2>&1 || true)"
  live_log "diag: cooldown stamp: $(live_exec cat "$OPS_COOLDOWN" 2>&1 || true)"
  live_log "diag: lifecycle state: $(live_exec cat /var/lib/palwarden-ops/lifecycle/state.json 2>&1 || true)"
  live_compose logs --tail=200 palwarden 2>/dev/null | grep -ai 'knock\|wake\|cooldown\|Traceback' | tail -30 >&2 || true
fi
assert_eq "$(svc_state palworld-server)" "down" \
  "5: a knock inside the cooldown did not restart the server"

# =============================================================================
# Scenario 6 — after the cooldown, knock wakes again, onto the saved world.
# =============================================================================
ok=0
for _ in $(seq 1 $((COOLDOWN_S + 60))); do
  udp_knock "$LIVE_UDP_PORT" "$TOKEN"
  [ "$(svc_state palworld-server)" = up ] && { ok=1; break; }
  sleep 1
done
if [ "$ok" = 1 ]; then pass "6: knock after the cooldown expiry woke the server"
else fail "6: knock never woke the server after the cooldown expired"; fi

# Readiness the way every job measures it, bounded.
deadline=$((SECONDS + WAKE_SETTLE))
ok=0
while ((SECONDS < deadline)); do
  live_exec palworld-api info 2>/dev/null | grep -q servername && { ok=1; break; }
  sleep 5
done
assert_eq "$ok" "1" "6: the woken server answers its REST API — it loaded a world"

# By now the scenario-4 wake's readiness poll has completed (this server just
# answered REST through it), so the daemon's completion line is in the log.
if live_compose logs palwarden 2>/dev/null | grep -q "wake started"; then
  pass "the wake is recorded in the service log"
else
  fail "no 'wake started' line in the service log"
  live_compose logs --tail 60 palwarden 2>/dev/null | grep -i knock >&2 || true
fi

# The world it woke on is the world the idle stop saved: same world
# directories (this run's before against this run's after — a freshly
# generated world would be healthy, REST-ready, and WRONG), and this run's
# marker still in the tree.
assert_file_contains "$HOST_MARKER" "$MARKER_TEXT" \
  "6: the world tree survived the idle stop and the knock wake"
assert_eq "$(world_dirs)" "$worlds_before" \
  "6: the woken server reopened the world the idle stop saved, not a new one"

# The game owns the port again now that it is up.
if knock_holds; then fail "6: knock kept UDP 8211 after the wake"
else pass "6: the woken game holds UDP 8211 again"; fi

# Restore the shipped defaults (also in the EXIT trap, for the failure paths).
restore_config
assert_contains "$(live_api GET /api/palwarden-config)" '"IDLE_TIMEOUT": 0,' \
  "config restored to defaults for whatever suite runs next"

# live_down runs from the EXIT trap installed above, on every path out of here.
assert_report
