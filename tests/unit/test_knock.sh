#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Task 5 (idle-shutdown/knock-wake): truthful idempotent start — the service
# state adapter, cooldown gating, and `palworld-knock wake`.
#
# Spec:  docs/superpowers/specs/2026-10-18-idle-shutdown-knock-wake.md  §4.3, §6.2, §6.3
# Plan:  docs/superpowers/plans/2026-10-18-idle-shutdown-knock-wake.md (Task 5)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
ROOT="$DIR/../.."
KNOCK="$ROOT/sbin/palworld-knock"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/svc/palworld-server" "$WORK/state"

# --- stubs --------------------------------------------------------------------
# s6-svstat answers from a state file: up / down / fail.
cat > "$WORK/bin/s6-svstat" <<EOF
#!/usr/bin/env bash
sf="$WORK/svc/palworld-server/svstat"
case "\$(cat "\$sf" 2>/dev/null)" in
  up)   echo "up (pid 4242 pgid 4242) 100 seconds"; exit 0 ;;
  starting) echo "up (no pid) 0 seconds"; exit 0 ;;
  down) echo "down: status 111, 100 seconds"; exit 1 ;;
  *)    echo "s6-svstat: unable: query failure" >&2; exit 127 ;;
esac
EOF
# systemctl: mutating commands act on the same state file; logs every argv.
# start refuses to clobber a concurrent start (mirrors real exclusion: only
# one wake ever reaches the starter, but the log is the race oracle).
cat > "$WORK/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/systemctl.log"
case "\$1" in
  start)
    if [ -e "$WORK/start.sleep" ]; then sleep "$(cat "$WORK/start.sleep" 2>/dev/null || echo 0)"; fi
    if [ -e "$WORK/log_fdenv" ]; then
      # Liveness, not mere presence: subprocess defaults to close_fds=True,
      # which closes the lock fd in the child even when CLOEXEC was cleared —
      # a logged-but-dead FDENV was a real production bug (Task 11).
      _fd="\${PALWARDEN_LIFECYCLE_LOCK_FD:-}"
      if [ -n "\$_fd" ] && [ -e "/proc/self/fd/\$_fd" ]; then
        echo "FDENV=\$_fd LIVE" >> "$WORK/systemctl.log"
      else
        echo "FDENV=\${_fd:-none} DEAD" >> "$WORK/systemctl.log"
      fi
    fi
    if [ -e "$WORK/knock.cooldown" ]; then
      echo "COOLDOWN_AT_START=yes" >> "$WORK/systemctl.log"
    else
      echo "COOLDOWN_AT_START=no" >> "$WORK/systemctl.log"
    fi
    if [ -e "$WORK/start.fail" ]; then exit 1; fi
    if [ -e "$WORK/start.delay" ]; then
      # Model s6's async spawn: s6-svc -u returns, supervise flips the
      # status a moment later (the Task 11 race).
      sleep "\$(cat "$WORK/start.delay")"
    fi
    rm -f "$WORK/svc/palworld-server/down"   # s6-svc -u clears the wanted-down marker
    echo up > "$WORK/svc/palworld-server/svstat"; exit 0 ;;
  stop|restart) echo "FORBIDDEN:\$1" >> "$WORK/systemctl.log"; exit 0 ;;
  is-active)
    if [ "\$(cat "$WORK/svc/palworld-server/svstat" 2>/dev/null)" = up ]; then echo active; exit 0
    else echo inactive; exit 3; fi ;;
  is-enabled)
    if [ -e "$WORK/unit.disabled" ]; then echo disabled; exit 1; else echo enabled; exit 0; fi ;;
  *) exit 0 ;;
esac
EOF
# palworld-api: exit code from a file (default 0); logs calls.
cat > "$WORK/bin/palworld-api" <<EOF
#!/usr/bin/env bash
echo api >> "$WORK/api.log"
code=\$(cat "$WORK/api.code" 2>/dev/null || echo 0)
n=\$(("\$(cat "$WORK/api.calls" 2>/dev/null || echo 0)" + 1)); echo "\$n" > "$WORK/api.calls"
if [ -e "$WORK/api.succeed_on" ]; then
  [ "\$n" -ge "\$(cat "$WORK/api.succeed_on")" ] && code=0
fi
[ "\$code" = 0 ] && echo '{"serverfps": 50}'
exit "\$code"
EOF
# notify helper: records argv; fails on demand. Function-only, exactly like
# the shipped lib/palworld-notify: the adapter must source it and CALL
# palworld_notify (F9).
cat > "$WORK/bin/palworld-notify" <<EOF
#!/usr/bin/env bash
palworld_notify() {
  echo "notify \$1 \$2" >> "$WORK/notify.log"
  [ -e "$WORK/notify.fail" ] && exit 1
  exit 0
}
EOF
chmod +x "$WORK/bin/s6-svstat" "$WORK/bin/systemctl" "$WORK/bin/palworld-api" "$WORK/bin/palworld-notify"

# --- fixture helpers ------------------------------------------------------------
# Default world: embedded container, service fully stopped (down + wanted-down).
echo down > "$WORK/svc/palworld-server/svstat"
touch "$WORK/svc/palworld-server/down"
# The ops config file is schema-complete (all five keys, canonical order).
make_ops() { # make_ops <enabled> <token>  (atomic: the daemon re-reads every lease)
  PYTHONPATH="$ROOT/lib" python3 -c '
import sys
import palwarden_ops as ops
sys.stdout.write(ops.render({
    "IDLE_TIMEOUT": 0, "IDLE_CHECK_INTERVAL": 60,
    "KNOCK_ENABLED": sys.argv[1] == "true", "KNOCK_COOLDOWN": 600,
    "KNOCK_TOKEN": sys.argv[2]}))' "$1" "$2" > "$WORK/ops.env.tmp"
  mv -f "$WORK/ops.env.tmp" "$WORK/ops.env"
}
make_ops true "synthetic-token-DO-NOT-LEAK"

wake() { # wake [args...]
  env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$HOME" \
    PALWARDEN_CONTAINER=1 \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/state" \
    PALWARDEN_S6_SVC_DIR="$WORK/svc" \
    PALWARDEN_OPS_FILE="$WORK/ops.env" \
    PALWORLD_KNOCK_COOLDOWN_FILE="$WORK/knock.cooldown" \
    PALWORLD_API_BIN="$WORK/bin/palworld-api" \
    PALWARDEN_NOTIFY_HELPER="$WORK/bin/palworld-notify" \
    PALWARDEN_WAKE_READY_TIMEOUT_S="${WAKE_READY_TIMEOUT_S:-2}" \
    PALWARDEN_WAKE_POLL_INTERVAL_S=0.05 \
    python3 "$KNOCK" wake "$@"
}
lc_env() { # env prefix for direct module probes
  env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$HOME" \
    PALWARDEN_CONTAINER=1 \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/state" \
    PALWARDEN_S6_SVC_DIR="$WORK/svc" \
    PALWARDEN_OPS_FILE="$WORK/ops.env" \
    PALWORLD_KNOCK_COOLDOWN_FILE="$WORK/knock.cooldown" \
    PYTHONPATH="$ROOT/lib" "$@"
}
# Initial world carries a lifecycle state file (real boot runs init-runtime;
# wake requires a CONFIRMED idle lifecycle).
lc_env python3 -c 'import palwarden_lifecycle as lc; lc.ensure_state()' >/dev/null
reset_world() {
  echo down > "$WORK/svc/palworld-server/svstat"
  touch "$WORK/svc/palworld-server/down"
  rm -f "$WORK/systemctl.log" "$WORK/api.log" "$WORK/notify.log" \
        "$WORK/knock.cooldown" "$WORK/api.code" "$WORK/start.fail" \
        "$WORK/api.calls" "$WORK/api.succeed_on" "$WORK/notify.fail" \
        "$WORK/start.delay"
  # Real boot always runs init-runtime before anything can wake; wake is
  # spec-bound to a CONFIRMED idle lifecycle, so the world needs its state
  # file (ensure_state keeps an existing active/unsafe marker — sections
  # that want unsafe write it explicitly).
  lc_env python3 -c 'import palwarden_lifecycle as lc; lc.ensure_state()' >/dev/null
}

# ==============================================================================
# 1. Service-state adapter (s6 branch): actual + wanted, six distinct states.
# ==============================================================================
probe_state() { lc_env python3 -c 'import palwarden_lifecycle as lc; print(lc.service_state())'; }
rm -f "$WORK/svc/palworld-server/down"   # each probed world is set explicitly below

echo up > "$WORK/svc/palworld-server/svstat"
assert_eq "$(probe_state)" "running" "s6: up without a down marker is running"
echo starting > "$WORK/svc/palworld-server/svstat"
assert_eq "$(probe_state)" "starting" "s6: up (no pid) is starting"
echo down > "$WORK/svc/palworld-server/svstat"
touch "$WORK/svc/palworld-server/down"
assert_eq "$(probe_state)" "stopped" "s6: down with the down marker is stopped/wanted-down"
rm -f "$WORK/svc/palworld-server/down"
echo down > "$WORK/svc/palworld-server/svstat"
assert_eq "$(probe_state)" "crash-backoff" "s6: down without the down marker is crash-backoff (wanted-up)"
touch "$WORK/svc/palworld-server/down"
echo up > "$WORK/svc/palworld-server/svstat"
assert_eq "$(probe_state)" "stopping" "s6: up while marked down is stopping"
mv "$WORK/svc/palworld-server" "$WORK/svc-hidden"
assert_eq "$(probe_state)" "no-supervisor" "s6: missing service directory is no-supervisor"
mv "$WORK/svc-hidden" "$WORK/svc/palworld-server"
echo down > "$WORK/svc/palworld-server/svstat"
echo fail > "$WORK/svc/palworld-server/svstat"
assert_eq "$(probe_state)" "unknown" "s6: a failed state query is unknown, never a guess"
rm -f "$WORK/svc/palworld-server/down"
echo down > "$WORK/svc/palworld-server/svstat"

# --- portable systemd branch (bare metal) --------------------------------------
probe_state_systemd() {
  env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$HOME" \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
    PALWARDEN_SYSTEMCTL_BIN="$WORK/bin/systemctl" \
    PYTHONPATH="$ROOT/lib" \
    python3 -c 'import palwarden_lifecycle as lc; print(lc.service_state())'
}
rm -f "$WORK/unit.disabled"
assert_eq "$(probe_state_systemd)" "crash-backoff" "systemd: inactive + enabled is crash-backoff (unit wants up)"
touch "$WORK/unit.disabled"
assert_eq "$(probe_state_systemd)" "stopped" "systemd: inactive + disabled is stopped/wanted-down"
echo up > "$WORK/svc/palworld-server/svstat"
assert_eq "$(probe_state_systemd)" "running" "systemd: active is running"
echo fail > "$WORK/svc/palworld-server/svstat"
rm -f "$WORK/unit.disabled"
mv "$WORK/bin/systemctl" "$WORK/bin/systemctl.hidden"
assert_eq "$(probe_state_systemd)" "no-supervisor" "systemd: missing systemctl is no-supervisor"
mv "$WORK/bin/systemctl.hidden" "$WORK/bin/systemctl"
echo down > "$WORK/svc/palworld-server/svstat"

# ==============================================================================
# 2. Cooldown file semantics (module-level).
# ==============================================================================
cd "$ROOT" || exit 1
# shellcheck disable=SC2016  # $PALWORLD_KNOCK_COOLDOWN_FILE expands in the inner bash -c
lc_env bash -c 'python3 - "$PALWORLD_KNOCK_COOLDOWN_FILE" <<PY
import time
import palwarden_lifecycle as lc
import sys
p = sys.argv[1]
assert lc.read_cooldown(p) is None, "missing file means no previous wake"
now = int(time.time() * 1000)
lc.write_cooldown(p, now - 30_000)
assert lc.read_cooldown(p) == now - 30_000
st, age = lc.cooldown_status(p, cooldown_s=600)
assert st == "active" and 29_000 <= age <= 61_000, (st, age)
lc.write_cooldown(p, now - 700_000)
assert lc.cooldown_status(p, cooldown_s=600)[0] == "expired"
lc.write_cooldown(p, now + 3_600_000)
assert lc.cooldown_status(p, cooldown_s=600)[0] == "invalid", "future timestamps fail closed"
open(p, "w").write("not-a-number\n")
assert lc.cooldown_status(p, cooldown_s=600)[0] == "invalid", "corrupt data fails closed"
open(p, "w").write("-5\n")
assert lc.cooldown_status(p, cooldown_s=600)[0] == "invalid", "negative timestamps fail closed"
# atomic writer leaves 0640-ish regular file, no temp litter
import os, stat
mode = stat.S_IMODE(os.stat(p).st_mode)
assert mode & 0o007 == 0, oct(mode)
print("COOLDOWN_OK")
PY' > "$WORK/cd.out" 2>&1
assert_contains "$(cat "$WORK/cd.out")" "COOLDOWN_OK" "cooldown: missing/active/expired/corrupt/future semantics (output: $(cat "$WORK/cd.out"))"
rm -f "$WORK/knock.cooldown"

# ==============================================================================
# 3. `palworld-knock wake` — happy path: start-if-down, cooldown BEFORE start,
#    ownership handed to the starter, readiness verified, one notification.
# ==============================================================================
touch "$WORK/svc/palworld-server/down"   # world: stopped (wanted-down)
: > "$WORK/log_fdenv"   # the starter logs the FD env var it inherits
out="$(wake --reason "player request" 2>&1)"; rc=$?
assert_eq "$rc" "0" "wake on a stopped server exits 0 (output: $out)"
assert_contains "$out" "started" "wake reports started"
assert_contains "$out" "ready" "wake reports verified readiness"
starts="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts:-0}" "1" "exactly one start command"
assert_eq "$(grep -c 'FORBIDDEN' "$WORK/systemctl.log" 2>/dev/null || true)" "0" \
  "wake never issues stop or restart"
assert_contains "$(cat "$WORK/systemctl.log")" "LIVE" \
  "the starter inherits a LIVE lifecycle descriptor, not just the env var"
# cooldown written BEFORE start: the systemctl stub would have logged the
# cooldown file's absence if start had run first.
assert_contains "$(cat "$WORK/systemctl.log")" "COOLDOWN_AT_START=yes" \
  "cooldown marker is written atomically before the start"
assert_eq "$(wc -l < "$WORK/knock.cooldown")" "1" "cooldown file holds one timestamp"
assert_contains "$(cat "$WORK/notify.log")" "wake" "one wake notification was sent"
assert_not_contains "$out" "synthetic-token-DO-NOT-LEAK" "wake output never echoes the configured token"

# Already up: no-op, exit 0, explicit status, NO notification.
rm -f "$WORK/notify.log" "$WORK/systemctl.log"
out="$(wake 2>&1)"; rc=$?
assert_eq "$rc" "0" "wake on a running server exits 0"
assert_contains "$out" "already-running" "already-up wake reports an explicit no-op status"
starts0="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts0:-0}" "0" \
  "already-up wake issues no start"
assert_path_absent "$WORK/notify.log" "already-up wake sends no notification"

# Cooldown active: no-op exit 0, explicit status, no start, no notification,
# and the cooldown file is NOT reset.
reset_world
now_ms=$(( $(date +%s) * 1000 - 30000 ))
printf '%s\n' "$now_ms" > "$WORK/knock.cooldown"
before_cd="$(cat "$WORK/knock.cooldown")"
rm -f "$WORK/notify.log"
out="$(wake 2>&1)"; rc=$?
assert_eq "$rc" "0" "wake during cooldown exits 0 as a no-op"
assert_contains "$out" "cooldown" "cooldown wake reports an explicit status"
starts0="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts0:-0}" "0" \
  "cooldown wake issues no start"
assert_eq "$(cat "$WORK/knock.cooldown")" "$before_cd" "cooldown wake does not reset the marker"
assert_path_absent "$WORK/notify.log" "cooldown wake sends no notification"

# Cooldown expired: eligible again.
now_ms=$(( $(date +%s) * 1000 - 700000 ))
printf '%s\n' "$now_ms" > "$WORK/knock.cooldown"
out="$(wake 2>&1)"; rc=$?
assert_eq "$rc" "0" "wake after an expired cooldown succeeds (output: $out)"
assert_contains "$(cat "$WORK/systemctl.log")" "start" "expired cooldown allows the start"

# Corrupt / future cooldown: fail CLOSED with a bounded actionable warning.
reset_world
printf 'garbage\n' > "$WORK/knock.cooldown"
out="$(wake 2>&1)"; rc=$?
assert_ne "$rc" "0" "corrupt cooldown fails closed"
assert_contains "$out" "cooldown" "corrupt cooldown names the cooldown in the warning"
starts0="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts0:-0}" "0" \
  "corrupt cooldown issues no start"
now_ms=$(( $(date +%s) * 1000 + 3600000 ))
printf '%s\n' "$now_ms" > "$WORK/knock.cooldown"
out="$(wake 2>&1)"; rc=$?
assert_ne "$rc" "0" "future cooldown fails closed"
reset_world

# Crash-backoff (down but wanted-up): refuse — the supervisor is still trying.
rm -f "$WORK/svc/palworld-server/down"
out="$(wake 2>&1)"; rc=$?
assert_ne "$rc" "0" "wake refuses during crash-backoff"
assert_contains "$out" "crash" "the refusal names the crash-backoff state"
starts0="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts0:-0}" "0" \
  "crash-backoff wake issues no start"
touch "$WORK/svc/palworld-server/down"

# Stopping: refuse.
touch "$WORK/svc/palworld-server/down"
echo up > "$WORK/svc/palworld-server/svstat"
out="$(wake 2>&1)"; rc=$?
assert_ne "$rc" "0" "wake refuses while the service is stopping"
rm -f "$WORK/svc/palworld-server/down"
echo down > "$WORK/svc/palworld-server/svstat"

# Unknown state: refuse, never start blind.
echo fail > "$WORK/svc/palworld-server/svstat"
out="$(wake 2>&1)"; rc=$?
assert_ne "$rc" "0" "wake refuses when the state query fails"
starts0="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts0:-0}" "0" \
  "unknown-state wake issues no start"
echo down > "$WORK/svc/palworld-server/svstat"
touch "$WORK/svc/palworld-server/down"

# ==============================================================================
# 4. Busy: a held lifecycle lock yields 75 + retry guidance, not a queued start.
# ==============================================================================
PYTHONPATH="$ROOT/lib" python3 - "$WORK/lifecycle.lock" "$WORK/busy.ready" "$WORK/busy.go" <<'PY' &
import os, sys, time
import palwarden_lifecycle as lc
os.environ["PALWARDEN_LIFECYCLE_LOCK"] = sys.argv[1]
fd = lc.acquire(timeout=5, owner_pid=os.getpid(), owner_comm="busy-holder")
open(sys.argv[2], "w").write("ready")
# hold until released by the test
while not os.path.exists(sys.argv[3]):
    time.sleep(0.02)
lc.release(fd)
PY
busy_pid=$!
for _ in $(seq 1 100); do [ -e "$WORK/busy.ready" ] && break; sleep 0.05; done
out="$(wake 2>&1)"; rc=$?
assert_eq "$rc" "75" "a busy lifecycle lock makes wake exit 75"
assert_contains "$out" "retry" "busy wake prints retry guidance"
starts0="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts0:-0}" "0" \
  "busy wake issues no start (nothing is queued)"
touch "$WORK/busy.go"
wait "$busy_pid" 2>/dev/null || true

# ==============================================================================
# 5. Concurrent wakes: exactly one start, the other busy; zero down commands.
# ==============================================================================
reset_world
rm -f "$WORK/systemctl.log" "$WORK/race-a.run" "$WORK/race-b.run"
# The starter stub sleeps 1.0s inside `start`, so the loser's nonblocking
# acquisition definitely overlaps the winner's transaction even on a loaded
# machine (0.3s proved flaky: wake startup could outlive the whole window,
# and the loser then saw already-running instead of busy).
printf '1.0\n' > "$WORK/start.sleep"
: > "$WORK/log_fdenv"
( touch "$WORK/race-a.run"; while [ ! -e "$WORK/race-b.run" ]; do :; done
  wake >"$WORK/race-a.out" 2>&1; echo $? > "$WORK/race-a.rc" ) &
ra=$!
( touch "$WORK/race-b.run"; while [ ! -e "$WORK/race-a.run" ]; do :; done
  wake >"$WORK/race-b.out" 2>&1; echo $? > "$WORK/race-b.rc" ) &
rb=$!
wait "$ra" "$rb" 2>/dev/null || true
rm -f "$WORK/start.sleep" "$WORK/log_fdenv"
rc_a="$(cat "$WORK/race-a.rc")"; rc_b="$(cat "$WORK/race-b.rc")"
zeros=0; seventyfive=0
for rcv in "$rc_a" "$rc_b"; do
  [ "$rcv" = "0" ] && zeros=$((zeros + 1))
  [ "$rcv" = "75" ] && seventyfive=$((seventyfive + 1))
done
assert_eq "$((zeros + seventyfive))" "2" "both concurrent wakes completed with 0 or 75 (got $rc_a/$rc_b)"
assert_eq "$seventyfive" "1" "exactly one concurrent wake found the lock busy"
assert_eq "$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)" "1" \
  "concurrent wakes produced exactly one start"
assert_eq "$(grep -c 'FORBIDDEN' "$WORK/systemctl.log" 2>/dev/null || true)" "0" \
  "the race produced zero down/restart commands"

# ==============================================================================
# 6. Readiness outcomes and notification failure independence.
# ==============================================================================
# REST unconfigured (exit 2): started, readiness NOT verified, exit 0.
reset_world
echo 2 > "$WORK/api.code"
out="$(wake 2>&1)"; rc=$?
assert_eq "$rc" "0" "REST exit 2 still exits 0 (start succeeded)"
assert_contains "$out" "unverified" "REST exit 2 reports readiness unverified, never healthy"
assert_not_contains "$out" "ready" "unverified is not reported as ready/healthy"

# REST persistently failing: nonzero, warns; start itself succeeded.
reset_world
echo 1 > "$WORK/api.code"
WAKE_READY_TIMEOUT_S=0.3 out="$(wake 2>&1)"; rc=$?
assert_ne "$rc" "0" "persistent readiness failure exits nonzero"
assert_contains "$out" "readiness" "the failure names readiness"

# Readiness recovers within the window (poll, not one-shot).
reset_world
rm -f "$WORK/api.calls"
echo 1 > "$WORK/api.code"
echo 2 > "$WORK/api.succeed_on"
WAKE_READY_TIMEOUT_S=3 out="$(wake 2>&1)"; rc=$?
assert_eq "$rc" "0" "readiness polling tolerates transient failures and recovers (output: $out)"
assert_contains "$out" "ready" "recovered polling reports ready"

# Notification helper failing must not break the lifecycle result.
reset_world
touch "$WORK/notify.fail"
out="$(wake 2>&1)"; rc=$?
assert_eq "$rc" "0" "a failing notify helper does not fail the wake (output: $out)"

# A notify helper that is ABSENT (not merely failing) must also be nonfatal.
# The bash grep-based invariant in test_notify_optional.sh guards shell
# scripts; the Python spawn's FileNotFoundError path needs its own proof
# (spec §6.3: "Test Python behavior separately").
reset_world
mv "$WORK/bin/palworld-notify" "$WORK/bin/palworld-notify.hidden"
out="$(wake 2>&1)"; rc=$?
mv "$WORK/bin/palworld-notify.hidden" "$WORK/bin/palworld-notify"
assert_eq "$rc" "0" "an absent notify helper does not fail the wake (output: $out)"

# Explicit wake works with UDP knock disabled (config gate is UDP-only).
reset_world
make_ops false ""
out="$(wake 2>&1)"; rc=$?
assert_eq "$rc" "0" "explicit wake operates with UDP knock disabled (output: $out)"
assert_contains "$(cat "$WORK/systemctl.log")" "start" "disabled-UDP wake still starts the service"
make_ops true "synthetic-token-DO-NOT-LEAK"

# Invalid CLI usage exits 64.
out="$(python3 "$KNOCK" wake --reason 2>&1)"; rc=$?
assert_eq "$rc" "64" "a missing --reason value exits 64"
out="$(env -i PATH="/usr/bin:/bin" python3 "$KNOCK" bogus 2>&1)"; rc=$?
assert_eq "$rc" "64" "an unknown verb exits 64"
out="$(wake --reason "$(printf 'x%.0s' $(seq 1 300))" 2>&1)"; rc=$?
assert_eq "$rc" "64" "an over-long reason is rejected as usage"

# ==============================================================================
# 7. Task 6: UDP listener daemon with bounded leases (spec §4.2, §6.1).
#    Fixture port 18211 via --port (production internal listener stays 8211).
# ==============================================================================
KPORT=18211
DAEMON=""
daemon_log() { cat "$WORK/daemon.log" 2>/dev/null || true; }
starts_count() { local c; c="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"; echo "${c:-0}"; }
knock_daemon() { # start the daemon; records its PID in $DAEMON
  env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$HOME" \
    PALWARDEN_CONTAINER=1 \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/state" \
    PALWARDEN_S6_SVC_DIR="$WORK/svc" \
    PALWARDEN_OPS_FILE="$WORK/ops.env" \
    PALWORLD_KNOCK_COOLDOWN_FILE="$WORK/knock.cooldown" \
    PALWORLD_API_BIN="$WORK/bin/palworld-api" \
    PALWARDEN_NOTIFY_HELPER="$WORK/bin/palworld-notify" \
    PALWARDEN_WAKE_READY_TIMEOUT_S="${WAKE_READY_TIMEOUT_S:-2}" \
    PALWARDEN_WAKE_POLL_INTERVAL_S=0.05 \
    PALWARDEN_KNOCK_LEASE_S="${PALWARDEN_KNOCK_LEASE_S:-1}" \
    PALWARDEN_KNOCK_IDLE_S="${PALWARDEN_KNOCK_IDLE_S:-0.15}" \
    python3 "$KNOCK" daemon --port "$KPORT" >"$WORK/daemon.log" 2>&1 &
  DAEMON=$!
}
stop_daemon() { # fixture-owned child only
  [ -n "$DAEMON" ] || return 0
  kill -TERM "$DAEMON" 2>/dev/null || true
  wait "$DAEMON" 2>/dev/null || true
  DAEMON=""
}
trap 'stop_daemon; rm -rf "$WORK"' EXIT
port_bound() {
  # Kernel UDP table, not a live probe: a probe packet would be consumed by
  # the listener as a (token-invalid) knock and perturb the lease under test.
  if ss -lun 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$KPORT\$"; then
    echo bound
  else
    echo free
  fi
}
wait_port() { # wait_port bound|free [deadline_s]
  local want="$1" lim="${2:-6}" t0
  t0=$(date +%s%N)
  while [ "$(port_bound)" != "$want" ]; do
    if [ $(( ($(date +%s%N) - t0) / 1000000 )) -ge $(( lim * 1000 )) ]; then return 1; fi
    sleep 0.05
  done
  return 0
}
send_knock() { # send_knock <bytes-literal>
  python3 - "$KPORT" "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(eval(sys.argv[2]), ("127.0.0.1", int(sys.argv[1])))
s.close()
PY
}
acquire_probe() { # bounded controller acquisition; prints ACQUIRED <ms> / BUSY
  env -i PATH="/usr/bin:/bin" HOME="$HOME" \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
    PYTHONPATH="$ROOT/lib" \
    python3 -c 'import os, sys, time
import palwarden_lifecycle as lc
t0 = time.monotonic()
try:
    fd = lc.acquire(timeout=float(sys.argv[1]))
except lc.LifecycleError:
    print("BUSY"); sys.exit(0)
lc.release(fd)
print("ACQUIRED %d" % int((time.monotonic() - t0) * 1000))' "$1"
}

reset_world
make_ops true "synthetic-token-DO-NOT-LEAK"
rm -f "$WORK/daemon.log"
knock_daemon

# --- arm / disarm on service state --------------------------------------------
if wait_port bound 6; then pass "daemon binds the test port while the service is stopped/wanted-down"; else fail "daemon never bound the port (log: $(daemon_log))"; fi
echo up > "$WORK/svc/palworld-server/svstat"
rm -f "$WORK/svc/palworld-server/down"
if wait_port free 6; then pass "a running service disarms the listener at the next lease boundary"; else fail "listener stayed bound while the service was running"; fi
echo down > "$WORK/svc/palworld-server/svstat"
touch "$WORK/svc/palworld-server/down"
if wait_port bound 6; then pass "the listener re-arms once the service is stopped again"; else fail "listener did not re-arm (log: $(daemon_log))"; fi

# --- crash-backoff must not arm ------------------------------------------------
rm -f "$WORK/svc/palworld-server/down"   # down but wanted-up
if wait_port free 6; then pass "crash-backoff (wanted-up) never arms the listener"; else fail "listener armed during crash-backoff"; fi
touch "$WORK/svc/palworld-server/down"
wait_port bound 6 >/dev/null || fail "listener did not re-arm after restoring wanted-down"

# --- starting must not arm -------------------------------------------------------
echo starting > "$WORK/svc/palworld-server/svstat"
if wait_port free 6; then pass "starting never arms the listener"; else fail "listener armed while the service is starting"; fi
echo down > "$WORK/svc/palworld-server/svstat"
wait_port bound 6 >/dev/null || fail "listener did not re-arm after starting -> stopped"

# --- lock busy: another controller owning the lock keeps the listener closed -----
# (the daemon may only bind under its own ownership; contention is bounded retry)
PYTHONPATH="$ROOT/lib" python3 - "$WORK/lifecycle.lock" "$WORK/busy2.ready" "$WORK/busy2.go" <<'PY' &
import os, sys, time
import palwarden_lifecycle as lc
os.environ["PALWARDEN_LIFECYCLE_LOCK"] = sys.argv[1]
fd = lc.acquire(timeout=5, owner_pid=os.getpid(), owner_comm="busy-holder")
open(sys.argv[2], "w").write("ready")
while not os.path.exists(sys.argv[3]):
    time.sleep(0.02)
lc.release(fd)
PY
busy2_pid=$!
for _ in $(seq 1 100); do [ -e "$WORK/busy2.ready" ] && break; sleep 0.05; done
sleep 2.0   # spans several daemon lease attempts
assert_eq "$(port_bound)" "free" "the listener stays closed while another controller owns the lifecycle lock"
touch "$WORK/busy2.go"
wait "$busy2_pid" 2>/dev/null || true
if wait_port bound 6; then pass "the listener re-arms once the lock holder releases"; else fail "listener did not re-arm after the holder released (log: $(daemon_log))"; fi

# --- lease order: close socket -> release lock; controller not starved ---------
# Once the controller wins the lock, the port MUST already be closed (the
# daemon closes its socket BEFORE releasing, so a supported manual start can
# bind the game socket under its own ownership).
ctrl="$(acquire_probe 5)"
assert_contains "$ctrl" "ACQUIRED" "a controller acquires the lifecycle lock within 5s while the daemon cycles leases (got: $ctrl)"
assert_eq "$(port_bound)" "free" \
  "the daemon closes its socket BEFORE releasing the lock (controller bound the game socket under its own ownership)"

# Sustained wrong-token traffic must not starve controllers across lease
# reacquisition.
python3 - "$KPORT" 1.5 <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
end = time.monotonic() + float(sys.argv[2])
while time.monotonic() < end:
    s.sendto(b"wrong-token-under-traffic", ("127.0.0.1", int(sys.argv[1])))
    time.sleep(0.02)
s.close()
PY
flood_pid=$!
ctrl="$(acquire_probe 5)"
flood_ms="${ctrl#ACQUIRED }"
assert_contains "$ctrl" "ACQUIRED" "controller acquires within 5s under sustained knock traffic (got: $ctrl)"
if [ "$ctrl" != "BUSY" ] && [ "$flood_ms" -ge 0 ] && [ "$flood_ms" -lt 5000 ]; then pass "measured lease handoff under traffic: ${flood_ms}ms (<5000)"; else fail "lease handoff under traffic too slow or refused: $ctrl"; fi
wait "$flood_pid" 2>/dev/null || true

# --- token mode: exact match wakes; everything else is rejected ----------------
# Retry like a real client: the lease gap (port closed ~0.15s between leases)
# can drop a single datagram by design.
ok=0
for _ in $(seq 1 40); do
  send_knock 'b"synthetic-token-DO-NOT-LEAK"'
  grep -q '^start ' "$WORK/systemctl.log" 2>/dev/null && { ok=1; break; }
  sleep 0.1
done
assert_eq "$ok" "1" "the exact token wakes the stopped server (log: $(daemon_log))"
ok=0
for _ in $(seq 1 60); do [ -e "$WORK/knock.cooldown" ] && { ok=1; break; }; sleep 0.05; done
assert_eq "$ok" "1" "the UDP wake wrote the cooldown marker"
# "wake started" is logged only after start_if_down COMPLETES (readiness
# included) — poll with a deadline; a single-shot grep races the daemon.
ok=0
for _ in $(seq 1 60); do daemon_log | grep -q 'wake started' && { ok=1; break; }; sleep 0.05; done
assert_eq "$ok" "1" "the daemon logs the wake (log: $(daemon_log))"
assert_file_not_contains "$WORK/systemctl.log" "FORBIDDEN" "the UDP wake never issues stop/restart"
assert_file_not_contains "$WORK/daemon.log" "synthetic-token-DO-NOT-LEAK" "the daemon log never echoes the token"
assert_file_not_contains "$WORK/daemon.log" "127.0.0.1" "the daemon log never publishes source addresses"

# Cooldown gates the next packet: re-stop the service (so the listener
# re-arms) but LEAVE the cooldown marker in place, then knock again.
rm -f "$WORK/systemctl.log"
echo down > "$WORK/svc/palworld-server/svstat"
touch "$WORK/svc/palworld-server/down"
wait_port bound 6 >/dev/null || fail "listener did not re-arm for the cooldown test"
send_knock 'b"synthetic-token-DO-NOT-LEAK"'
sleep 1.2
assert_eq "$(starts_count)" "0" "a second packet inside cooldown starts nothing"

# Wrong / empty / oversized / token+suffix / invalid-UTF-8: all rejected.
reset_world
rm -f "$WORK/systemctl.log"
send_knock 'b"wrong-token"'
send_knock 'b""'
send_knock 'b"x" * 513'
send_knock 'b"synthetic-token-DO-NOT-LEAK-suffix"'
send_knock 'b"\xff\xfe" + b"synthetic-token-DO-NOT-LEAK"'
sleep 1.5
assert_eq "$(starts_count)" "0" "wrong/empty/oversized/token+suffix/invalid-UTF-8 packets never start the service"
assert_contains "$(daemon_log)" "invalid" "invalid packets are counted in a bounded local log"
inv="$(grep -c 'invalid' "$WORK/daemon.log" 2>/dev/null || true)"; inv="${inv:-0}"
if [ "$inv" -le 2 ]; then pass "invalid-packet logging is aggregated ($inv lines for 5 rejects)"; else fail "invalid-packet logging is not bounded: $inv lines"; fi

# A 512-byte token plus suffix must never truncate into an accepted token.
reset_world
rm -f "$WORK/systemctl.log"
send_knock 'b"T" * 512 + b"X"'
sleep 1.2
assert_eq "$(starts_count)" "0" "a 512-byte token plus suffix is rejected, not truncated into a match"

# --- open-doorbell mode: any nonempty datagram, even beyond the buffer ---------
reset_world
make_ops true ""
# The daemon reloads config at each lease START: wait one lease boundary so
# the armed lease holds the NEW (empty) token before we ring.
sleep 1.5
wait_port bound 6 >/dev/null || fail "listener not armed for the doorbell test"
rm -f "$WORK/systemctl.log"
# The lease design intentionally closes the port between leases (0.15s), so
# a single datagram can be lost by design — a real client retries until the
# wake lands. Ring repeatedly (bounded) and assert a wake happened WITHOUT
# the payload ever being parsed.
ok=0
for _ in $(seq 1 40); do
  send_knock 'b"x" * 2000'
  grep -q '^start ' "$WORK/systemctl.log" 2>/dev/null && { ok=1; break; }
  sleep 0.1
done
assert_eq "$ok" "1" "open-doorbell mode wakes on an oversized datagram without parsing its payload"
reset_world
rm -f "$WORK/systemctl.log"
send_knock 'b""'
sleep 1.2
assert_eq "$(starts_count)" "0" "even doorbell mode ignores an empty datagram"

# --- live config reload: disable closes, enable re-arms, token edits apply -----
reset_world
make_ops true "synthetic-token-DO-NOT-LEAK"
wait_port bound 6 >/dev/null || fail "listener not armed before the disable test"
make_ops false "synthetic-token-DO-NOT-LEAK"
if wait_port free 3; then pass "disabling knock closes the socket by the next lease boundary (no restart)"; else fail "disable did not close the socket (log: $(daemon_log))"; fi
make_ops true "synthetic-token-DO-NOT-LEAK"
if wait_port bound 6; then pass "re-enabling knock re-arms when safe"; else fail "re-enable did not re-arm (log: $(daemon_log))"; fi
make_ops true "second-synthetic-token"
sleep 1.5
rm -f "$WORK/systemctl.log"
send_knock 'b"synthetic-token-DO-NOT-LEAK"'
sleep 1.2
assert_eq "$(starts_count)" "0" "the old token stops matching after a live token edit"
# Baseline for the wake-completion wait in the EADDRINUSE section below. No
# wake has polled at this point, so api.log may not exist and the `|| echo 0`
# fallback is the intended baseline. (The `2>/dev/null` must come BEFORE the
# `<`: bash opens the input file before running wc, so a trailing redirect
# cannot silence the open error.)
api_before="$(wc -l 2>/dev/null < "$WORK/api.log" || echo 0)"
send_knock 'b"second-synthetic-token"'
ok=0
for _ in $(seq 1 100); do grep -q '^start ' "$WORK/systemctl.log" 2>/dev/null && { ok=1; break; }; sleep 0.05; done
assert_eq "$ok" "1" "the new token wakes without restarting the daemon"

# --- EADDRINUSE: bounded warning, daemon survives, rebinds when free -----------
# The wake the token-edit knock just triggered is NOT finished when its
# `start` lands in systemctl.log: _lease then runs the readiness poll INLINE,
# and the stub's start is what sets the fake service state to `up`. If the
# reset_world below ran while that wake was still in flight, the stub's `up`
# would land AFTER reset_world's `down` + down-marker — a permanent
# `stopping` the listener correctly refuses to arm through, and no wait
# deadline could rescue it (this was the load-dependent flake). The readiness
# poll appends to api.log AFTER the stub's start has landed, so one NEW
# api.log line past the baseline captured right before the knock is the
# wake-completion signal. (The baseline was taken before the knock above;
# reset_world has not run since, so api.log still holds the earlier wakes.)
ok=0
for _ in $(seq 1 200); do
  api_now="$(wc -l 2>/dev/null < "$WORK/api.log" || echo 0)"
  [ "$api_now" -gt "$api_before" ] && { ok=1; break; }
  sleep 0.05
done
assert_eq "$ok" "1" "the token-edit wake completed its readiness poll before the EADDRINUSE reset"
reset_world
make_ops true "synthetic-token-DO-NOT-LEAK"
# 15s: generous headroom for the daemon's next lease after a completed wake.
wait_port bound 15 >/dev/null || fail "listener not armed before the EADDRINUSE test"
# Holder: takes the lifecycle lock (so the daemon cannot be holding or
# binding), binds the game port, holds both briefly, then releases the lock
# (daemon's next lease now hits EADDRINUSE) and finally frees the port.
PYTHONPATH="$ROOT/lib" PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
python3 - "$WORK/eaiu.ready" "$KPORT" <<'PY' &
import os, socket, sys, time
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=5)
open(sys.argv[1], "w").write("ready")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
deadline = time.monotonic() + 6      # the daemon may hold the port for <=1s
while time.monotonic() < deadline:
    try:
        s.bind(("0.0.0.0", int(sys.argv[2])))
        break
    except OSError:
        time.sleep(0.05)
time.sleep(3.0)          # port held while the daemon is locked out
lc.release(fd)           # daemon re-arms now, but the port is still taken
time.sleep(3.0)
s.close()
PY
eaiu_pid=$!
for _ in $(seq 1 100); do [ -e "$WORK/eaiu.ready" ] && break; sleep 0.05; done
sleep 7
daemon_alive=0; kill -0 "$DAEMON" 2>/dev/null && daemon_alive=1
assert_eq "$daemon_alive" "1" "the daemon survives EADDRINUSE with bounded retry, not a wake or a crash"
eaiu="$(grep -ci 'eaddrinuse\|address already in use' "$WORK/daemon.log" 2>/dev/null || true)"; eaiu="${eaiu:-0}"
if [ "$eaiu" -le 3 ]; then pass "EADDRINUSE logging is bounded ($eaiu lines over ~3s of contention)"; else fail "EADDRINUSE logging is not bounded: $eaiu lines"; fi
wait "$eaiu_pid" 2>/dev/null || true
# 15s for the same inline-wake reason as the pre-test wait above.
if wait_port bound 15; then pass "the listener rebinds once the port is free again"; else fail "listener never rebound after EADDRINUSE (log: $(daemon_log))"; fi

# --- flood across lease boundaries: bounded logs, no leaks, progress -----------
reset_world
rm -f "$WORK/systemctl.log" "$WORK/daemon.log"
: > "$WORK/daemon.log"
python3 - "$KPORT" 1.5 <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
end = time.monotonic() + float(sys.argv[2])
while time.monotonic() < end:
    s.sendto(b"synthetic-wrong-token-flood", ("127.0.0.1", int(sys.argv[1])))
    time.sleep(0.002)
s.close()
PY
flood_pid=$!
wait "$flood_pid" 2>/dev/null || true
sleep 1.2
daemon_alive=0; kill -0 "$DAEMON" 2>/dev/null && daemon_alive=1
assert_eq "$daemon_alive" "1" "the daemon survives a wrong-token flood across lease boundaries"
assert_eq "$(starts_count)" "0" "the flood starts nothing"
ctrl="$(acquire_probe 5)"
assert_contains "$ctrl" "ACQUIRED" "competing maintenance still acquires the lock within 5s after a flood (got: $ctrl)"
flog="$(daemon_log)"
assert_not_contains "$flog" "synthetic-wrong-token-flood" "flood payloads are never logged"
assert_not_contains "$flog" "127.0.0.1" "flood source addresses are never logged"
inv="$(grep -c 'invalid' "$WORK/daemon.log" 2>/dev/null || true)"; inv="${inv:-0}"
if [ "$inv" -le 2 ]; then pass "flood invalid-reporting stays aggregated ($inv lines)"; else fail "flood invalid-reporting is not bounded: $inv lines"; fi

# --- daemon termination: exits promptly, frees port and lock --------------------
reset_world
kill -TERM "$DAEMON" 2>/dev/null || true
rc_d=0; wait "$DAEMON" 2>/dev/null || rc_d=$?
DAEMON=""
assert_eq "$rc_d" "0" "SIGTERM exits the daemon cleanly (rc=$rc_d)"
assert_eq "$(port_bound)" "free" "termination releases the UDP port"
ctrl="$(acquire_probe 3)"
assert_contains "$ctrl" "ACQUIRED" "termination releases the lifecycle lock"

# ==============================================================================
# 8. The wake fence (spec §4.4, plan Task 8): a wake admitted by the API carries
#    the idle generation and a server-minted expiry; wake re-checks BOTH after
#    acquiring ownership and before start_if_down touches anything.
# ==============================================================================
reset_world
lc_env python3 -c 'import palwarden_lifecycle as lc; lc.ensure_state()'
FGEN="$(lc_env python3 -c 'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
FNOW="$(date +%s)"

# Unfenced wake (UDP knock / manual `wake` carry no fence) must STILL honour
# the unsafe marker: spec §4.4 inhibits automatic wake until the operator
# acknowledges. This is the hole Task 11's Docker acceptance found.
lc_env python3 -c 'import palwarden_lifecycle as lc; lc.write_state("unsafe", operation="update", rotate=True)'
out="$(wake --reason itest-unsafe 2>&1)"; rc=$?
assert_eq "$rc" "65" "unfenced wake against an unsafe marker is refused (65)"
assert_contains "$out" "not idle" "the refusal names the non-idle status"
assert_eq "$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || echo 0)" "0" \
  "unsafe refusal never touches the starter"
lc_env python3 -c 'import palwarden_lifecycle as lc; lc.write_state("idle", rotate=True, force=True)'
# Async-spawn race (Task 11): the starter returns BEFORE the supervisor
# reports running; wake must poll briefly, not sample once and cry failure.
echo 0.6 > "$WORK/start.delay"
out="$(wake --reason itest-spawnrace 2>&1)"; rc=$?
assert_eq "$rc" "0" "wake tolerates a delayed supervisor flip (output: $out)"
assert_contains "$out" "started" "delayed spawn still reports started, not error"
reset_world   # the spawn-race wake left the service up; the fenced tests need a stopped world
FGEN="$(lc_env python3 -c 'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"  # rotations above moved it
out="$(wake --fence-generation "$FGEN" --fence-expires-at "$((FNOW + 60))" 2>&1)"; rc=$?
assert_eq "$rc" "0" "a fenced wake matching the idle generation starts (output: $out)"
assert_eq "$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)" "1" \
  "the fenced wake issued exactly one start"

# Expired: refused before start_if_down — even an already-running world is not
# reported, because the request itself is stale.
rm -f "$WORK/systemctl.log"
out="$(wake --fence-generation "$FGEN" --fence-expires-at "$((FNOW - 1))" 2>&1)"; rc=$?
assert_eq "$rc" "65" "an expired fenced wake is refused (65)"
assert_contains "$out" "expired" "the refusal says expired"
starts0="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts0:-0}" "0" "an expired wake issues no start"

# Generation rotated (maintenance ran, or the runtime restarted): refused.
lc_env python3 -c 'import palwarden_lifecycle as lc; lc.write_state("idle", rotate=True, force=True)'
reset_world
out="$(wake --fence-generation "$FGEN" --fence-expires-at "$((FNOW + 60))" 2>&1)"; rc=$?
assert_eq "$rc" "65" "a wake for a rotated generation is refused (65)"
assert_contains "$out" "generation" "the refusal names the generation"
starts0="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts0:-0}" "0" "a rotated-generation wake issues no start"

# Active maintenance: refused even with the CURRENT generation.
lc_env python3 -c 'import palwarden_lifecycle as lc; lc.write_state("active", "update", rotate=True, force=True)'
FGEN2="$(lc_env python3 -c 'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
reset_world
out="$(wake --fence-generation "$FGEN2" --fence-expires-at "$((FNOW + 60))" 2>&1)"; rc=$?
assert_eq "$rc" "65" "a wake during active maintenance is refused (65)"
assert_contains "$out" "active" "the refusal names the active status"
starts0="$(grep -c '^start ' "$WORK/systemctl.log" 2>/dev/null || true)"
assert_eq "${starts0:-0}" "0" "an active-maintenance wake issues no start"

# Missing state reads unknown: fail closed. Unsafe too.
rm -rf "$WORK/state"
out="$(wake --fence-generation "$FGEN2" --fence-expires-at "$((FNOW + 60))" 2>&1)"; rc=$?
assert_eq "$rc" "65" "a wake with no state file fails closed (65)"
lc_env python3 -c 'import palwarden_lifecycle as lc; lc.ensure_state(); lc.write_state("unsafe", "restore")'
FGEN3="$(lc_env python3 -c 'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
out="$(wake --fence-generation "$FGEN3" --fence-expires-at "$((FNOW + 60))" 2>&1)"; rc=$?
assert_eq "$rc" "65" "a wake against an unsafe marker is refused (65)"

# Flag hygiene: all-or-nothing, and the generation must be well-formed.
out="$(wake --fence-generation "$FGEN2" 2>&1)"; rc=$?
assert_eq "$rc" "64" "a fence generation without an expiry is a usage error (64)"
out="$(wake --fence-expires-at "$((FNOW + 60))" 2>&1)"; rc=$?
assert_eq "$rc" "64" "a fence expiry without a generation is a usage error (64)"
out="$(wake --fence-generation "nothex" --fence-expires-at "$((FNOW + 60))" 2>&1)"; rc=$?
assert_eq "$rc" "64" "a malformed fence generation is a usage error (64)"
out="$(wake --fence-generation "$FGEN2" --fence-expires-at "soon" 2>&1)"; rc=$?
assert_eq "$rc" "64" "a non-integer fence expiry is a usage error (64)"

# The fence never replaces ownership: with the lock held elsewhere, wake is
# busy (75) before any fence evaluation — unchanged behaviour.
( lc_env python3 -c '
import palwarden_lifecycle as lc, time
fd = lc.acquire(timeout=5)
time.sleep(2)
lc.release(fd)' & sleep 0.3
  out="$(wake --fence-generation "$FGEN2" --fence-expires-at "$((FNOW + 60))" 2>&1)"; rc=$?
  wait
  exit $rc
) ; rc=$?
assert_eq "$rc" "75" "a fenced wake still refuses to wait behind maintenance (75)"

# ==============================================================================
# 8. F10 (review follow-up): arming and cooldown logs are bounded.
#    Extended quiet stopped operation must not log an arming line per lease,
#    and repeated accepted-but-ineligible (cooldown) knocks must aggregate.
# ==============================================================================
stop_daemon
reset_world
make_ops true "synthetic-token-DO-NOT-LEAK"
rm -f "$WORK/daemon.log" "$WORK/systemctl.log"
PALWARDEN_KNOCK_LEASE_S=0.4 PALWARDEN_KNOCK_IDLE_S=0.1 knock_daemon
sleep 3   # ~6 short leases with zero traffic
armed_lines="$(grep -c 'listener armed' "$WORK/daemon.log" || true)"
if [ "${armed_lines:-0}" -le 1 ]; then
  pass "quiet stopped operation logs at most one arming line (got ${armed_lines})"
else
  fail "arming logged once per lease: ${armed_lines} lines in 3s (log: $(daemon_log))"
fi

# Repeated valid knocks during cooldown: accepted, no-op, bounded logs, no
# starts, and nothing secret in the log.
lc_env python3 -c 'import palwarden_lifecycle as lc; lc.write_cooldown()' >/dev/null
for _ in 1 2 3 4; do
  send_knock 'b"synthetic-token-DO-NOT-LEAK"'
  sleep 0.5
done
sleep 1
cooldown_lines="$(grep -c 'cooldown' "$WORK/daemon.log" || true)"
if [ "${cooldown_lines:-0}" -le 2 ]; then
  pass "repeated cooldown knocks produce bounded/aggregated logs (got ${cooldown_lines})"
else
  fail "every cooldown knock logged its own line: ${cooldown_lines} (log: $(daemon_log))"
fi
assert_eq "$(starts_count)" "0" "cooldown knocks never start the service"
if grep -q 'synthetic-token' "$WORK/daemon.log"; then
  fail "the knock token leaked into the daemon log"
else
  pass "tokens stay out of the daemon log during the cooldown storm"
fi
probe="$(acquire_probe 5)"
assert_contains "$probe" "ACQUIRED" "manual controllers are not starved by the daemon"
stop_daemon

assert_report
