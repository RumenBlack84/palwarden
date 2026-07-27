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
mkdir -p "$WORK/jobs" "$WORK/bin" "$WORK/etc" "$WORK/backups"

# stub tools that record their argv so we can prove nothing was mangled
stub_tools() {
  for tool in palworld-backup palworld-config-pretty palworld-config-apply-env \
              palworld-config-snapshot palworld-engine-config palworld-graceful-restart \
              palworld-graceful-stop palworld-update palworld-api-save palworld-fps; do
    cat > "$WORK/bin/$tool" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$0") \$*" >> "$WORK/argv.log"
echo "ran \$(basename "\$0")"
EOF
    chmod +x "$WORK/bin/$tool"
  done
}
stub_tools

# ENGINE_ENV/BACKUP_DIR/LOCK all live under $WORK: the worker now takes its
# flock in every mode, so the default /run path would fail for a non-root test.
jobd() {
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" \
  PALWARDEN_SBIN_DIR="$WORK/bin" PALWORLD_ENGINE_ENV="${ENGINE_ENV_OVERRIDE:-$WORK/etc/engine.env}" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWARDEN_JOBD_LOCK="$WORK/jobd.lock" \
  PATH="$WORK/bin:$PATH" \
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
assert_file_contains "$WORK/argv.log" "create -- before-tuning_2" "label passed verbatim after --"

# a label that looks like a flag must arrive as a positional, not be eaten as one
: > "$WORK/argv.log"
id="$(enqueue snapshot_create '{"label": "--no-mark"}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "flag-shaped label accepted (it is a legal label)"
assert_file_contains "$WORK/argv.log" "create -- --no-mark" "flag-shaped label passed as a positional"

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

# The failing engine-config stub above is still installed; restore the recorders
# before the remaining sections.
stub_tools

# --- confirm must be exactly true, not merely truthy ----------------------
# A UI that posts confirm:"yes" or confirm:1 has NOT shown a confirmation
# dialog to anyone; only the literal boolean counts.
for bad in '"yes"' '1'; do
  id="$(enqueue graceful_restart "{\"wait\": 30, \"confirm\": $bad}")"
  jobd --once >/dev/null 2>&1
  assert_eq "$(state_of "$id")" "failed" "confirm: $bad is not confirmation"
  assert_contains "$(output_of "$id")" "requires confirm" "explains the refusal for confirm: $bad"
done

# --- wait must be an int, and a JSON bool is not one ---------------------
# isinstance(True, int) is True in Python, so {"wait": true} would silently
# become --wait 1 without an explicit bool rejection.
: > "$WORK/argv.log"
id="$(enqueue graceful_restart '{"wait": true, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "boolean wait rejected"
assert_file_not_contains "$WORK/argv.log" "graceful-restart" "boolean wait never reached a command"

# --- wait is optional: omit --wait so the tool's own default applies ------
: > "$WORK/argv.log"
id="$(enqueue graceful_restart '{"confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "graceful_restart without wait succeeds"
assert_file_contains "$WORK/argv.log" "palworld-graceful-restart" "restart still ran"
assert_file_not_contains "$WORK/argv.log" "--wait" "no --wait when the caller did not ask for one"

# --- settings values may be JSON numbers, but never booleans -------------
rm -f "$WORK/etc/engine.env"
id="$(enqueue engine_save '{"settings": {"NET_SERVER_MAX_TICK_RATE": 60}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "integer setting value accepted"
assert_file_contains "$WORK/etc/engine.env" "NET_SERVER_MAX_TICK_RATE=60" "integer normalised to a string"
id="$(enqueue engine_save '{"settings": {"NET_SERVER_MAX_TICK_RATE": true}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "boolean setting value rejected"

# --- engine_save merges: unsubmitted keys stay managed -------------------
# Dropping a key would silently unmanage it — apply would stop enforcing it and
# the drift check would go blind to it.
cat > "$WORK/etc/engine.env" <<'EOF'
NET_SERVER_MAX_TICK_RATE=60
MAX_CLIENT_RATE=100000
EOF
id="$(enqueue engine_save '{"settings": {"NET_SERVER_MAX_TICK_RATE": "90"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "partial engine_save succeeds"
assert_file_contains "$WORK/etc/engine.env" "NET_SERVER_MAX_TICK_RATE=90" "submitted key updated"
assert_file_contains "$WORK/etc/engine.env" "MAX_CLIENT_RATE=100000" "unsubmitted key preserved"
assert_file_contains "$WORK/etc/engine.env" "# Generated by palwarden-jobd" "generated header preserved"

# --- a failed engine.env write aborts the whole composite action ---------
# ENGINE_ENV under a read-only directory. Root ignores the 0500 mode, so the
# write would succeed and this would fail for an environmental reason; skip that
# one assertion there (CI runs unprivileged, so the coverage is kept). Same
# root-divergence pattern as the s6-svstat gotcha in CLAUDE.md.
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP: unwritable-directory check needs a non-root uid (root ignores mode 0500)"
else
  mkdir -p "$WORK/readonly"
  chmod 0500 "$WORK/readonly"
  : > "$WORK/argv.log"
  id="$(enqueue engine_save_apply_restart '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60"}, "wait": 30, "confirm": true}')"
  ENGINE_ENV_OVERRIDE="$WORK/readonly/engine.env" jobd --once >/dev/null 2>&1
  chmod 0700 "$WORK/readonly"
  assert_eq "$(state_of "$id")" "failed" "composite fails when engine.env cannot be written"
  assert_file_not_contains "$WORK/argv.log" "engine-config apply" "no apply after a failed save"
  assert_file_not_contains "$WORK/argv.log" "graceful-restart" "no restart after a failed save"
fi

# --- every mode holds the worker lock -----------------------------------
# A stray --once/--reap during a long update_apply would reap the live job as
# failed and race claim_next, so it must refuse to start instead.
id="$(enqueue backup '{}')"
holder_out="$(
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" PALWARDEN_SBIN_DIR="$WORK/bin" \
  PALWORLD_ENGINE_ENV="$WORK/etc/engine.env" PALWORLD_BACKUP_DIR="$WORK/backups" \
  PALWARDEN_JOBD_LOCK="$WORK/jobd.lock" TEST_JOBD="$JOBD" \
  python3 - "$WORK/jobd.lock" <<'EOF'
import fcntl, os, subprocess, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
for mode in ("--once", "--reap"):
    p = subprocess.run([sys.executable, os.environ["TEST_JOBD"], mode],
                       capture_output=True, text=True)
    print(mode, p.returncode, p.stderr.strip().replace("\n", " "))
EOF
)" || true
assert_contains "$holder_out" "--once 1 " "--once refuses to run while the lock is held"
assert_contains "$holder_out" "--reap 1 " "--reap refuses to run while the lock is held"
assert_contains "$holder_out" "holds" "explains why it exited"
assert_eq "$(state_of "$id")" "queued" "the locked-out worker touched nothing"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "the job runs once the lock is free"

# --- argument parsing ---------------------------------------------------
jobd --help >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "--help exits 0"
jobd --definitely-not-a-flag >/dev/null 2>&1; rc=$?
assert_ne "$rc" "0" "an unrecognised flag does not start the daemon"

# --- a bad PALWARDEN_JOBD_INTERVAL falls back instead of crashing --------
id="$(enqueue backup '{}')"
out="$(PALWARDEN_JOBD_INTERVAL="two seconds" jobd --once 2>&1)"
assert_eq "$(state_of "$id")" "succeeded" "a bad interval does not break every action"
assert_contains "$out" "PALWARDEN_JOBD_INTERVAL" "warns about the bad interval"

# --- remaining actions: argv reaching the tool is exactly the spec's -----
: > "$WORK/argv.log"
id="$(enqueue mark '{"text": "tuned tick rate"}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "mark succeeds"
assert_file_contains "$WORK/argv.log" "palworld-fps mark --category manual -- tuned tick rate" "mark argv exact"

: > "$WORK/argv.log"
id="$(enqueue engine_apply '{}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "engine_apply succeeds"
assert_file_contains "$WORK/argv.log" "palworld-engine-config apply" "engine_apply argv exact"
assert_file_not_contains "$WORK/argv.log" "--dry-run" "engine_apply is not a dry run by default"

: > "$WORK/argv.log"
id="$(enqueue engine_apply '{"dry_run": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "engine_apply --dry-run succeeds"
assert_file_contains "$WORK/argv.log" "palworld-engine-config apply --dry-run" "engine_apply dry-run argv exact"

: > "$WORK/argv.log"
id="$(enqueue graceful_stop '{"wait": 60, "message": "maintenance", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "graceful_stop succeeds"
assert_file_contains "$WORK/argv.log" "palworld-graceful-stop --wait 60 --message maintenance" "graceful_stop argv exact"

: > "$WORK/argv.log"
id="$(enqueue update_check '{"confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "update_check succeeds"
assert_file_contains "$WORK/argv.log" "palworld-update --check" "update_check argv exact"

: > "$WORK/argv.log"
id="$(enqueue update_apply '{"wait": 300, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "update_apply succeeds"
assert_file_contains "$WORK/argv.log" "palworld-update --wait 300" "update_apply argv exact"

: > "$WORK/argv.log"
id="$(enqueue api_save '{"confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "api_save succeeds"
assert_file_contains "$WORK/argv.log" "palworld-api-save" "api_save argv exact"

# --- engine_rollback: only real backups, and never through a symlink -----
# The backup directory is owned by the unprivileged web user, so its contents
# are attacker-controlled: a symlink there would otherwise be copied over
# Engine.ini and chmod 0644'd, publishing any root-readable file.
echo "[/script/onlineSubsystemUtils.ipnetdriver]" > "$WORK/backups/Engine.ini.20260710T182037Z"
: > "$WORK/argv.log"
id="$(enqueue engine_rollback '{"backup": "Engine.ini.20260710T182037Z", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "rollback to a real backup succeeds"
assert_file_contains "$WORK/argv.log" "palworld-engine-config rollback -- Engine.ini.20260710T182037Z" "rollback argv exact"

# the `-N` suffix palworld-engine-config adds when two applies land in the same
# UTC second is part of the legitimate name shape: those backups must be rollable
echo "[/script/onlineSubsystemUtils.ipnetdriver]" > "$WORK/backups/Engine.ini.20260710T182037Z-1"
: > "$WORK/argv.log"
id="$(enqueue engine_rollback '{"backup": "Engine.ini.20260710T182037Z-1", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "a same-second -1 backup can be rolled back"
assert_file_contains "$WORK/argv.log" "rollback -- Engine.ini.20260710T182037Z-1" "the -1 name passed verbatim"

# ...but the suffix is digits only; it is not a licence for arbitrary trailing text
: > "$WORK/argv.log"
echo "[whatever]" > "$WORK/backups/Engine.ini.20260710T182037Z-pwn"
id="$(enqueue engine_rollback '{"backup": "Engine.ini.20260710T182037Z-pwn", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "a non-numeric suffix is still off-pattern"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "off-pattern suffix never reached a command"

echo "ADMIN_PASSWORD=hunter2" > "$WORK/etc/settings.env"
ln -sf "$WORK/etc/settings.env" "$WORK/backups/Engine.ini.20260101T000000Z"
: > "$WORK/argv.log"
id="$(enqueue engine_rollback '{"backup": "Engine.ini.20260101T000000Z", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "a symlinked backup is refused"
assert_contains "$(output_of "$id")" "symlink" "says why the symlink was refused"
assert_file_not_contains "$WORK/argv.log" "rollback" "symlinked backup never reached a command"

# a name that is not the shape palworld-engine-config writes is refused, even
# when such a file exists
ln -sf "$WORK/etc/settings.env" "$WORK/backups/Engine.ini.pwn"
id="$(enqueue engine_rollback '{"backup": "Engine.ini.pwn", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "off-pattern backup name refused"

# ...and as a plain REGULAR file, so the name check is what does the refusing.
# With a symlink, the symlink guard would refuse it anyway and deleting BACKUP_RE
# would leave the suite green (it did).
echo "[whatever]" > "$WORK/backups/notabackup"
: > "$WORK/argv.log"
id="$(enqueue engine_rollback '{"backup": "notabackup", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "off-pattern regular file refused on its name alone"
assert_contains "$(output_of "$id")" "backup must match" "names the pattern it failed"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "off-pattern regular file never reached a command"
id="$(enqueue engine_rollback '{"backup": "../../etc/palworld/settings.env", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "path traversal in backup name refused"

# --- params are a whitelist: an unrecognised key is refused, not ignored ---
# A copy-the-request normalisation stored whatever the caller sent (the API's
# body cap is 64 KiB, so that was 64 KiB of junk per request), and silently
# dropped a typo: `waitt: 30` produced a restart with no wait at all.
: > "$WORK/argv.log"
id="$(enqueue graceful_restart '{"waitt": 30, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "an unrecognised param key is refused"
assert_contains "$(output_of "$id")" "'waitt'" "the refusal names the offending key"
assert_contains "$(output_of "$id")" "it takes: confirm, message, wait" "and lists what it does take"
assert_file_not_contains "$WORK/argv.log" "graceful-restart" "the typo'd restart never ran"
id="$(enqueue backup '{"pad": "xxxxx"}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "a param on an action that takes none is refused"
assert_contains "$(output_of "$id")" "'pad'" "names the offending key there too"

# ...and every recognised key still round-trips, for every action. Driven off
# ACTIONS itself so a new param name (or one added to the whitelist with no
# validator behind it) fails here instead of being quietly dropped.
roundtrip="$(
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" PALWARDEN_SBIN_DIR="$WORK/bin" \
  PALWORLD_ENGINE_ENV="$WORK/etc/engine.env" PALWORLD_BACKUP_DIR="$WORK/backups" \
  PALWARDEN_JOBD_LOCK="$WORK/jobd.lock" \
  python3 - "$JOBD" <<'EOF'
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("jobd_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

SAMPLES = {
    "confirm": True,
    "wait": 30,
    "message": "maintenance",
    "label": "before-tuning",
    "text": "tuned tick rate",
    "dry_run": True,
    "settings": {"NET_SERVER_MAX_TICK_RATE": "60"},
    "backup": "Engine.ini.20260710T182037Z",
}
for action in mod.ACTIONS:
    keys = mod.recognised_params(action)
    missing = sorted(k for k in keys if k not in SAMPLES)
    if missing:
        print(f"FAIL {action}: no sample value for {missing}")
        continue
    params = {k: SAMPLES[k] for k in keys}
    got, err = mod.validate_params(action, params)
    if err is not None:
        print(f"FAIL {action}: {err}")
    elif set(got) != set(keys):
        print(f"FAIL {action}: normalised {sorted(got)} != recognised {sorted(keys)}")
print("done")
EOF
)"
assert_eq "$roundtrip" "done" "every recognised param key round-trips for every action"

assert_report
