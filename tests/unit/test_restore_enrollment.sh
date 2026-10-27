#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Task 3 (idle-shutdown/knock-wake): palworld-restore enrollment in the
# lifecycle lock.
#
# Spec:  docs/superpowers/specs/2026-10-18-idle-shutdown-knock-wake.md  §4.1
# Plan:  docs/superpowers/plans/2026-10-18-idle-shutdown-knock-wake.md (Task 3)
#
# Restore is the enrolled script with the unusual ordering: it takes the
# lifecycle lock only AFTER its safety backup (palworld-backup holds and
# releases its own lock first — restore must never invert that order), and it
# then holds the lifecycle lock across stop -> swap -> start so no other
# lifecycle controller can interleave with a half-applied world.
#
# Proven with real processes and real flock:
#   A. During a restore, a concurrent acquirer is busy (75) both inside the
#      stop window and inside the start window, and succeeds after restore
#      exits; the world really was replaced.
#   B. The nested stop and start children receive a live borrowed descriptor
#      (validated through the module's own `borrowed` verb, not just an env
#      string), so they reuse the transaction instead of deadlocking on it.
#   C. With the lifecycle lock held by someone else, restore aborts with a
#      named refusal after the safety backup and BEFORE touching the server
#      or the world.
#
# Fixture shape mirrors tests/unit/test_restore_apply.sh (stub sbin, scratch,
# backups dir); only the lock behaviour is exercised here.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
LIB="$DIR/../../lib"
RESTORE="$DIR/../../sbin/palworld-restore"

WORK="$(mktemp -d)"
export PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/lifecycle-state"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

BK="$WORK/backups"
SC="$WORK/scratch"
SAVED="$WORK/install/Pal/Saved"
PAL="$WORK/install/Pal"
STUBS="$WORK/sbin"
LOGD="$WORK/log"
LOCK="$WORK/lifecycle.lock"
NAME="palworld-save-20260727T101500Z.tar.gz"
OWNER_USER="$(id -un)"
OWNER_GROUP="$(id -gn)"

# --- stubs -------------------------------------------------------------------
mkdir -p "$STUBS"
cat > "$STUBS/palworld-backup" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$STUB_LOG_DIR/backup.log"
dest="$STUB_BK/palworld-save-20260101T000000Z.tar.gz"
printf 'stub safety archive\n' > "$dest"
echo "$dest"
EOF
# stop: optionally validates the inherited borrowed descriptor through the
# module itself, then blocks between STOP_READY and STOP_GO (only when STOP_GO
# is configured — a forgotten knob must fail an assertion, not the suite).
cat > "$STUBS/palworld-graceful-stop" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$STUB_LOG_DIR/stop.log"
if [ -n "${STUB_CHECK_FD:-}" ]; then
  if env PYTHONPATH="$STUB_LIB" python3 -m palwarden_lifecycle borrowed 2>/dev/null; then
    printf 'FD:VALID\n' >> "$STUB_LOG_DIR/stop.log"
  else
    printf 'FD:INVALID\n' >> "$STUB_LOG_DIR/stop.log"
  fi
fi
if [ -n "${STOP_GO:-}" ]; then
  : > "${STOP_READY:?stop stub blocking without a READY path}"
  until [ -e "$STOP_GO" ]; do sleep 0.05; done
fi
exit 0
EOF
cat > "$STUBS/palworld-api" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$STUB_LOG_DIR/api.log"
echo 'HTTP 200 OK'
echo '{"servername":"stub","version":"v1"}'
exit 0
EOF
cat > "$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$STUB_LOG_DIR/systemctl.log"
case "${1:-}" in
  is-active) exit 3 ;;   # inactive: the normal state for a server being restored
  start)
    if [ -n "${STUB_CHECK_FD:-}" ]; then
      if env PYTHONPATH="$STUB_LIB" python3 -m palwarden_lifecycle borrowed 2>/dev/null; then
        printf 'FD:VALID\n' >> "$STUB_LOG_DIR/systemctl.log"
      else
        printf 'FD:INVALID\n' >> "$STUB_LOG_DIR/systemctl.log"
      fi
    fi
    if [ -n "${START_GO:-}" ]; then
      : > "${START_READY:?systemctl stub blocking without a READY path}"
      until [ -e "$START_GO" ]; do sleep 0.05; done
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUBS"/*

# --- fixtures ----------------------------------------------------------------
mkdir -p "$WORK/src/SaveGames/0" "$WORK/src/Config"
head -c 200000 /dev/urandom > "$WORK/src/SaveGames/0/Level.sav"
printf 'GOOD\n' > "$WORK/src/SaveGames/marker.txt"
printf 'cfg\n' > "$WORK/src/Config/PalWorldSettings.ini"
tar -C "$WORK/src" -czf "$WORK/good.tar.gz" SaveGames Config \
  || fail "could not build the good archive"

# --- helpers -------------------------------------------------------------------
env_args() {
  printf '%s\n' \
    "PYTHONPATH=$LIB" \
    "PALWARDEN_SAVE_BACKUP_DIR=$BK" \
    "PALWARDEN_RESTORE_SCRATCH=$SC" \
    "PALWARDEN_SBIN_DIR=$STUBS" \
    "PALWARDEN_SYSTEMCTL_BIN=$STUBS/systemctl" \
    "PALWORLD_SAVED_DIR=$SAVED" \
    "PALWORLD_USER=$OWNER_USER" \
    "PALWORLD_GROUP=$OWNER_GROUP" \
    "PALWARDEN_RESTORE_POLL_SECONDS=1" \
    "PALWARDEN_LIFECYCLE_LOCK=$LOCK" \
    "PALWARDEN_LIFECYCLE_TIMEOUT=1" \
    "STUB_LOG_DIR=$LOGD" \
    "STUB_BK=$BK" \
    "STUB_LIB=$LIB" \
    "STUB_CHECK_FD=${CHECK_FD:-}" \
    "STOP_READY=${STOP_READY:-}" "STOP_GO=${STOP_GO:-}" \
    "START_READY=${START_READY:-}" "START_GO=${START_GO:-}"
}
run() { mapfile -t e < <(env_args); env "${e[@]}" python3 "$RESTORE" "$@"; }

reset_all() {
  chmod -R u+rwX "$WORK/install" 2>/dev/null
  rm -rf "$BK" "$SC" "$WORK/install" "$LOGD"
  mkdir -p "$BK" "$LOGD" "$PAL" "$SC"
  : > "$LOGD/backup.log"; : > "$LOGD/stop.log"
  : > "$LOGD/api.log"; : > "$LOGD/systemctl.log"
  CHECK_FD="" STOP_READY="" STOP_GO="" START_READY="" START_GO=""
}
populate_world() {
  mkdir -p "$SAVED/SaveGames"
  printf 'PREVIOUS\n' > "$SAVED/SaveGames/old.sav"
}
stage() { cp "$WORK/good.tar.gz" "$BK/$NAME"; }

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

hold_lock() {  # READY GO
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

wait_for() {
  local f="$1" deadline=$(( SECONDS + ${2:-15} ))
  while [ ! -e "$f" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

# ===========================================================================
# A+B. happy path: lock held across stop AND start; children borrow it validly
# ===========================================================================
reset_all; populate_world; stage
CHECK_FD=1
STOP_READY="$WORK/sr" STOP_GO="$WORK/sg"
START_READY="$WORK/sar" START_GO="$WORK/sag"
run --restore "$NAME" --startup-timeout 10 >"$WORK/a.out" 2>&1 &
rp=$!
if ! wait_for "$WORK/sr"; then fail "restore never reached the stop"; fi
assert_rc 75 probe_free "concurrent acquire is busy while restore holds the lock across the stop"
: > "$WORK/sg"
if ! wait_for "$WORK/sar"; then fail "restore never reached the start"; fi
assert_rc 75 probe_free "concurrent acquire is busy while restore holds the lock across the start"
: > "$WORK/sag"
wait "$rp"; rc=$?
assert_eq "$rc" 0 "restore completed"
assert_rc 0 probe_free "lock is free again after restore exits"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" \
  "world really was replaced (the lock did not break the restore)"
assert_file_contains "$LOGD/stop.log" "FD:VALID" \
  "nested stop inherited a live borrowed descriptor (reuses, never deadlocks)"
assert_file_contains "$LOGD/systemctl.log" "FD:VALID" \
  "nested start inherited a live borrowed descriptor"

# ===========================================================================
# C. lifecycle lock held by another transaction: abort before touching anything
# ===========================================================================
reset_all; populate_world; stage
hold_lock "$WORK/hr" "$WORK/hg" &
hp=$!
if ! wait_for "$WORK/hr"; then fail "external holder never took the lock"; fi
out="$(run --restore "$NAME" --startup-timeout 10 2>&1)"; rc=$?
: > "$WORK/hg"
wait "$hp"
assert_ne "$rc" 0 "restore refuses while another transaction holds the lifecycle lock"
assert_contains "$out" "cannot take the lifecycle lock" "refusal is named"
assert_contains "$out" "nothing was stopped and the world was left untouched" \
  "refusal states the server and world are untouched"
assert_file_not_contains "$LOGD/stop.log" "ARGS" "no stop was attempted"
assert_file_not_contains "$LOGD/systemctl.log" "start" "no start was attempted"
assert_file_contains "$SAVED/SaveGames/old.sav" "PREVIOUS" "live world untouched"
# The safety backup legitimately ran BEFORE the refusal (documented ordering:
# backup's own lock is taken and released first; lifecycle comes after).
assert_file_contains "$LOGD/backup.log" "ARGS" "safety backup ran before the refusal"

assert_report
