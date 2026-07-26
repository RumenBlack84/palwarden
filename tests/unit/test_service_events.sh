#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Crash/restart watchdog summary (docs/backlog.md item 8).
#
# `sample` notices when the server process changed underneath us and records an
# event marker, classifying it as planned (we asked for a restart) or unexpected
# (it crashed / was restarted by something else). `summary` reports those for the
# CLI and the daily health report.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
EVENTS="$DIR/../../sbin/palworld-service-events"
FPS="$DIR/../../sbin/palworld-fps"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

DB="$WORK/metrics.sqlite3"
STATE="$WORK/service-events.json"

# fake systemctl driven by two files: the service state and its main PID
cat > "$WORK/bin/systemctl" <<EOF
#!/usr/bin/env bash
state="\$(cat "$WORK/state" 2>/dev/null || echo active)"
pid="\$(cat "$WORK/pid" 2>/dev/null || echo 100)"
for arg in "\$@"; do
  case "\$arg" in
    ActiveState) echo "ActiveState=\$state" ;;
    MainPID)     echo "MainPID=\$pid" ;;
  esac
done
exit 0
EOF
chmod +x "$WORK/bin/systemctl"

echo active > "$WORK/state"; echo 100 > "$WORK/pid"

run_events() {
  PATH="$WORK/bin:$PATH" \
  PALWORLD_METRICS_DB="$DB" \
  PALWORLD_SERVICE_STATE_FILE="$STATE" \
  PALWORLD_FPS_BIN="$FPS" \
    python3 "$EVENTS" "$@"
}
markers() { python3 "$FPS" --db "$DB" events --window 24h --json 2>/dev/null; }

# --- first sample just records the baseline, it is not a restart -------------
out="$(run_events sample 2>&1)"; rc=$?
assert_eq "$rc" "0" "first sample exits 0"
assert_contains "$out" "baseline" "first sample records a baseline"
assert_not_contains "$(markers)" "restart detected" "first sample does not invent a restart"

# --- no change: nothing recorded --------------------------------------------
out="$(run_events sample 2>&1)"
assert_contains "$out" "no change" "unchanged service reports no change"
assert_not_contains "$(markers)" "restart detected" "unchanged service records nothing"

# --- the PID changed with no restart of ours: unexpected --------------------
echo 200 > "$WORK/pid"
out="$(run_events sample 2>&1)"
assert_contains "$out" "unexpected" "PID change with no request is unexpected"
assert_contains "$(markers)" "restart detected" "a marker was recorded"
assert_contains "$(markers)" "unexpected" "the marker says unexpected"

# --- a PID change right after we asked for a restart is planned -------------
python3 "$FPS" --db "$DB" mark "graceful restart requested" --category restart --details "test" >/dev/null 2>&1
echo 300 > "$WORK/pid"
out="$(run_events sample 2>&1)"
assert_contains "$out" "planned" "PID change after a requested restart is planned"

# --- the service going down is reported --------------------------------------
echo inactive > "$WORK/state"; echo 0 > "$WORK/pid"
out="$(run_events sample 2>&1)"
assert_contains "$out" "not running" "an inactive service is reported"
assert_contains "$(markers)" "not running" "a marker records the outage"

# --- ...and coming back up ---------------------------------------------------
echo active > "$WORK/state"; echo 400 > "$WORK/pid"
out="$(run_events sample 2>&1)"
assert_contains "$out" "came back up" "recovery is reported"

# --- summary counts what happened -------------------------------------------
out="$(run_events summary --since 24h 2>&1)"; rc=$?
assert_eq "$rc" "0" "summary exits 0"
assert_contains "$out" "restarts detected" "summary reports restarts detected"
assert_contains "$out" "unexpected" "summary distinguishes unexpected restarts"

json="$(run_events summary --since 24h --json 2>&1)"
assert_rc 0 python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert 'restarts' in d and 'unexpected' in d" "$json"

# --- a quiet period summarises cleanly, and never crashes on an empty DB -----
rm -f "$DB"
out="$(run_events summary --since 24h 2>&1)"; rc=$?
assert_eq "$rc" "0" "summary on an empty DB exits 0"
assert_not_contains "$out" "Traceback" "summary on an empty DB does not crash"

assert_report
