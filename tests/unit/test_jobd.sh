#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# The worker holds root, and its only input is a file written by a process we
# treat as untrusted. So it re-validates everything: unknown actions, hostile
# parameters and hand-edited job files must all be refused, and no parameter may
# ever reach a shell.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
JOBD="$DIR/../../sbin/palwarden-jobd"
LIB="$DIR/../../lib"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/jobs" "$WORK/bin" "$WORK/etc"

# stub tools that record their argv so we can prove nothing was mangled
for tool in palworld-backup palworld-config-pretty palworld-config-apply-env \
            palworld-config-snapshot palworld-engine-config palworld-graceful-restart \
            palworld-fps; do
  cat > "$WORK/bin/$tool" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$0") \$*" >> "$WORK/argv.log"
echo "ran \$(basename "\$0")"
EOF
  chmod +x "$WORK/bin/$tool"
done

jobd() {
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" \
  PALWARDEN_SBIN_DIR="$WORK/bin" PALWORLD_ENGINE_ENV="$WORK/etc/engine.env" \
    python3 "$JOBD" "$@"
}
enqueue() {  # enqueue <action> <json-params>
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import json, sys, palwarden_jobs as j
print(j.create_job(sys.argv[1], json.loads(sys.argv[2]))['id'])" "$1" "$2"
}
state_of() {
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import sys, palwarden_jobs as j
job = j.read_job(sys.argv[1]); print(job['state'] if job else 'missing')" "$1"
}
output_of() {
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import sys, palwarden_jobs as j
job = j.read_job(sys.argv[1]); print((job or {}).get('output',''))" "$1"
}

# --- a simple file-only action succeeds -----------------------------------
id="$(enqueue backup '{}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "backup job succeeds"
assert_contains "$(output_of "$id")" "ran palworld-backup" "captures tool output"

# --- an unknown action is refused by the WORKER, not just the API ---------
id="$(enqueue definitely_not_an_action '{}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "unknown action fails"
assert_contains "$(output_of "$id")" "not an allowed action" "explains the refusal"

# --- hostile parameters are rejected, never passed through ----------------
: > "$WORK/argv.log"
id="$(enqueue snapshot_create '{"label": "; rm -rf /"}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "hostile label rejected"
assert_file_not_contains "$WORK/argv.log" "rm -rf" "hostile label never reached a command"

id="$(enqueue graceful_restart '{"wait": 999999, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "out-of-range wait rejected"

# --- a valid label IS passed through, exactly ----------------------------
: > "$WORK/argv.log"
id="$(enqueue snapshot_create '{"label": "before-tuning_2"}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "valid label accepted"
assert_file_contains "$WORK/argv.log" "create before-tuning_2" "label passed verbatim"

# --- engine_save writes engine.env from validated pairs ------------------
id="$(enqueue engine_save '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60", "MAX_CLIENT_RATE": "100000"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "engine_save succeeds"
assert_file_contains "$WORK/etc/engine.env" "NET_SERVER_MAX_TICK_RATE=60" "wrote the tick rate"
assert_file_contains "$WORK/etc/engine.env" "MAX_CLIENT_RATE=100000" "wrote the client rate"

# unknown key and out-of-range value are both refused
id="$(enqueue engine_save '{"settings": {"NOT_A_SETTING": "1"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "unknown engine setting rejected"
id="$(enqueue engine_save '{"settings": {"NET_SERVER_MAX_TICK_RATE": "9999"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "out-of-range tick rate rejected"

# --- the composite action runs its steps in order and stops on failure ----
: > "$WORK/argv.log"
id="$(enqueue engine_save_apply_restart '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60"}, "wait": 30, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "composite action succeeds"
log="$(cat "$WORK/argv.log")"
assert_contains "$log" "palworld-engine-config apply" "applied the config"
assert_contains "$log" "palworld-graceful-restart" "restarted the server"
apply_line="$(grep -n 'engine-config apply' "$WORK/argv.log" | cut -d: -f1 | head -1)"
restart_line="$(grep -n 'graceful-restart' "$WORK/argv.log" | cut -d: -f1 | head -1)"
if [ "$apply_line" -lt "$restart_line" ]; then pass; else fail "apply must run before restart"; fi

# a failing apply must NOT reach the restart
cat > "$WORK/bin/palworld-engine-config" <<'EOF'
#!/usr/bin/env bash
echo "apply exploded" >&2; exit 7
EOF
chmod +x "$WORK/bin/palworld-engine-config"
: > "$WORK/argv.log"
id="$(enqueue engine_save_apply_restart '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60"}, "wait": 30, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "composite fails when apply fails"
assert_file_not_contains "$WORK/argv.log" "graceful-restart" "no restart after a failed apply"

# --- disruptive actions require confirm ---------------------------------
id="$(enqueue graceful_restart '{"wait": 30}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "disruptive action without confirm is refused"

# --- a hand-edited job file is refused ----------------------------------
id="$(enqueue backup '{}')"
PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import sys, json, palwarden_jobs as j
p = j.job_path(sys.argv[1]); d = json.loads(p.read_text())
d['action'] = 'graceful_restart'; d['params'] = {}
p.write_text(json.dumps(d))" "$id"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "tampered action is re-validated and refused"

# --- orphaned running jobs are reaped on startup ------------------------
id="$(enqueue backup '{}')"
PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import sys, palwarden_jobs as j
j.update_job(sys.argv[1], state='running')" "$id"
jobd --reap >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "orphaned running job marked failed"
assert_contains "$(output_of "$id")" "did not finish" "explains the orphaning"

assert_report
