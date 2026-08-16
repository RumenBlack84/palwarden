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
# backups/ is the *config* backup dir (engine_rollback's source); uploads/ and
# savebackups/ are the staging and world-save-archive dirs the backup actions use.
mkdir -p "$WORK/jobs" "$WORK/bin" "$WORK/etc" "$WORK/backups" \
         "$WORK/uploads" "$WORK/savebackups"
ARCHIVE="palworld-save-20260726T031500Z.tar.gz"
ARCHIVE2="palworld-save-20260726T041500Z.tar.gz"
# The worker only ever stats these (the tools it spawns are what read the bytes),
# so a placeholder file is enough to stand in for a real archive here.
printf 'placeholder\n' > "$WORK/uploads/$ARCHIVE"
printf 'placeholder\n' > "$WORK/savebackups/$ARCHIVE"

# stub tools that record their argv so we can prove nothing was mangled
stub_tools() {
  for tool in palworld-backup palworld-config-pretty palworld-config-apply-env \
              palworld-config-snapshot palworld-engine-config palworld-graceful-restart \
              palworld-graceful-stop palworld-update palworld-api-save palworld-fps \
              palworld-restore palworld-backups; do
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
# The live config settings_save validates against; a real full-shaped file so
# key resolution and value rendering behave exactly as they will in production.
cp "$DIR/../fixtures/PalWorldSettings.full.ini" "$WORK/PalWorldSettings.ini"
# Exported (not set per-call in jobd() alone) because jobd module-loads the
# parser at import time, and several checks below import jobd from inline
# python of their own — every one of them needs the dev-checkout path.
export PALWARDEN_PARSER_BIN="$DIR/../../bin/palworld-config-parser"

jobd() {
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" \
  PALWARDEN_SBIN_DIR="$WORK/bin" PALWORLD_ENGINE_ENV="${ENGINE_ENV_OVERRIDE:-$WORK/etc/engine.env}" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWARDEN_JOBD_LOCK="$WORK/jobd.lock" \
  PALWARDEN_UPLOAD_DIR="$WORK/uploads" PALWARDEN_SAVE_BACKUP_DIR="$WORK/savebackups" \
  PALWORLD_BACKUP_SCHEDULE="${SCHEDULE_OVERRIDE:-$WORK/etc/backup.env}" \
  PALWARDEN_PARSER_BIN="$DIR/../../bin/palworld-config-parser" \
  PALWORLD_CONFIG_FILE="${CONFIG_FILE_OVERRIDE:-$WORK/PalWorldSettings.ini}" \
  PALWORLD_SETTINGS_OVERRIDES="$WORK/etc/settings-overrides.env" \
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

# --- write_engine_env creates its temp O_EXCL|O_NOFOLLOW under a unique name ---
# engine_save is confirm-free, and write_engine_env used a FIXED "engine.env.tmp"
# opened without O_EXCL/O_NOFOLLOW, then chmod'd and re-read *by path*. /etc/palworld
# is root:root 0755 so nothing can plant there today — but this was the last
# check-then-use-by-path write in the worker, the exact pattern closed everywhere
# else, so it is pinned rather than left to the next person to rediscover.
#
# Observable without root: plant a symlink at the temp name the writer would have
# used and assert (a) that the fixed name is not what it uses at all, and (b) that
# a link *at whatever name it does use* is refused rather than followed.
if [ -e "$WORK/etc/engine.env.tmp" ]; then fail "a fixed-name temp file exists"; else pass; fi

printf 'DO-NOT-CLOBBER\n' > "$WORK/victim-env"
ln -sfn "$WORK/victim-env" "$WORK/etc/engine.env.tmp"
id="$(enqueue engine_save '{"settings": {"NET_SERVER_MAX_TICK_RATE": "61"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "engine_save is unaffected by a link at the old fixed temp name"
assert_file_contains "$WORK/victim-env" "DO-NOT-CLOBBER" "the pre-planted fixed-name temp was never written through"
assert_file_contains "$WORK/etc/engine.env" "NET_SERVER_MAX_TICK_RATE=61" "and the real write still landed"
rm -f "$WORK/etc/engine.env.tmp"

# ...and the kernel refusal itself: pin the random suffix so a symlink can occupy
# the exact name the writer is about to use, and assert it fails the job instead of
# writing through the link. (Same shape as the temp-name block in
# test_jobs_store.sh, which pins secrets.token_hex for the same reason.)
printf 'DO-NOT-CLOBBER\n' > "$WORK/victim-env2"
excl="$(
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" PALWARDEN_SBIN_DIR="$WORK/bin" \
  PALWORLD_ENGINE_ENV="$WORK/etc/engine.env" PALWORLD_BACKUP_DIR="$WORK/backups" \
  PALWARDEN_JOBD_LOCK="$WORK/jobd.lock" \
  python3 - "$JOBD" "$WORK/etc/engine.env" "$WORK/victim-env2" <<'EOF'
import importlib.machinery, importlib.util, os, secrets, sys
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("jobd_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

env_path, victim = Path(sys.argv[2]), Path(sys.argv[3])
real = secrets.token_hex
mod_secrets = sys.modules[mod.__name__].secrets
mod_secrets.token_hex = lambda n: "deadbeef" if n == 4 else real(n)
tmp = env_path.with_name(f"{env_path.name}.tmp.{os.getpid()}.deadbeef")
os.symlink(victim, tmp)
try:
    mod.write_engine_env({"NET_SERVER_MAX_TICK_RATE": "62"})
    print("FOLLOWED")
except OSError:
    print("refused" if victim.read_text().strip() == "DO-NOT-CLOBBER" else "CLOBBERED")
finally:
    if tmp.is_symlink():
        tmp.unlink()
EOF
)"
assert_eq "$excl" "refused" "a symlink at the temp name it does use is refused, not followed"
assert_file_contains "$WORK/victim-env2" "DO-NOT-CLOBBER" "the victim of that attempt is intact"

# --- the composite action: the apply rides INSIDE the restart --------------
# Not a separate argv before it: applying while the server still runs is lost
# work (the game rewrites its config from memory as it exits and clobbers the
# freshly-applied file mid-shutdown — observed on v1.0.3). --apply-engine tells
# palworld-graceful-restart to run the apply after the server has fully
# stopped; the ordering inside that window is that tool's own test's business
# (test_graceful_restart.sh).
: > "$WORK/argv.log"
id="$(enqueue engine_save_apply_restart '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60"}, "wait": 30, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "composite action succeeds"
assert_file_contains "$WORK/argv.log" "palworld-graceful-restart --apply-engine --wait 30" \
  "the restart carries the apply flag and the wait"
assert_file_not_contains "$WORK/argv.log" "engine-config apply" \
  "no separate apply argv before the restart (it would race the game's exit write)"

# a failing restart (which reports a failed in-window apply as nonzero) fails the job
cat > "$WORK/bin/palworld-graceful-restart" <<'EOF2'
#!/usr/bin/env bash
echo "apply exploded inside the restart window" >&2; exit 1
EOF2
chmod +x "$WORK/bin/palworld-graceful-restart"
id="$(enqueue engine_save_apply_restart '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60"}, "wait": 30, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "composite fails when the restart (or its in-window apply) fails"
assert_contains "$(output_of "$id")" "apply exploded" "the failure reason reaches the job output"
stub_tools

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

# --- a job file whose id disagrees with its filename must not wedge the queue ---
# The demonstrated wedge: claim_next raised KeyError on such a file, and poll_once
# called claim_next *outside* its own try, so the raise escaped to main's loop —
# a traceback every PALWARDEN_JOBD_INTERVAL seconds forever and no other job ever
# draining. Two independent fixes, both asserted: palwarden_jobs.read_job refuses
# the file (test_jobs_store.sh), and claim_next now sits inside poll_once's guard.
: > "$WORK/argv.log"
bad_id="$(enqueue backup '{}')"
PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import sys, json, palwarden_jobs as j
p = j.job_path(sys.argv[1]); d = json.loads(p.read_text())
d['id'] = 'd' * 32              # disagrees with the file it lives in
p.write_text(json.dumps(d))" "$bad_id"
good_id="$(enqueue config_pretty '{}')"
jobd --once >"$WORK/wedge.out" 2>"$WORK/wedge.err"
rc=$?
assert_eq "$rc" "0" "--once exits cleanly with a mismatched job file in the queue"
assert_file_not_contains "$WORK/wedge.err" "Traceback" "no traceback escapes to the daemon"
assert_file_not_contains "$WORK/wedge.err" "KeyError" "and specifically no KeyError from claim_next"
assert_eq "$(state_of "$good_id")" "succeeded" "the job behind the bad file still ran"
assert_file_contains "$WORK/argv.log" "palworld-config-pretty" "and really ran its tool"

# poll_once must survive a claim_next that raises for *any* reason, not just this
# one — the structural half of the fix. Stub claim_next to explode and assert
# poll_once returns rather than propagating.
survives="$(
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" PALWARDEN_SBIN_DIR="$WORK/bin" \
  PALWORLD_ENGINE_ENV="$WORK/etc/engine.env" PALWORLD_BACKUP_DIR="$WORK/backups" \
  PALWARDEN_JOBD_LOCK="$WORK/jobd.lock" \
  python3 - "$JOBD" <<'EOF' 2>/dev/null
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("jobd_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)


def boom():
    raise KeyError("deadbeef")


mod.jobs.claim_next = boom
try:
    mod.poll_once()
    print("survived")
except BaseException as exc:
    print("ESCAPED %r" % (exc,))
EOF
)"
assert_eq "$survives" "survived" "poll_once contains a raise from claim_next instead of ending the daemon"

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
  PALWARDEN_UPLOAD_DIR="$WORK/uploads" PALWARDEN_SAVE_BACKUP_DIR="$WORK/savebackups" \
  PALWORLD_BACKUP_SCHEDULE="$WORK/etc/backup.env" \
  PALWORLD_CONFIG_FILE="$WORK/PalWorldSettings.ini" \
  python3 - "$JOBD" "$ARCHIVE" <<'EOF'
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("jobd_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

archive_name = sys.argv[2]
SAMPLES = {
    "confirm": True,
    "wait": 30,
    "message": "maintenance",
    "label": "before-tuning",
    "text": "tuned tick rate",
    "dry_run": True,
    "settings": {"NET_SERVER_MAX_TICK_RATE": "60"},
    "backup": "Engine.ini.20260710T182037Z",
    "staged": archive_name,
}
# `settings` and `backup` mean different things to different actions (an engine
# table vs the backup schedule; a config backup vs a world-save archive), so those
# actions bring their own sample rather than the shared one being widened to
# something every validator would accept — which would defeat the check.
OVERRIDES = {
    "settings_save": {"settings": {"ExpRate": "2"}},
    "settings_save_apply_restart": {"settings": {"ExpRate": "2"}},
    "backup_schedule_save": {"settings": {"BACKUP_ENABLED": True,
                                          "BACKUP_INTERVAL_HOURS": 24,
                                          "BACKUP_RETENTION_DAYS": 14,
                                          "BACKUP_KEEP_MIN": 3}},
    "backup_restore": {"backup": archive_name},
    "backup_delete": {"backup": archive_name},
}
for action in mod.ACTIONS:
    keys = mod.recognised_params(action)
    samples = dict(SAMPLES, **OVERRIDES.get(action, {}))
    missing = sorted(k for k in keys if k not in samples)
    if missing:
        print(f"FAIL {action}: no sample value for {missing}")
        continue
    params = {k: samples[k] for k in keys}
    got, err = mod.validate_params(action, params)
    if err is not None:
        print(f"FAIL {action}: {err}")
    elif set(got) != set(keys):
        print(f"FAIL {action}: normalised {sorted(got)} != recognised {sorted(keys)}")
print("done")
EOF
)"
assert_eq "$roundtrip" "done" "every recognised param key round-trips for every action"

# --- backup_import: promote one staged upload, exact argv -------------------
# The name is the *value* of --import, so no `--` may separate them: argparse would
# fail with "expected one argument". valid_archive_name is what makes that safe.
: > "$WORK/argv.log"
id="$(enqueue backup_import "{\"staged\": \"$ARCHIVE\"}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "backup_import succeeds"
assert_eq "$(cat "$WORK/argv.log")" "palworld-restore --import $ARCHIVE" "backup_import argv exact"

# ...and it looks in the UPLOAD dir, not the backups dir: an archive that exists
# only as a promoted backup is not something there is anything left to import.
printf 'placeholder\n' > "$WORK/savebackups/$ARCHIVE2"
: > "$WORK/argv.log"
id="$(enqueue backup_import "{\"staged\": \"$ARCHIVE2\"}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "an archive present only in the backups dir is not importable"
assert_contains "$(output_of "$id")" "staged not found in the upload directory" "says which directory it looked in"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "the missing upload never reached a command"

# a symlink in the staging dir under a legitimate name is refused, not followed:
# the web account owns that directory, so it chooses what root would have read.
ln -sf "$WORK/etc/settings.env" "$WORK/uploads/$ARCHIVE2"
: > "$WORK/argv.log"
id="$(enqueue backup_import "{\"staged\": \"$ARCHIVE2\"}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "a symlinked staged upload is refused"
assert_contains "$(output_of "$id")" "staged must not be a symlink" "says why the staged symlink was refused"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "the symlinked upload never reached a command"
rm -f "$WORK/uploads/$ARCHIVE2"

# --- hostile staged/backup names never reach argv --------------------------
# A REGULAR file with an off-pattern name, so the pattern check is what refuses it:
# with a symlink the symlink guard would refuse it anyway and deleting the pattern
# check would leave the suite green.
printf 'placeholder\n' > "$WORK/uploads/notanarchive"
printf 'placeholder\n' > "$WORK/savebackups/notanarchive"
: > "$WORK/argv.log"
id="$(enqueue backup_import '{"staged": "notanarchive"}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "off-pattern staged name refused on its name alone"
assert_contains "$(output_of "$id")" "staged must match" "names the pattern the staged name failed"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "off-pattern staged name never reached a command"

: > "$WORK/argv.log"
id="$(enqueue backup_delete '{"backup": "notanarchive", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "off-pattern save-archive name refused on its name alone"
assert_contains "$(output_of "$id")" "backup must match" "names the pattern the archive name failed"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "off-pattern archive name never reached a command"

# separators, traversal and a shell metacharacter, on both parameters. Built with
# json.dumps so the shell never has to quote these values correctly for them to be
# the values under test.
hostile_params() {  # hostile_params <key> <value> [extra-json-key]
  python3 -c "
import json, sys
params = {sys.argv[1]: sys.argv[2]}
if len(sys.argv) > 3:
    params[sys.argv[3]] = True
print(json.dumps(params))" "$@"
}
for hostile in '../../etc/palworld/settings.env' 'sub/palworld-save-20260726T031500Z.tar.gz' \
               'palworld-save-20260726T031500Z.tar.gz; rm -rf /' \
               "palworld-save-20260726T031500Z.tar.gz\$(id)" \
               "palworld-save-20260726T031500Z.tar.gz\\" '..' ''; do
  : > "$WORK/argv.log"
  id="$(enqueue backup_import "$(hostile_params staged "$hostile")")"
  jobd --once >/dev/null 2>&1
  assert_eq "$(state_of "$id")" "failed" "hostile staged value refused: '$hostile'"
  assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "hostile staged value never reached a command: '$hostile'"
  : > "$WORK/argv.log"
  id="$(enqueue backup_restore "$(hostile_params backup "$hostile" confirm)")"
  jobd --once >/dev/null 2>&1
  assert_eq "$(state_of "$id")" "failed" "hostile backup value refused: '$hostile'"
  assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "hostile backup value never reached a command: '$hostile'"
done

# Non-string / non-int values: these guards are the only thing between a JSON null
# and a TypeError that validate_params' `except ValueError` would NOT catch -- it
# would escape to poll_once and surface as "worker hit an internal error", which is
# exactly the symptom the disabled unknown-key check produced. Pin the messages so
# the guards cannot be dropped as redundant.
for bad in 'null' 'true' '6.5' '[]' '{}'; do
  id="$(enqueue backup_schedule_save "{\"settings\": {\"BACKUP_ENABLED\": true, \"BACKUP_INTERVAL_HOURS\": $bad, \"BACKUP_RETENTION_DAYS\": 14, \"BACKUP_KEEP_MIN\": 3}}")"
  jobd --once >/dev/null 2>&1
  assert_eq "$(state_of "$id")" "failed" "a $bad interval is refused"
  assert_contains "$(output_of "$id")" "must be an integer 1-720" \
    "a $bad interval is refused as a number, not as an internal error"
  assert_not_contains "$(output_of "$id")" "internal error" \
    "a $bad interval never escapes as an uncaught TypeError"
done

# PEP-515 underscores and padding are not what a form field posts: int("6_0") is 60,
# so accepting the string shape would silently save an interval nobody asked for.
for bad in '"6_0"' '" 6 "' '"+6"'; do
  id="$(enqueue backup_schedule_save "{\"settings\": {\"BACKUP_ENABLED\": true, \"BACKUP_INTERVAL_HOURS\": $bad, \"BACKUP_RETENTION_DAYS\": 14, \"BACKUP_KEEP_MIN\": 3}}")"
  jobd --once >/dev/null 2>&1
  assert_eq "$(state_of "$id")" "failed" "interval $bad is refused rather than reinterpreted"
done

# The same guard on the archive-name path: a non-string must be refused by name,
# not crash on `"/" in 123`.
id="$(enqueue backup_import '{"staged": 123}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "a non-string staged name is refused"
assert_contains "$(output_of "$id")" "staged must be a bare file name" \
  "a non-string staged name is refused by name, not as an internal error"
assert_not_contains "$(output_of "$id")" "internal error" \
  "a non-string staged name never escapes as an uncaught TypeError"

# the `backup` key shares _validate_archive_in, so pin its separator message too
id="$(enqueue backup_delete '{"backup": "../../etc/passwd", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_contains "$(output_of "$id")" "backup must be a bare file name" \
  "the backup key's separator refusal says what is wrong too"

# a separator is refused as a *separator*, by its own message, before any pattern or
# filesystem reasoning happens
id="$(enqueue backup_import '{"staged": "../../etc/passwd"}')"
jobd --once >/dev/null 2>&1
assert_contains "$(output_of "$id")" "staged must be a bare file name" "the separator refusal says what is wrong"

# --- backup_restore: confirm-gated, exact argv, --wait only when asked -----
: > "$WORK/argv.log"
id="$(enqueue backup_restore "{\"backup\": \"$ARCHIVE\"}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "backup_restore without confirm is refused"
assert_contains "$(output_of "$id")" "requires confirm" "explains the restore refusal"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "unconfirmed restore never reached a command"

: > "$WORK/argv.log"
id="$(enqueue backup_restore "{\"backup\": \"$ARCHIVE\", \"confirm\": true}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "backup_restore succeeds"
assert_eq "$(cat "$WORK/argv.log")" "palworld-restore --restore $ARCHIVE" "backup_restore argv exact, with no --wait"

: > "$WORK/argv.log"
id="$(enqueue backup_restore "{\"backup\": \"$ARCHIVE\", \"wait\": 45, \"confirm\": true}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "backup_restore with a wait succeeds"
assert_eq "$(cat "$WORK/argv.log")" "palworld-restore --restore $ARCHIVE --wait 45" "backup_restore forwards --wait exactly"

# restoring something that has only been uploaded (never promoted) is refused: the
# staging directory is web-writable and the backups directory is not.
printf 'placeholder\n' > "$WORK/uploads/$ARCHIVE2"
rm -f "$WORK/savebackups/$ARCHIVE2"
: > "$WORK/argv.log"
id="$(enqueue backup_restore "{\"backup\": \"$ARCHIVE2\", \"confirm\": true}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "an un-imported upload is not restorable"
assert_contains "$(output_of "$id")" "backup not found in the backups directory" "says which directory it looked in"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "the un-imported upload never reached a command"

# --- backup_delete: confirm-gated, exact argv -----------------------------
: > "$WORK/argv.log"
id="$(enqueue backup_delete "{\"backup\": \"$ARCHIVE\"}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "backup_delete without confirm is refused"
assert_contains "$(output_of "$id")" "requires confirm" "explains the delete refusal"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "unconfirmed delete never reached a command"

: > "$WORK/argv.log"
id="$(enqueue backup_delete "{\"backup\": \"$ARCHIVE\", \"confirm\": true}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "backup_delete succeeds"
assert_eq "$(cat "$WORK/argv.log")" "palworld-backups --delete $ARCHIVE" "backup_delete argv exact"

# a symlink in the backups dir is refused too: palworld-backup chowns each archive
# to the service account, so an entry there is not beyond an attacker's reach.
ln -sf "$WORK/etc/settings.env" "$WORK/savebackups/$ARCHIVE2"
: > "$WORK/argv.log"
id="$(enqueue backup_delete "{\"backup\": \"$ARCHIVE2\", \"confirm\": true}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "a symlinked save archive is refused"
assert_contains "$(output_of "$id")" "backup must not be a symlink" "says why the archive symlink was refused"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "the symlinked archive never reached a command"
rm -f "$WORK/savebackups/$ARCHIVE2"

# --- the two `backup` validators must not have merged --------------------
# validate_backup is engine_rollback's *config*-backup check. Widening it to cover
# save archives (or pointing engine_rollback at the new one) would silently change
# what a rollback accepts, so both directions are pinned. Both files exist, in the
# directory each action reads, so only the name checks can be doing the refusing.
echo "[/script/onlineSubsystemUtils.ipnetdriver]" > "$WORK/backups/Engine.ini.20260726T031500Z"
printf 'placeholder\n' > "$WORK/backups/$ARCHIVE"
: > "$WORK/argv.log"
id="$(enqueue engine_rollback '{"backup": "Engine.ini.20260726T031500Z", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "engine_rollback still accepts an Engine.ini.<stamp> name"
assert_eq "$(cat "$WORK/argv.log")" "palworld-engine-config rollback -- Engine.ini.20260726T031500Z" "and its argv is unchanged"
: > "$WORK/argv.log"
id="$(enqueue engine_rollback "{\"backup\": \"$ARCHIVE\", \"confirm\": true}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "engine_rollback still refuses a save-archive name"
assert_contains "$(output_of "$id")" 'Engine\\.ini' "and refuses it against the Engine.ini pattern"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "a save-archive name never reached a rollback"
# the reverse: an Engine.ini backup is not a world save, even though one exists in
# the config-backup dir under that exact name
printf 'placeholder\n' > "$WORK/savebackups/Engine.ini.20260726T031500Z"
: > "$WORK/argv.log"
id="$(enqueue backup_delete '{"backup": "Engine.ini.20260726T031500Z", "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "backup_delete refuses a config-backup name"
assert_contains "$(output_of "$id")" "palworld-save-" "and refuses it against the save-archive pattern"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "a config-backup name never reached palworld-backups"
rm -f "$WORK/savebackups/Engine.ini.20260726T031500Z"

# --- backup_schedule_save: writes the four keys, and only those ------------
SCHED_OK='{"settings": {"BACKUP_ENABLED": true, "BACKUP_INTERVAL_HOURS": 6, "BACKUP_RETENTION_DAYS": 30, "BACKUP_KEEP_MIN": 5}}'
: > "$WORK/argv.log"
id="$(enqueue backup_schedule_save "$SCHED_OK")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "backup_schedule_save succeeds"
assert_contains "$(output_of "$id")" "wrote the backup schedule" "says the schedule was written"
assert_file_contains "$WORK/etc/backup.env" "BACKUP_ENABLED=true" "wrote the enabled flag"
assert_file_contains "$WORK/etc/backup.env" "BACKUP_INTERVAL_HOURS=6" "wrote the interval"
assert_file_contains "$WORK/etc/backup.env" "BACKUP_RETENTION_DAYS=30" "wrote the retention"
assert_file_contains "$WORK/etc/backup.env" "BACKUP_KEEP_MIN=5" "wrote the keep-min floor"
assert_file_contains "$WORK/etc/backup.env" "# Generated by palwarden-jobd (backup_schedule_save)" "marks the file as generated"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "the schedule action runs no command at all"
assert_eq "$(stat -c '%a' "$WORK/etc/backup.env")" "644" "the schedule file is 0644"
# no temp file left behind, and none at a guessable fixed name
if ls "$WORK/etc"/backup.env.tmp* >/dev/null 2>&1; then fail "a temp schedule file was left behind"; else pass; fi

# false is a value, not an absence: the disabled state has to survive a save
id="$(enqueue backup_schedule_save '{"settings": {"BACKUP_ENABLED": false, "BACKUP_INTERVAL_HOURS": 6, "BACKUP_RETENTION_DAYS": 30, "BACKUP_KEEP_MIN": 5}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "disabling scheduled backups succeeds"
assert_file_contains "$WORK/etc/backup.env" "BACKUP_ENABLED=false" "wrote the disabled flag"

# ...and the file we wrote is one palworld-backups actually reads back, with no
# warnings: the two sides parse the same file, so a format only one of them accepts
# would be a schedule silently replaced by defaults on the next tick.
id="$(enqueue backup_schedule_save "$SCHED_OK")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "re-saving the schedule succeeds"
sched_json="$(PALWORLD_BACKUP_SCHEDULE="$WORK/etc/backup.env" PYTHONPATH="$LIB" \
  python3 "$DIR/../../sbin/palworld-backups" --show-schedule 2>"$WORK/sched.err")"
assert_contains "$sched_json" '"BACKUP_INTERVAL_HOURS": 6' "palworld-backups reads back the interval we wrote"
assert_contains "$sched_json" '"BACKUP_RETENTION_DAYS": 30' "palworld-backups reads back the retention we wrote"
assert_contains "$sched_json" '"BACKUP_KEEP_MIN": 5' "palworld-backups reads back the keep-min we wrote"
assert_contains "$sched_json" '"BACKUP_ENABLED": true' "palworld-backups reads back the enabled flag we wrote"
assert_eq "$(wc -c < "$WORK/sched.err" | tr -d ' ')" "0" "and parses it without a single warning"

# an unknown key is refused BY NAME, not dropped
id="$(enqueue backup_schedule_save '{"settings": {"BACKUP_ENABLED": true, "BACKUP_INTERVAL_HOURS": 6, "BACKUP_RETENTION_DAYS": 30, "BACKUP_KEEP_MIN": 5, "BACKUP_INTERVAL_HOUR": 9}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "an unknown schedule key is refused"
assert_contains "$(output_of "$id")" "unknown backup schedule setting: 'BACKUP_INTERVAL_HOUR'" "the refusal names the unknown key"
assert_file_not_contains "$WORK/etc/backup.env" "BACKUP_INTERVAL_HOURS=9" "and nothing was written"

# an *engine* key is not a schedule key: the schedule form must not be a second
# door to engine.env's table
id="$(enqueue backup_schedule_save '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "an engine setting is refused by the schedule action"
assert_contains "$(output_of "$id")" "unknown backup schedule setting: 'NET_SERVER_MAX_TICK_RATE'" "names the engine key as unknown here"

# a partial save is refused: the writer replaces the file, so a missing key would
# silently revert to palworld-backups' default
id="$(enqueue backup_schedule_save '{"settings": {"BACKUP_INTERVAL_HOURS": 6}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "a partial schedule save is refused"
assert_contains "$(output_of "$id")" "must be saved whole" "explains that the schedule is saved whole"
assert_contains "$(output_of "$id")" "'BACKUP_KEEP_MIN'" "and names a key that was missing"

# BACKUP_ENABLED takes a real boolean only, exactly like confirm
for bad in '"true"' '1' 'null'; do
  id="$(enqueue backup_schedule_save "{\"settings\": {\"BACKUP_ENABLED\": $bad, \"BACKUP_INTERVAL_HOURS\": 6, \"BACKUP_RETENTION_DAYS\": 30, \"BACKUP_KEEP_MIN\": 5}}")"
  jobd --once >/dev/null 2>&1
  assert_eq "$(state_of "$id")" "failed" "BACKUP_ENABLED: $bad is refused"
  assert_contains "$(output_of "$id")" "BACKUP_ENABLED must be a boolean" "explains the BACKUP_ENABLED refusal for $bad"
done

# every range bound: accepted at both ends, refused one step outside either
sched_with() {  # sched_with <key> <value>
  python3 -c "
import json, sys
s = {'BACKUP_ENABLED': True, 'BACKUP_INTERVAL_HOURS': 6,
     'BACKUP_RETENTION_DAYS': 30, 'BACKUP_KEEP_MIN': 5}
s[sys.argv[1]] = json.loads(sys.argv[2])
print(json.dumps({'settings': s}))" "$1" "$2"
}
while read -r key low high; do
  for good in "$low" "$high"; do
    id="$(enqueue backup_schedule_save "$(sched_with "$key" "$good")")"
    jobd --once >/dev/null 2>&1
    assert_eq "$(state_of "$id")" "succeeded" "$key=$good (a bound) is accepted"
    assert_file_contains "$WORK/etc/backup.env" "$key=$good" "$key=$good was written"
  done
  for bad in "$((low - 1))" "$((high + 1))"; do
    id="$(enqueue backup_schedule_save "$(sched_with "$key" "$bad")")"
    jobd --once >/dev/null 2>&1
    assert_eq "$(state_of "$id")" "failed" "$key=$bad (outside the range) is refused"
    assert_contains "$(output_of "$id")" "$key must be an integer $low-$high" "names $key's range"
    assert_file_not_contains "$WORK/etc/backup.env" "$key=$bad" "$key=$bad was never written"
  done
  # a non-integer is refused too, and it is the *value* that is named
  id="$(enqueue backup_schedule_save "$(sched_with "$key" '"lots"')")"
  jobd --once >/dev/null 2>&1
  assert_eq "$(state_of "$id")" "failed" "$key='lots' is refused"
  assert_contains "$(output_of "$id")" "$key must be an integer" "explains the $key type refusal"
done <<'EOF'
BACKUP_INTERVAL_HOURS 1 720
BACKUP_RETENTION_DAYS 1 3650
BACKUP_KEEP_MIN 1 100
EOF

# the ranges jobd enforces are the ranges palworld-backups repairs against. If they
# diverged, the panel would accept a value the next tick silently replaced with a
# default — invisible until someone needed a backup that was never taken.
tables="$(PYTHONPATH="$LIB" python3 - "$JOBD" "$DIR/../../sbin/palworld-backups" <<'EOF'
import importlib.machinery, importlib.util, sys

def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    loader.exec_module(mod)
    return mod

jobd = load("jobd_under_test", sys.argv[1])
backups = load("backups_under_test", sys.argv[2])
if jobd.SCHEDULE_RANGES != backups.RANGES:
    print(f"FAIL ranges: {jobd.SCHEDULE_RANGES} != {backups.RANGES}")
elif set(jobd.SCHEDULE_KEYS) != set(backups.DEFAULTS):
    print(f"FAIL keys: {sorted(jobd.SCHEDULE_KEYS)} != {sorted(backups.DEFAULTS)}")
else:
    print("agree")
EOF
)"
assert_eq "$tables" "agree" "jobd's schedule table matches palworld-backups' own"

# --- a failed schedule write leaves the previous schedule intact ----------
# Root ignores mode 0500, so this needs a non-root uid; same divergence as the
# engine.env case above.
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP: unwritable-schedule check needs a non-root uid (root ignores mode 0500)"
else
  mkdir -p "$WORK/roschedule"
  id="$(enqueue backup_schedule_save "$SCHED_OK")"
  SCHEDULE_OVERRIDE="$WORK/roschedule/backup.env" jobd --once >/dev/null 2>&1
  assert_eq "$(state_of "$id")" "succeeded" "the schedule saves into a writable directory"
  assert_file_contains "$WORK/roschedule/backup.env" "BACKUP_INTERVAL_HOURS=6" "the first schedule landed"
  chmod 0500 "$WORK/roschedule"
  id="$(enqueue backup_schedule_save '{"settings": {"BACKUP_ENABLED": false, "BACKUP_INTERVAL_HOURS": 12, "BACKUP_RETENTION_DAYS": 7, "BACKUP_KEEP_MIN": 2}}')"
  SCHEDULE_OVERRIDE="$WORK/roschedule/backup.env" jobd --once >/dev/null 2>&1
  chmod 0700 "$WORK/roschedule"
  assert_eq "$(state_of "$id")" "failed" "an unwritable schedule directory fails the job"
  assert_contains "$(output_of "$id")" "backup_schedule_save failed" "says which step failed"
  assert_file_contains "$WORK/roschedule/backup.env" "BACKUP_INTERVAL_HOURS=6" "the previous schedule is intact"
  assert_file_not_contains "$WORK/roschedule/backup.env" "BACKUP_INTERVAL_HOURS=12" "and the failed save left nothing behind"
fi

# --- the new actions take no parameters they do not use -------------------
: > "$WORK/argv.log"
id="$(enqueue backup_import "{\"staged\": \"$ARCHIVE\", \"wait\": 30}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "backup_import does not take a wait"
assert_contains "$(output_of "$id")" "it takes: staged" "and says what it does take"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "the over-specified import never ran"
: > "$WORK/argv.log"
id="$(enqueue backup_delete "{\"backup\": \"$ARCHIVE\", \"wait\": 30, \"confirm\": true}")"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "backup_delete does not take a wait"
assert_contains "$(output_of "$id")" "it takes: backup, confirm" "and lists backup and confirm only"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "the over-specified delete never ran"

# --- settings_save: the PalWorldSettings twin of engine_save ---------------
# Validation is against the live config's own shapes (the fixture file), via
# palworld-config-parser's resolver/renderer — the same code config_apply runs.
OVERRIDES="$WORK/etc/settings-overrides.env"
rm -f "$OVERRIDES"
: > "$WORK/argv.log"
id="$(enqueue settings_save '{"settings": {"ExpRate": 2, "ServerName": "My Server", "bIsPvP": "True"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "settings_save succeeds"
assert_file_contains "$OVERRIDES" 'ExpRate="2"' "wrote the numeric setting"
assert_file_contains "$OVERRIDES" 'ServerName="My Server"' "wrote the quoted string setting"
assert_file_contains "$OVERRIDES" 'bIsPvP="True"' "wrote the boolean setting"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "settings_save is file-only; no command ran"

# env-style names resolve exactly like config_apply resolves them
id="$(enqueue settings_save '{"settings": {"EXP_RATE": "3", "IS_PVP": "False"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "env-style names accepted"
assert_file_contains "$OVERRIDES" 'ExpRate="3"' "EXP_RATE resolved to the canonical INI key and merged"
assert_file_contains "$OVERRIDES" 'bIsPvP="False"' "IS_PVP resolved through the b-prefix rule"
assert_file_contains "$OVERRIDES" 'ServerName="My Server"' "unsubmitted key preserved by the merge"

# refusals: each one is told at the form, not silently dropped at apply time
id="$(enqueue settings_save '{"settings": {"NotAPalworldKey": "1"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "unknown game setting rejected"
assert_contains "$(output_of "$id")" "no matching Palworld setting" "explains the unknown key"

id="$(enqueue settings_save '{"settings": {"AdminPassword": "hunter2"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "AdminPassword refused"
assert_contains "$(output_of "$id")" "settings.env" "points at the right mechanism"
assert_file_not_contains "$OVERRIDES" "hunter2" "the refused secret never landed in the file"

id="$(enqueue settings_save '{"settings": {"SERVER_PASSWORD": "hunter2"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "ServerPassword refused under its env-style alias too"

# the REST API keys are the control plane's own lifeline: a saved
# RESTAPIEnabled=False would ride the overrides file and win over settings.env
# on every boot, permanently cutting off telemetry/graceful-stop/updates
id="$(enqueue settings_save '{"settings": {"RESTAPIEnabled": "False"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "RESTAPIEnabled refused"
assert_contains "$(output_of "$id")" "control plane" "explains why REST cannot be changed here"
id="$(enqueue settings_save '{"settings": {"REST_API_PORT": "9999"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "RESTAPIPort refused under its env-style alias too"
assert_file_not_contains "$OVERRIDES" "RESTAPI" "no REST key ever lands in the overrides file"

id="$(enqueue settings_save '{"settings": {"ExpRate": "not-a-number"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "value that does not fit the live shape rejected"

id="$(enqueue settings_save '{"settings": {"CrossplayPlatforms": "Steam"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "tuple-valued setting rejected"

id="$(enqueue settings_save '{"settings": {"bIsPvP": true}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "JSON boolean value rejected (send the string)"

id="$(enqueue settings_save '{"settings": {"ExpRate": "4", "EXP_RATE": "5"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "two aliases of one key in a single request refused"

id="$(enqueue settings_save '{"settings": {}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "empty settings object refused"

# a quote in a string value round-trips through the always-quoted env format
id="$(enqueue settings_save '{"settings": {"ServerDescription": "say \"hi\" (PvE)"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "string with quotes and parens accepted"
assert_file_contains "$OVERRIDES" 'ServerDescription="say \"hi\" (PvE)"' "quotes escaped in the env file"

# --- settings_save_apply_restart: write, then apply, then restart ----------
: > "$WORK/argv.log"
id="$(enqueue settings_save_apply_restart '{"settings": {"ExpRate": "5"}, "wait": 30, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "settings_save_apply_restart succeeds"
assert_file_contains "$OVERRIDES" 'ExpRate="5"' "composite wrote the overrides file"
assert_file_contains "$WORK/argv.log" "palworld-graceful-restart --apply-config --wait 30" \
  "then restarted with the apply inside the stop window and the wait"
assert_file_not_contains "$WORK/argv.log" "palworld-config-apply-env" \
  "no separate apply argv before the restart (it would race the game's exit write)"

# the composite is disruptive: no confirm, no run
id="$(enqueue settings_save_apply_restart '{"settings": {"ExpRate": "5"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "settings_save_apply_restart requires confirm"

# an unreadable live config refuses the save with a reason, exactly as the
# later apply would have failed — but at the form instead of after a restart
: > "$WORK/argv.log"
id="$(enqueue settings_save_apply_restart '{"settings": {"ExpRate": "6"}, "confirm": true}')"
CONFIG_FILE_OVERRIDE="$WORK/no-such-config.ini" jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "missing live config refuses the save"
assert_contains "$(output_of "$id")" "cannot read" "explains why"
assert_eq "$(wc -c < "$WORK/argv.log" | tr -d ' ')" "0" "no apply or restart after a refused save"

assert_report
