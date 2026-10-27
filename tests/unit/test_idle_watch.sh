#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Task 7 (idle-shutdown/knock-wake): idle tick and live scheduler.
#
# Spec:  docs/superpowers/specs/2026-10-18-idle-shutdown-knock-wake.md  §5.2, §7.2
# Plan:  docs/superpowers/plans/2026-10-18-idle-shutdown-knock-wake.md (Task 7)
#
# Covers: every skip condition (disabled, occupied incl. loading placeholders,
# short/unknown uptime, stale/invalid/missing evidence, locked DB, timestamp
# discontinuity), the eligible path (final empty check under ownership ->
# graceful-stop --wait 0 with inherited lock, idle event, one warning, service
# down confirmed), boundary aborts (config flip, service restart, new player,
# superseded sequence, write failure), reason wording vs the knock policy, and
# monotonic --loop scheduling with a fake clock.
#
# DB fixtures are built through the REAL presence module (create_schema +
# apply_observation), never by hand-inserting presence_state rows — except the
# deliberate corruption fixtures.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TEST_DIR/../.." && pwd)"
WATCH="$ROOT/sbin/palworld-idle-watch"
source "$ROOT/tests/lib/assert.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export ROOT WORK

# --- stub world ---------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/svc/palworld-server" "$WORK/state"
echo down > "$WORK/svc/palworld-server/svstat"
touch "$WORK/svc/palworld-server/down"

cat > "$WORK/bin/s6-svstat" <<EOF
#!/usr/bin/env bash
sf="$WORK/svc/palworld-server/svstat"
case "\$(cat "\$sf" 2>/dev/null)" in
  up) echo "up (pid 4242 pgid 4242) \${UPTAGE:-3600} seconds"; exit 0 ;;
  down) echo "down: status 111, 100 seconds"; exit 1 ;;
  *) echo "query failure" >&2; exit 127 ;;
esac
EOF

# systemctl stub (systemd branch): state from svstat file; uptime from the
# ExecMainStartTimestamp the real systemd and the s6 shim both print in
# "%a %Y-%m-%d %H:%M:%S UTC" form. UPTAGE_SECONDS env controls the age.
cat > "$WORK/bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$1" in
  is-active)
    case "\$(cat "$WORK/svc/palworld-server/svstat" 2>/dev/null)" in
      up) echo active; exit 0 ;;
      *) echo inactive; exit 3 ;;
    esac ;;
  is-enabled)
    if [ -e "$WORK/svc/palworld-server/down" ]; then echo disabled; exit 1
    else echo enabled; exit 0; fi ;;
  show)
    secs="\${UPTAGE_SECONDS:-3600}"
    if [ "\$secs" = garbage ]; then echo "not a timestamp at all"; exit 0; fi
    if [ "\$secs" = empty ]; then echo ""; exit 0; fi
    date -u -d "@\$(( \$(date -u +%s) - secs ))" '+%a %Y-%m-%d %H:%M:%S UTC' ;;
  *) exit 0 ;;
esac
EOF

# players stub: JSON from players.json, exit code from players.rc
cat > "$WORK/bin/palworld-api" <<EOF
#!/usr/bin/env bash
rc="\$(cat "$WORK/players.rc" 2>/dev/null || echo 0)"
if [ -f "$WORK/players.json" ]; then cat "$WORK/players.json"; fi
exit "\$rc"
EOF

# graceful-stop stub: records argv (including whether it genuinely INHERITED
# a live lock descriptor), brings the service down like the real container
# branch does (SIGINT save -> wanted-down).
cat > "$WORK/bin/palworld-graceful-stop" <<EOF
#!/usr/bin/env bash
borrowed=no
if [ -n "\${PALWARDEN_LIFECYCLE_LOCK_FD:-}" ]; then
  PYTHONPATH="$ROOT/lib" python3 -m palwarden_lifecycle borrowed >/dev/null 2>&1 && borrowed=yes
fi
echo "\$* borrowed=\$borrowed" >> "$WORK/stop.log"
if [ -f "$WORK/stop.fails" ]; then exit 1; fi
if [ ! -f "$WORK/stop.nodeown" ]; then
  echo down > "$WORK/svc/palworld-server/svstat"
  touch "$WORK/svc/palworld-server/down"
fi
exit 0
EOF

cat > "$WORK/bin/palworld-notify" <<EOF
#!/usr/bin/env bash
# Function-only, exactly like the shipped lib/palworld-notify: executing it
# delivers nothing; the adapter must SOURCE it and CALL palworld_notify (F9).
palworld_notify() { echo "\$1|\$2" >> "$WORK/notify.log"; }
EOF
chmod +x "$WORK/bin/"*

make_ops() { # make_ops <idle_timeout_min> <interval_s> <knock_enabled> <token>
  # Rendered through the REAL writer so the file is canonical (JSON strings).
  PYTHONPATH="$ROOT/lib" python3 -c '
import sys
import palwarden_ops as ops
sys.stdout.write(ops.render({
    "IDLE_TIMEOUT": int(sys.argv[1]), "IDLE_CHECK_INTERVAL": int(sys.argv[2]),
    "KNOCK_ENABLED": sys.argv[3] == "true", "KNOCK_COOLDOWN": 600,
    "KNOCK_TOKEN": sys.argv[4]}))' "$1" "$2" "$3" "$4" > "$WORK/ops.env.tmp"
  mv -f "$WORK/ops.env.tmp" "$WORK/ops.env"
}

export PYTHONPATH="$ROOT/lib"
export PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock"
export PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/state"
export PALWORLD_METRICS_DB="$WORK/metrics.sqlite3"

# seed_db builds evidence through the REAL presence writer.
# seed_db <mode>: fresh | empty-fresh | empty-old | occupied | invalid | none
seed_db() {
  rm -f "$WORK/metrics.sqlite3"
  [ "$1" = none ] && return
  python3 - "$1" <<'PY'
import sqlite3, sys, time
import palwarden_presence as presence

import os
con = sqlite3.connect(os.environ["PALWORLD_METRICS_DB"])
con.row_factory = sqlite3.Row
presence.create_schema(con)
now = int(time.time() * 1000)
mode = sys.argv[1]
if mode == "empty-old":
    # Chain of empty observations, each within the 60s trust window of the
    # previous, starting 3 minutes ago: the interval must PRESERVE its start.
    for age in (180_000, 120_000, 60_000, 5_000):
        seq = presence.reserve_observation(con)
        presence.apply_observation(con, seq, True, [], now - age)
elif mode == "empty-fresh":
    seq = presence.reserve_observation(con)
    presence.apply_observation(con, seq, True, [], now - 5_000)
elif mode == "occupied":
    seq = presence.reserve_observation(con)
    presence.apply_observation(con, seq, True,
                               [{"playerId": "76561198000000001", "name": "Alice"}],
                               now - 5_000)
elif mode == "loading":
    seq = presence.reserve_observation(con)
    presence.apply_observation(con, seq, True,
                               [{"playerId": "None", "name": "Loading"}],
                               now - 5_000)
elif mode == "invalid":
    seq = presence.reserve_observation(con)
    presence.apply_observation(con, seq, False, None, now - 5_000)
con.close()
PY
}

set_players() { # set_players <json>
  printf '%s' "$1" > "$WORK/players.json"
  rm -f "$WORK/players.rc"
}
set_players_rc() { printf '%s' "$1" > "$WORK/players.rc"; printf '%s' '{}' > "$WORK/players.json"; }

watch() { # one-shot tick; env passthrough for per-case overrides
  env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$HOME" \
    PALWARDEN_CONTAINER=1 \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/state" \
    PALWARDEN_S6_SVC_DIR="$WORK/svc" \
    PALWARDEN_OPS_FILE="$WORK/ops.env" \
    PALWORLD_METRICS_DB="$WORK/metrics.sqlite3" \
    PALWORLD_API_BIN="$WORK/bin/palworld-api" \
    PALWARDEN_GRACEFUL_STOP_BIN="$WORK/bin/palworld-graceful-stop" \
    PALWARDEN_NOTIFY_HELPER="$WORK/bin/palworld-notify" \
    PALWARDEN_IDLE_STOP_CONFIRM_S="${CONFIRM_S:-5}" \
    PALWARDEN_IDLE_STOP_POLL_S="${POLL_S:-0.1}" \
    UPTAGE_SECONDS="${UPTAGE:-3600}" \
    PYTHONPATH="$ROOT/lib" \
    python3 "$WATCH" "$@"
}

reset_case() {
  rm -f "$WORK/stop.log" "$WORK/notify.log" "$WORK/players.rc" \
        "$WORK/stop.fails" "$WORK/stop.nodeown" \
        "$WORK/svc/palworld-server/down"
  # The watcher's precondition is a RUNNING service; every case below then
  # varies ONE other factor. (The stop stub flips this to down on success.)
  echo up > "$WORK/svc/palworld-server/svstat"
}

# ==============================================================================
# 1. Skip conditions — none may stop the server.
# ==============================================================================
reset_case
make_ops 0 60 true ""
seed_db empty-old
set_players '{"players": []}'
out="$(watch)"; rc=$?
assert_eq "$rc" "0" "disabled tick exits 0"
assert_contains "$out" "skip disabled" "IDLE_TIMEOUT=0 skips (got: $out)"
assert_path_absent "$WORK/stop.log" "disabled never stops"

reset_case
make_ops 5 60 true ""
seed_db occupied
out="$(watch)"
assert_contains "$out" "skip presence" "occupied evidence skips (got: $out)"
assert_path_absent "$WORK/stop.log" "occupied never stops"

reset_case
make_ops 5 60 true ""
seed_db loading
out="$(watch)"
assert_contains "$out" "skip presence" "a loading placeholder is occupancy, not emptiness (got: $out)"
assert_path_absent "$WORK/stop.log" "loading never stops"

reset_case
make_ops 5 60 true ""
seed_db empty-old
out="$(UPTAGE=60 watch)"
assert_contains "$out" "skip uptime-short" "uptime below the timeout suppresses even fresh empty evidence (got: $out)"
assert_path_absent "$WORK/stop.log" "short uptime never stops"

reset_case
make_ops 5 60 true ""
seed_db empty-old
out="$(UPTAGE=garbage watch)"
assert_contains "$out" "skip uptime-unknown" "unparseable uptime is UNKNOWN, not idle (got: $out)"
assert_path_absent "$WORK/stop.log" "unknown uptime never stops"
out="$(UPTAGE=empty watch)"
assert_contains "$out" "skip uptime-unknown" "empty uptime is UNKNOWN too (got: $out)"

reset_case
make_ops 5 60 true ""
seed_db empty-fresh   # empty interval only 5s old, timeout 5 min
out="$(watch)"
assert_contains "$out" "skip presence" "empty interval shorter than the timeout skips (got: $out)"

reset_case
make_ops 1 60 true ""
seed_db empty-old
# age the last success beyond the 60s trust window without touching empty_since
python3 - <<'PY'
import os, sqlite3, time
con = sqlite3.connect(os.environ["PALWORLD_METRICS_DB"])
con.execute("UPDATE presence_state SET last_success_ms=? WHERE id=1",
            (int(time.time() * 1000) - 120_000,))
con.commit()
PY
out="$(watch)"
assert_contains "$out" "skip presence" "stale last-success skips even with healthy info (got: $out)"
assert_path_absent "$WORK/stop.log" "stale never stops"

reset_case
make_ops 1 60 true ""
seed_db invalid
out="$(watch)"
assert_contains "$out" "skip presence" "invalid presence skips (got: $out)"

reset_case
make_ops 1 60 true ""
seed_db none
out="$(watch)"
assert_contains "$out" "skip presence" "missing DB is UNKNOWN, not idle (got: $out)"
assert_path_absent "$WORK/stop.log" "missing DB never stops"

reset_case
make_ops 1 60 true ""
: > "$WORK/metrics.sqlite3"   # DB exists but has no presence_state table
out="$(watch)"
assert_contains "$out" "skip presence" "missing table is UNKNOWN (got: $out)"

reset_case
make_ops 1 60 true ""
seed_db empty-old
python3 - "$WORK/metrics.sqlite3" "$WORK/lock.ready" <<'PY' &
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1], timeout=30)
con.execute("BEGIN EXCLUSIVE")
con.execute("UPDATE presence_state SET valid = valid")
open(sys.argv[2], "w").write("ready")
time.sleep(4)
con.rollback()
PY
lock_pid=$!
for _ in $(seq 1 100); do [ -e "$WORK/lock.ready" ] && break; sleep 0.05; done
out="$(watch)"; rc=$?
assert_contains "$out" "skip presence" "a locked DB cannot refresh evidence -> UNKNOWN (got: $out)"
assert_path_absent "$WORK/stop.log" "locked DB never stops"
touch "$WORK/lock.go"; wait "$lock_pid" 2>/dev/null || true

reset_case
make_ops 1 60 true ""
seed_db empty-old
python3 - <<'PY'
import os, sqlite3
con = sqlite3.connect(os.environ["PALWORLD_METRICS_DB"])
row = con.execute("SELECT last_success_ms FROM presence_state WHERE id=1").fetchone()
con.execute("UPDATE presence_state SET empty_since_ms=? WHERE id=1", (row[0] + 60_000,))
con.commit()
PY
out="$(watch)"
assert_contains "$out" "skip presence" "empty_since AFTER last-success is a discontinuity (got: $out)"

reset_case
make_ops 1 60 true ""
seed_db empty-old
python3 - <<'PY'
import os, sqlite3, time
con = sqlite3.connect(os.environ["PALWORLD_METRICS_DB"])
con.execute("UPDATE presence_state SET empty_since_ms=? WHERE id=1",
            (int(time.time() * 1000) + 600_000,))
con.commit()
PY
out="$(watch)"
assert_contains "$out" "skip presence" "future-dated empty_since is a discontinuity (got: $out)"

reset_case
make_ops 1 60 true ""
seed_db empty-old
set_players '{"players": []}'
python3 -c '
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=2, owner_pid=os.getpid(), owner_comm="busy-holder")
open(os.environ["WORK"] + "/busy.ready", "w").write("r")
import time; time.sleep(3)
lc.release(fd)
' &
busy_pid=$!
for _ in $(seq 1 100); do [ -e "$WORK/busy.ready" ] && break; sleep 0.05; done
out="$(watch)"
assert_contains "$out" "skip busy" "lock contention skips the tick (got: $out)"
assert_path_absent "$WORK/stop.log" "busy never stops"
wait "$busy_pid" 2>/dev/null || true

# ==============================================================================
# 2. The eligible path.
# ==============================================================================
reset_case
make_ops 1 60 true ""
seed_db empty-old
set_players '{"players": []}'
out="$(watch)"; rc=$?
assert_eq "$rc" "0" "eligible tick exits 0 (got rc=$rc: $out)"
assert_contains "$out" "stop issued" "eligible + final-empty stops (got: $out)"
assert_file_exists "$WORK/stop.log" "graceful-stop was invoked"
stopline="$(cat "$WORK/stop.log")"
assert_contains "$stopline" "--wait 0" "stop uses --wait 0 (got: $stopline)"
assert_contains "$stopline" "--message" "stop carries a message"
assert_contains "$stopline" "borrowed=yes" "graceful-stop runs under the INHERITED lifecycle lock, not a re-acquire"
assert_file_not_contains "$WORK/stop.log" "FORBIDDEN" "no forbidden verbs"
ev="$(python3 -c '
import os, sqlite3
con = sqlite3.connect(os.environ["PALWORLD_METRICS_DB"])
row = con.execute("SELECT label, category FROM fps_events WHERE category=\"idle\"").fetchone()
print("none" if row is None else row[1])')"
assert_eq "$ev" "idle" "an idle event was recorded"
warns="$(grep -c '^warning|' "$WORK/notify.log" 2>/dev/null || true)"
assert_eq "${warns:-0}" "1" "exactly one dedicated warning notification"
assert_eq "$(cat "$WORK/svc/palworld-server/svstat")" "down" "service down confirmed before reporting success"

# An ABSENT notify helper (not merely failing) must not break the stop either:
# the Python spawn raises FileNotFoundError, which the bash-only invariant in
# test_notify_optional.sh cannot see (spec §6.3).
reset_case
make_ops 1 60 true ""
seed_db empty-old
set_players '{"players": []}'
mv "$WORK/bin/palworld-notify" "$WORK/bin/palworld-notify.hidden"
out="$(watch)"; rc=$?
mv "$WORK/bin/palworld-notify.hidden" "$WORK/bin/palworld-notify"
assert_eq "$rc" "0" "eligible tick still stops with no notify helper (got rc=$rc: $out)"
assert_file_exists "$WORK/stop.log" "the stop happened despite the missing helper"

# reason wording must match the wake policy — no false knock promises
reset_case
make_ops 1 60 false ""
seed_db empty-old
set_players '{"players": []}'
watch >/dev/null
assert_file_exists "$WORK/stop.log" "knock-disabled still idle-stops"
assert_not_contains "$(cat "$WORK/stop.log")" "knock" "disabled knock: the reason never promises a knock wake"

reset_case
make_ops 1 60 true "s3cret-token"
seed_db empty-old
set_players '{"players": []}'
watch >/dev/null
assert_contains "$(cat "$WORK/stop.log")" "token" "token mode: the reason explains the token wake"
assert_not_contains "$(cat "$WORK/stop.log")" "s3cret-token" "the token itself never enters the message"

reset_case
make_ops 1 60 true ""
seed_db empty-old
set_players '{"players": []}'
watch >/dev/null
assert_contains "$(cat "$WORK/stop.log")" "Knock" "open doorbell: the reason may promise a knock"

# ==============================================================================
# 3. Boundary aborts — the final check and revalidations must be able to stop
#    the stop.
# ==============================================================================
reset_case
make_ops 1 60 true ""
seed_db empty-old
set_players '{"players": [{"playerId": "76561198000000002", "name": "Bob"}]}'
out="$(watch)"
assert_contains "$out" "abort final=occupied" "a joining player aborts the stop (got: $out)"
assert_path_absent "$WORK/stop.log" "joining player never gets stopped"
cleared="$(python3 -c '
import os, sqlite3
con = sqlite3.connect(os.environ["PALWORLD_METRICS_DB"])
print(con.execute("SELECT empty_since_ms FROM presence_state WHERE id=1").fetchone()[0])')"
assert_eq "$cleared" "None" "the occupied final check CLEARED the stored empty interval (new full period required)"

reset_case
make_ops 1 60 true ""
seed_db empty-old
set_players_rc 1
out="$(watch)"
assert_contains "$out" "abort final=error" "a failing final API call aborts (got: $out)"
assert_path_absent "$WORK/stop.log" "API failure never stops"
inv="$(python3 -c '
import os, sqlite3
con = sqlite3.connect(os.environ["PALWORLD_METRICS_DB"])
print(con.execute("SELECT valid FROM presence_state WHERE id=1").fetchone()[0])')"
assert_eq "$inv" "0" "the failed final check invalidated evidence"

reset_case
make_ops 1 60 true ""
seed_db empty-old
printf '%s' 'not json at all' > "$WORK/players.json"
out="$(watch)"
assert_contains "$out" "abort final=error" "a malformed final payload aborts (got: $out)"
assert_path_absent "$WORK/stop.log" "malformed payload never stops"

reset_case
make_ops 1 60 true ""
seed_db empty-old
set_players '{"players": []}'
touch "$WORK/stop.fails"
out="$(watch)"; rc=$?
assert_eq "$rc" "1" "a failing graceful-stop exits nonzero (got rc=$rc: $out)"
assert_contains "$out" "stop failed" "stop failure is reported as such (got: $out)"
rm -f "$WORK/stop.fails"

reset_case
make_ops 1 60 true ""
seed_db empty-old
set_players '{"players": []}'
touch "$WORK/stop.nodeown"   # stub stops nothing: service stays up
CONFIRM_S=1 POLL_S=0.1 out="$(watch)"; rc=$?
assert_eq "$rc" "1" "no service-down confirmation is a failure (got rc=$rc: $out)"
assert_contains "$out" "stop failed" "unconfirmed stop is reported (got: $out)"

# --- in-process module tier: interleavings a subprocess cannot time ------------
module_tests() {
python3 - "$WATCH" "$WORK" <<'PY'
import importlib.machinery, importlib.util, os, sqlite3, sys, time
watch_path, work = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("idle_watch", watch_path)
spec = importlib.util.spec_from_loader("idle_watch", loader)
iw = importlib.util.module_from_spec(spec)
loader.exec_module(iw)
import palwarden_presence as presence

def fresh_db(mode="empty-old"):
    path = os.path.join(work, "mod.sqlite3")
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    presence.create_schema(con)
    now = int(time.time() * 1000)
    if mode == "empty-old":
        for age in (180_000, 120_000, 60_000, 5_000):
            s = presence.reserve_observation(con)
            presence.apply_observation(con, s, True, [], now - age)
    con.close()
    return path

results = []
def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))

# A newer sampler observation lands between our reserve and apply: the final
# result is superseded and MUST NOT stop.
fresh_db()
calls = {"stop": 0}
def fetch_superseding():
    con = sqlite3.connect(os.path.join(work, "mod.sqlite3"))
    con.row_factory = sqlite3.Row
    s = presence.reserve_observation(con)
    presence.apply_observation(con, s, True,
                               [{"playerId": "1", "name": "X"}],
                               int(time.time() * 1000))
    con.close()
    return []   # our own (now stale) answer says empty
decision = iw.tick(deps={
    "config": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
               "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""},
    "state": lambda: "running",
    "uptime_s": lambda: 3600,
    "db_path": os.path.join(work, "mod.sqlite3"),
    "fetch_players": fetch_superseding,
    "acquire": lambda: None,
    "release": lambda fd: None,
    "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
    "notify": lambda kind, text: None,
})
check("superseded final result cannot stop",
      decision.startswith("abort final=superseded") and calls["stop"] == 0, decision)

# Config disabled between the eligibility read and the final check.
fresh_db()
calls = {"stop": 0}
configs = iter([{"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
                 "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""},
                {"IDLE_TIMEOUT": 0, "IDLE_CHECK_INTERVAL": 60,
                 "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""}])
decision = iw.tick(deps={
    "config": lambda: next(configs),
    "state": lambda: "running",
    "uptime_s": lambda: 3600,
    "db_path": os.path.join(work, "mod.sqlite3"),
    "fetch_players": lambda: [],
    "acquire": lambda: None,
    "release": lambda fd: None,
    "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
    "notify": lambda kind, text: None,
})
check("config flip to disabled aborts", decision.startswith("abort config") and calls["stop"] == 0, decision)

# Service restarted (uptime resets) between eligibility and final check.
fresh_db()
calls = {"stop": 0}
uptimes = iter([3600, 5])
decision = iw.tick(deps={
    "config": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
               "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""},
    "state": lambda: "running",
    "uptime_s": lambda: next(uptimes),
    "db_path": os.path.join(work, "mod.sqlite3"),
    "fetch_players": lambda: [],
    "acquire": lambda: None,
    "release": lambda fd: None,
    "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
    "notify": lambda kind, text: None,
})
check("uptime reset under the watcher aborts", decision.startswith("abort uptime") and calls["stop"] == 0, decision)

# State flipped to stopping under us aborts.
fresh_db()
calls = {"stop": 0}
states = iter(["running", "stopping"])
decision = iw.tick(deps={
    "config": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
               "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""},
    "state": lambda: next(states),
    "uptime_s": lambda: 3600,
    "db_path": os.path.join(work, "mod.sqlite3"),
    "fetch_players": lambda: [],
    "acquire": lambda: None,
    "release": lambda fd: None,
    "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
    "notify": lambda kind, text: None,
})
check("state flip aborts", decision.startswith("abort state") and calls["stop"] == 0, decision)

# R5a (Sol review): the idle shutdown is an OUTER lifecycle transaction. It
# acquires the lock itself (no bridge), so it must publish active + rotate
# BEFORE stopping and complete idle after — otherwise a wake admitted during
# the stop sees a plain `idle` marker and starts the server mid-shutdown.
import palwarden_lifecycle as _lc
fresh_db()
_lc.write_state("idle", rotate=True, force=True)
gen_r5 = _lc.read_state()["generation"]
seen_r5 = {}
def stop_capture(reason, fd):
    seen_r5["during"] = _lc.read_state()["status"]
    seen_r5["rotated"] = _lc.read_state()["generation"] != gen_r5
    return True
decision = iw.tick(deps={
    "config": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
               "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""},
    "state": lambda: "running",
    "uptime_s": lambda: 3600,
    "db_path": os.path.join(work, "mod.sqlite3"),
    "fetch_players": lambda: [],
    "stop": stop_capture,
    "notify": lambda kind, text: None,
})
after_r5 = _lc.read_state()
check("idle shutdown publishes active + rotated generation during stop",
      seen_r5.get("during") == "active" and seen_r5.get("rotated"),
      decision + " " + str(seen_r5))
check("idle shutdown completes idle after a successful stop",
      after_r5["status"] == "idle" and decision.startswith("stop issued"),
      decision + " " + after_r5["status"])

# F4 (review follow-up): the policy changed WHILE the final players request
# is in flight. Disabling idle (or raising its timeout) during the fetch must
# prevent the not-yet-issued stop; a stop already issued cannot be undone.
fresh_db()
calls = {"stop": 0}
holder = {"cfg": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
                  "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""}}
def fetch_disable():
    holder["cfg"] = dict(holder["cfg"], IDLE_TIMEOUT=0)
    return []
decision = iw.tick(deps={
    "config": lambda: dict(holder["cfg"]),
    "state": lambda: "running",
    "uptime_s": lambda: 3600,
    "db_path": os.path.join(work, "mod.sqlite3"),
    "fetch_players": fetch_disable,
    "acquire": lambda: None,
    "release": lambda fd: None,
    "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
    "notify": lambda kind, text: None,
})
check("disabling idle during the final fetch prevents the stop",
      decision.startswith("abort final=config") and calls["stop"] == 0, decision)

fresh_db()
calls = {"stop": 0}
holder = {"cfg": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
                  "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""}}
def fetch_raise_timeout():
    holder["cfg"] = dict(holder["cfg"], IDLE_TIMEOUT=120)
    return []
decision = iw.tick(deps={
    "config": lambda: dict(holder["cfg"]),
    "state": lambda: "running",
    "uptime_s": lambda: 3600,
    "db_path": os.path.join(work, "mod.sqlite3"),
    "fetch_players": fetch_raise_timeout,
    "acquire": lambda: None,
    "release": lambda fd: None,
    "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
    "notify": lambda kind, text: None,
})
check("raising the timeout during the final fetch prevents the stop",
      decision.startswith("abort") and calls["stop"] == 0, decision)

# F5 (review follow-up): a failed final check must apply its invalidation
# THROUGH ITS RESERVED SEQUENCE, so an older in-flight sampler response
# cannot resurrect the empty interval it just invalidated.
path = fresh_db()
con = sqlite3.connect(path); con.row_factory = sqlite3.Row
s_old = presence.reserve_observation(con)   # sampler response already in flight
con.close()
calls = {"stop": 0}
def fetch_fails():
    raise RuntimeError("players endpoint down")
decision = iw.tick(deps={
    "config": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
               "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""},
    "state": lambda: "running",
    "uptime_s": lambda: 3600,
    "db_path": path,
    "fetch_players": fetch_fails,
    "acquire": lambda: None,
    "release": lambda fd: None,
    "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
    "notify": lambda kind, text: None,
})
con = sqlite3.connect(path); con.row_factory = sqlite3.Row
late = presence.apply_observation(con, s_old, True, [], int(time.time() * 1000))
row = con.execute("SELECT valid, empty_since_ms, applied_seq "
                  "FROM presence_state WHERE id=1").fetchone()
con.close()
check("failed final check fences the older in-flight sampler response",
      decision.startswith("abort final=error") and calls["stop"] == 0
      and late["applied"] is False and int(row["valid"]) == 0
      and row["empty_since_ms"] is None,
      "%s late=%s row=%s" % (decision, late, tuple(row)))

# F5 companion: an OLDER failure can never erase newer successful evidence
# (the fence must cover failure applications too, not only successes).
path = fresh_db()
con = sqlite3.connect(path); con.row_factory = sqlite3.Row
now = int(time.time() * 1000)
s5 = presence.reserve_observation(con)
presence.apply_observation(con, s5, True, [], now)          # applied=5, valid
s6 = presence.reserve_observation(con)
presence.apply_observation(con, s6, False, None, now + 1)   # newer failure
s7 = presence.reserve_observation(con)
presence.apply_observation(con, s7, True, [], now + 2)      # newer success
replay = presence.apply_observation(con, s5, False, None, now + 3)  # old failure
row = con.execute("SELECT valid, empty_since_ms FROM presence_state "
                  "WHERE id=1").fetchone()
con.close()
check("older failure cannot erase newer success",
      replay["applied"] is False and int(row["valid"]) == 1
      and row["empty_since_ms"] is not None,
      "replay=%s row=%s" % (replay, tuple(row)))

# A write failure at apply time cannot stop.
fresh_db()
calls = {"stop": 0}
def broken_apply(con, seq, ok, players, at_ms, grace_ms=None):
    raise sqlite3.OperationalError("database is locked")
decision = iw.tick(deps={
    "config": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
               "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""},
    "state": lambda: "running",
    "uptime_s": lambda: 3600,
    "db_path": os.path.join(work, "mod.sqlite3"),
    "fetch_players": lambda: [],
    "acquire": lambda: None,
    "release": lambda fd: None,
    "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
    "notify": lambda kind, text: None,
    "apply_observation": broken_apply,
})
check("apply failure cannot stop", decision.startswith("abort final=db") and calls["stop"] == 0, decision)

# --loop scheduling with a fake clock: interval edits recompute relative to
# the LAST tick; an overdue tick runs promptly.
clock = {"t": 1000.0}
ticks = []
def fake_sleep(secs):
    clock["t"] += secs
    if clock["t"] > 4000:
        raise SystemExit
configs = [
    {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60, "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""},
    {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 10, "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""},
]
def fake_tick():
    ticks.append(clock["t"])
    if len(ticks) == 1:
        configs.pop(0)   # interval edit 60 -> 10 lands right after the first tick
    return "skip disabled"
try:
    iw.run_loop(tick_fn=fake_tick,
                config_fn=lambda: configs[0],
                clock=lambda: clock["t"],
                sleep=fake_sleep)
except SystemExit:
    pass   # fake_sleep's stop signal
check("first tick immediate", len(ticks) >= 1 and abs(ticks[0] - 1000.0) < 0.001, str(ticks))
if len(ticks) >= 2:
    check("interval edit reschedules relative to the last tick",
          abs(ticks[1] - ticks[0] - 10.0) < 1.5, str(ticks))

# R6 (Sol round 2): policy changed during the BLOCKING event/notify work
# must still abort — the gate re-runs immediately at dispatch. A stop
# already issued cannot be undone, but here it is not yet issued.
for flip_point in ("event", "notify"):
    fresh_db()
    calls = {"stop": 0}
    holder = {"cfg": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
                      "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""}}
    def flip():
        holder["cfg"] = dict(holder["cfg"], IDLE_TIMEOUT=0)
    deps = {
        "config": lambda: dict(holder["cfg"]),
        "state": lambda: "running",
        "uptime_s": lambda: 3600,
        "db_path": os.path.join(work, "mod.sqlite3"),
        "fetch_players": lambda: [],
        "acquire": lambda: None,
        "release": lambda fd: None,
        "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
        "notify": lambda kind, text: None,
    }
    if flip_point == "event":
        deps["event"] = lambda tmin: flip()
    else:
        deps["notify"] = lambda kind, text: flip()
    decision = iw.tick(deps=deps)
    check("disabling idle during %s prevents the stop" % flip_point,
          decision.startswith("abort final=config") and calls["stop"] == 0,
          decision)

# R6: timeout raised during notify — under the NEW policy the observed-
# empty window/uptime no longer holds; the dispatch gate must abort.
fresh_db()
calls = {"stop": 0}
holder = {"cfg": {"IDLE_TIMEOUT": 1, "IDLE_CHECK_INTERVAL": 60,
                  "KNOCK_ENABLED": True, "KNOCK_TOKEN": ""}}
decision = iw.tick(deps={
    "config": lambda: dict(holder["cfg"]),
    "state": lambda: "running",
    "uptime_s": lambda: 3600,
    "db_path": os.path.join(work, "mod.sqlite3"),
    "fetch_players": lambda: [],
    "acquire": lambda: None,
    "release": lambda fd: None,
    "stop": lambda reason, fd: calls.__setitem__("stop", calls["stop"] + 1) or True,
    "notify": lambda kind, text: holder.__setitem__(
        "cfg", dict(holder["cfg"], IDLE_TIMEOUT=120)),
})
check("raising the timeout during notify prevents the stop",
      decision.startswith("abort final=") and calls["stop"] == 0, decision)

fails = 0
for name, ok, detail in results:
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else " :: " + detail))
    fails += 0 if ok else 1
sys.exit(1 if fails else 0)
PY
}
mt_out="$(module_tests)"; mt_rc=$?
echo "$mt_out" | while IFS= read -r line; do echo "  module: $line"; done
mt_pass="$(printf '%s\n' "$mt_out" | grep -c '^PASS ' || true)"
mt_fail="$(printf '%s\n' "$mt_out" | grep -c '^FAIL ' || true)"
for _i in $(seq 1 "$((mt_pass > 0 ? mt_pass : 1))"); do pass; done
if [ "${mt_pass:-0}" -lt 6 ]; then
  fail "idle-watch module boundary tests: only $mt_pass/6 checks reported (rc=$mt_rc)"
elif [ "${mt_fail:-0}" -gt 0 ] || [ "$mt_rc" -ne 0 ]; then
  fail "idle-watch module boundary tests: $mt_fail failed (rc=$mt_rc)"
fi

# ==============================================================================
# 3b. F3 (review follow-up): wrong-shaped or ambiguous players JSON must be a
#     parse ERROR that invalidates evidence — never a silently-empty list that
#     authorizes a stop. Reviewer reproductions, verbatim.
# ==============================================================================
for bad in '[{"players": []}]' \
           '{"players": [{"playerId": "A"}], "players": []}' \
           '{"players": []} trailing garbage'; do
  reset_case
  make_ops 1 60 true ""
  seed_db empty-old
  set_players "$bad"
  out="$(watch)"; rc=$?
  assert_eq "$rc" "0" "tick survives malformed payload '$bad' (rc=$rc: $out)"
  assert_contains "$out" "abort final=error" \
    "ambiguous payload '$bad' is a parse error, not empty (got: $out)"
  if [ ! -f "$WORK/stop.log" ]; then
    pass "no stop issued for '$bad'"
  else
    fail "STOP WAS ISSUED for '$bad': $(cat "$WORK/stop.log")"
  fi
  if [ ! -f "$WORK/notify.log" ]; then
    pass "no warning issued for '$bad'"
  else
    fail "notification fired for '$bad': $(cat "$WORK/notify.log")"
  fi
done

# A legitimate empty object response still authorizes the stop (the strict
# parser must not break the happy path).
reset_case
make_ops 1 60 true ""
seed_db empty-old
set_players '{"players": []}'
out="$(watch)"; rc=$?
assert_eq "$rc" "0" "legitimate empty response still stops (rc=$rc: $out)"
assert_contains "$out" "stop issued" "strict parser keeps the happy path (got: $out)"

# ==============================================================================
# 4. --loop with the real wiring: config refresh >= 1/s, live interval edits.
# ==============================================================================
reset_case
make_ops 0 1 true ""
seed_db empty-old
set_players '{"players": []}'
env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$HOME" \
  PALWARDEN_CONTAINER=1 \
  PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
  PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/state" \
  PALWARDEN_S6_SVC_DIR="$WORK/svc" \
  PALWARDEN_OPS_FILE="$WORK/ops.env" \
  PALWORLD_METRICS_DB="$WORK/metrics.sqlite3" \
  PALWORLD_API_BIN="$WORK/bin/palworld-api" \
  PALWARDEN_GRACEFUL_STOP_BIN="$WORK/bin/palworld-graceful-stop" \
  PALWARDEN_NOTIFY_HELPER="$WORK/bin/palworld-notify" \
  PALWARDEN_IDLE_STOP_CONFIRM_S=5 \
  UPTAGE_SECONDS=3600 PYTHONPATH="$ROOT/lib" \
  python3 "$WATCH" --loop >"$WORK/loop.log" 2>&1 &
loop_pid=$!
sleep 2.2
# Flip enable mid-loop: the next tick must see it without a restart.
make_ops 1 1 true ""
ok=0
for _ in $(seq 1 80); do grep -q 'skip presence\|stop issued\|skip uptime' "$WORK/loop.log" && { ok=1; break; }; sleep 0.05; done
kill -TERM "$loop_pid" 2>/dev/null
wait "$loop_pid" 2>/dev/null || true
assert_eq "$ok" "1" "--loop picks up a live IDLE_TIMEOUT edit without restart (log: $(tr '\n' '|' < "$WORK/loop.log"))"

# ==============================================================================
# 5. Usage.
# ==============================================================================
out="$(watch --bogus 2>&1)"; rc=$?
assert_eq "$rc" "64" "unknown flag exits 64"

assert_report
