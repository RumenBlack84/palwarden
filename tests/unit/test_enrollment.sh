#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Task 3 (idle-shutdown/knock-wake): lifecycle-lock enrollment of the bash
# controllers (palworld-graceful-stop, palworld-graceful-restart) and of the
# docker systemctl shim.
#
# Spec:  docs/superpowers/specs/2026-10-18-idle-shutdown-knock-wake.md  §4.1
# Plan:  docs/superpowers/plans/2026-10-18-idle-shutdown-knock-wake.md (Task 3)
#
# Proven with real processes and real flock — never a mocked lock:
#   1. An enrolled controller holds the lifecycle lock for its whole mutation
#      window: while it is blocked inside the stubbed s6-svc call, a fresh
#      acquirer gets "busy" (75); after the controller exits, the same probe
#      succeeds. (Also proves dev-checkout resolution: with no
#      PALWARDEN_LIB_DIR set, the scripts must find lib/ next to sbin/ —
#      before this task's fix they silently found nothing and ran unlocked.)
#   2. A forged PALWARDEN_LIFECYCLE_LOCK_FD does not impersonate a borrowed
#      lock: the controller refuses loudly instead of running unlocked.
#   3. The shim's mutating verbs serialize with other transactions; its
#      read-only verbs never take the lock.
#   4. --help never acquires, even when the lock's parent directory cannot
#      exist (an acquire there would fail).
#   5. A missing lock parent fails loudly; enrollment never degrades
#      silently to unlocked.
#   6. With the helper genuinely not installed (empty PALWARDEN_LIB_DIR),
#      the controller behaves exactly as before the feature.
#
# Coordination uses ready/go files with deadlines — no guessed sleeps.
# Per-case knobs are PLAIN variables read inside the runners: env prefixes on
# *function* calls persist across later calls in bash and leak between tests.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
REPO="$DIR/../.."
LIB="$REPO/lib"
STOP="$REPO/sbin/palworld-graceful-stop"
RESTART="$REPO/sbin/palworld-graceful-restart"
SHIM="$REPO/docker/shims/systemctl"

WORK="$(mktemp -d)"
export PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/lifecycle-state"
trap 'rm -rf "$WORK"' EXIT
LOCK="$WORK/lifecycle.lock"

# --- stubs -------------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/svc"
# s6-svc: logs its argv, and blocks between READY and GO whenever -d is in the
# argv AND a GO file was configured for this call. Without GO configured the
# stub never blocks — a forgotten knob must fail an assertion, not the suite.
cat > "$WORK/bin/s6-svc" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$S6_LOG"
for a in "$@"; do
  if [ "$a" = "-d" ] && [ -n "${S6_GO:-}" ]; then
    : > "${S6_DOWN_READY:?s6-svc stub blocking without a READY path}"
    until [ -e "$S6_GO" ]; do sleep 0.05; done
  fi
done
exit 0
EOF
cat > "$WORK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$WORK/bin/palworld-api" <<'EOF'
#!/usr/bin/env bash
exit "${STUB_API_RC:-2}"   # 2 = REST not configured (restart's early-exit path)
EOF
chmod +x "$WORK/bin"/*
: > "$WORK/s6.log"

# --- helpers -------------------------------------------------------------------
# probe_free: try to acquire with timeout 0. rc 0 = lock free, 75 = busy.
probe_free() {
  env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_LOCK="$LOCK" python3 - <<'PY'
import palwarden_lifecycle as lc
try:
    fd = lc.acquire(timeout=0)
except lc.LifecycleError:
    raise SystemExit(75)
lc.release(fd)
PY
}

# hold_lock READY GO: external transaction holder until GO appears.
hold_lock() {
  env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_LOCK="$LOCK" \
    python3 - "$1" "$2" <<'PY'
import pathlib
import sys
import time

import palwarden_lifecycle as lc

fd = lc.acquire(timeout=10)
pathlib.Path(sys.argv[1]).touch()
go = pathlib.Path(sys.argv[2])
end = time.time() + 60
while not go.exists() and time.time() < end:
    time.sleep(0.05)
lc.release(fd)
PY
}

wait_for() {  # wait_for <path> [deadline_secs]
  local f="$1" deadline=$(( SECONDS + ${2:-10} ))
  while [ ! -e "$f" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

# Per-case knobs (plain variables; reset_knobs after each case that sets them).
R="" G="" CUR_LOCK="$LOCK" CUR_LIBDIR=""
# Short lifecycle timeout everywhere: a busy lock must surface as a fast 75,
# not a 600-second wait on the production default.
run_stop() {
  PALWARDEN_CONTAINER=1 PATH="$WORK/bin:$PATH" S6_LOG="$WORK/s6.log" \
  S6_DOWN_READY="$R" S6_GO="$G" \
  PALWARDEN_LIB_DIR="$CUR_LIBDIR" \
  PALWARDEN_LIFECYCLE_LOCK="$CUR_LOCK" PALWARDEN_LIFECYCLE_TIMEOUT=1 \
    bash "$STOP" "$@"
}
run_restart() {
  PALWARDEN_CONTAINER=1 PATH="$WORK/bin:$PATH" S6_LOG="$WORK/s6.log" \
  S6_DOWN_READY="$R" S6_GO="$G" \
  PALWARDEN_LIFECYCLE_LOCK="$CUR_LOCK" PALWARDEN_LIFECYCLE_TIMEOUT=1 \
  PALWORLD_API_BIN="$WORK/bin/palworld-api" \
    bash "$RESTART" "$@"
}
run_shim() {
  PATH="$WORK/bin:$PATH" S6_LOG="$WORK/s6.log" \
  PALWARDEN_S6_SVC_DIR="$WORK/svc" \
  PALWARDEN_LIFECYCLE_LOCK="$CUR_LOCK" PALWARDEN_LIFECYCLE_TIMEOUT=1 \
    bash "$SHIM" "$@"
}
reset_knobs() { R="" G="" CUR_LOCK="$LOCK" CUR_LIBDIR=""; }

# ===========================================================================
# 1. graceful-stop holds the lock across its stop window
# ===========================================================================
R="$WORK/r1" G="$WORK/g1"
run_stop "$@" >"$WORK/o1" 2>&1 &
stop_pid=$!
if ! wait_for "$WORK/r1"; then fail "graceful-stop never reached s6-svc -d"; fi
assert_rc 75 probe_free "concurrent acquire is busy while graceful-stop holds the lock"
: > "$WORK/g1"
wait "$stop_pid"; rc=$?
assert_eq "$rc" 0 "graceful-stop completed"
assert_rc 0 probe_free "lock is free again after graceful-stop exits"
reset_knobs

# ===========================================================================
# 2. graceful-restart holds the lock across its stop/start window
#    (api stub exits 2 -> REST-not-configured early exit, rc = apply_rc = 0)
# ===========================================================================
R="$WORK/r2" G="$WORK/g2"
run_restart "$@" >"$WORK/o2" 2>&1 &
rst_pid=$!
if ! wait_for "$WORK/r2"; then fail "graceful-restart never reached s6-svc -d"; fi
assert_rc 75 probe_free "concurrent acquire is busy while graceful-restart holds the lock"
: > "$WORK/g2"
wait "$rst_pid"; rc=$?
assert_eq "$rc" 0 "graceful-restart completed (REST-unconfigured path)"
assert_rc 0 probe_free "lock is free again after graceful-restart exits"
reset_knobs

# ===========================================================================
# 3. a forged FD_ENV does not impersonate a borrowed lock
#    (env on `env`, not a function prefix: cannot leak into later cases)
# ===========================================================================
: > "$WORK/s6.log"   # fresh log: "never mutated" must mean since THIS run
out="$(env PALWARDEN_LIFECYCLE_LOCK_FD=9 \
       PALWARDEN_CONTAINER=1 PATH="$WORK/bin:$PATH" S6_LOG="$WORK/s6.log" \
       PALWARDEN_LIFECYCLE_LOCK="$LOCK" PALWARDEN_LIFECYCLE_TIMEOUT=1 \
       bash "$STOP" 2>&1)"; rc=$?
assert_ne "$rc" 0 "forged FD_ENV does not let the controller run"
assert_contains "$out" "does not name a live lock descriptor" \
  "forged FD_ENV failure is named, not swallowed"
assert_file_not_contains "$WORK/s6.log" "-d" \
  "forged FD_ENV aborted before any service mutation"

# ===========================================================================
# 4. shim: mutating verbs serialize; read-only verbs never take the lock
# ===========================================================================
hold_lock "$WORK/r3" "$WORK/g3" &
holder_pid=$!
if ! wait_for "$WORK/r3"; then fail "external holder never took the lock"; fi
out="$(run_shim start palworld.service 2>&1)"; rc=$?
assert_eq "$rc" 75 "shim start is refused while another transaction holds the lock"
assert_contains "$out" "palwarden_lifecycle" "shim start refusal is named"
run_shim is-active palworld.service >/dev/null 2>&1; rc=$?
assert_ne "$rc" 75 "read-only is-active never takes the lock"
: > "$WORK/g3"
wait "$holder_pid"
# And with the lock free, the mutating verb proceeds (acquires, runs s6-svc).
out="$(run_shim start palworld.service 2>&1)"; rc=$?
assert_eq "$rc" 0 "shim start succeeds once the lock is free"
assert_file_contains "$WORK/s6.log" "-u" "shim start reached s6-svc after acquiring"

# ===========================================================================
# 5. --help never acquires (lock parent deliberately missing)
# ===========================================================================
out="$(env PALWARDEN_LIFECYCLE_LOCK="$WORK/nodir/lifecycle.lock" \
      bash "$RESTART" --help 2>&1)"; rc=$?
if [ "$rc" != 0 ] && [ "$rc" != 64 ]; then
  fail "--help should print-and-exit (0 or 64), got rc=$rc: $out"
else
  pass "--help exits without acquiring"
fi
assert_path_absent "$WORK/nodir/lifecycle.lock" "--help created no lock file"

# ===========================================================================
# 6. missing lock parent fails loudly (never silently unlocked)
# ===========================================================================
: > "$WORK/s6.log"
CUR_LOCK="$WORK/nodir/lifecycle.lock"
out="$(run_stop "$@" 2>&1)"; rc=$?
reset_knobs
assert_ne "$rc" 0 "missing lock parent aborts the controller"
assert_contains "$out" "lock parent unavailable" "abort names the lifecycle failure"
assert_file_not_contains "$WORK/s6.log" "-d" "nothing mutated when the lock cannot open"

# ===========================================================================
# 7. helper genuinely absent (feature off): controller behaves as before
# ===========================================================================
mkdir -p "$WORK/emptylib"
rm -f "$LOCK"   # earlier cases legitimately created it; a fresh acquire would recreate
: > "$WORK/g7"   # pre-opened GO so the s6-svc stub does not block
R="$WORK/r7" G="$WORK/g7" CUR_LIBDIR="$WORK/emptylib"
out="$(run_stop "$@" 2>&1)"; rc=$?
reset_knobs
assert_eq "$rc" 0 "controller runs when the helper is not installed"
assert_contains "$out" "server service stopped" "controller did its job unlocked"
assert_path_absent "$LOCK" "no lock file taken with the helper absent"

assert_report
