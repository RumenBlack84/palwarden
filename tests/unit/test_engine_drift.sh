#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Drift detection for Engine.ini (`palworld-engine-config status --check`).
#
# Hardened against what a real-server test showed the game actually does: it
# rewrites Engine.ini, reformatting values (True/1, 60.000000/60) and appending
# its own Unreal sections. None of that is drift — only a genuine value change is.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
ENGINE="$DIR/../../sbin/palworld-engine-config"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/backups"

ENV_FILE="$WORK/engine.env"
INI="$WORK/Engine.ini"
PRETTY="$WORK/Engine.pretty.ini"
# The managed owner is now applied with fchown, which needs a real uid/gid: point
# it at whoever runs the suite so the ownership path is genuinely exercised rather
# than skipped on a host with no palworld user.
PALWORLD_USER="$(id -un)"; PALWORLD_GROUP="$(id -gn)"
export PALWORLD_USER PALWORLD_GROUP

check() {
  PALWORLD_ENGINE_INI="$INI" PALWORLD_ENGINE_ENV="$ENV_FILE" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$PRETTY" \
  PALWORLD_FPS_BIN=/bin/true \
    python3 "$ENGINE" status --check 2>&1
}

cat > "$ENV_FILE" <<'EOF'
NET_SERVER_MAX_TICK_RATE=60
CONNECTION_TIMEOUT=60
ASYNC_LOADING_THREAD_ENABLED=true
EOF

# --- matching values pass, in the exact form our own apply writes -----------
cat > "$INI" <<'EOF'
[/Script/OnlineSubsystemUtils.IpNetDriver]
NetServerMaxTickRate=60
ConnectionTimeout=60
[/Script/Engine.StreamingSettings]
s.AsyncLoadingThreadEnabled=1
EOF
out="$(check)"; rc=$?
assert_eq "$rc" "0" "matching config reports no drift"
assert_contains "$out" "OK" "reports OK"

# --- the game's own formatting must NOT read as drift ------------------------
# Floats gain trailing zeros and bools become True/False when Unreal rewrites.
cat > "$INI" <<'EOF'
[/Script/OnlineSubsystemUtils.IpNetDriver]
NetServerMaxTickRate=60
ConnectionTimeout=60.000000
[/Script/Engine.StreamingSettings]
s.AsyncLoadingThreadEnabled=True
EOF
out="$(check)"; rc=$?
assert_eq "$rc" "0" "reformatted values (60.000000 / True) are not drift"
assert_not_contains "$out" "FAILED" "no false drift from reformatting"

# --- extra Unreal sections/keys are ignored ---------------------------------
cat >> "$INI" <<'EOF'
[Core.System]
Paths=../../../Engine/Content
Paths=%GAMEDIR%Content
[/Script/Engine.RendererSettings]
r.SomethingElse=1
EOF
out="$(check)"; rc=$?
assert_eq "$rc" "0" "the game's extra sections are not drift"

# --- a genuine value change IS drift ---------------------------------------
cat > "$INI" <<'EOF'
[/Script/OnlineSubsystemUtils.IpNetDriver]
NetServerMaxTickRate=30
ConnectionTimeout=60
[/Script/Engine.StreamingSettings]
s.AsyncLoadingThreadEnabled=1
EOF
out="$(check)"; rc=$?
assert_ne "$rc" "0" "a real value change exits nonzero"
assert_contains "$out" "NET_SERVER_MAX_TICK_RATE" "names the drifted setting"
assert_contains "$out" "30" "shows the actual value"

# --- a value the game wrote in a form we cannot parse is reported, not fatal --
cat > "$INI" <<'EOF'
[/Script/OnlineSubsystemUtils.IpNetDriver]
NetServerMaxTickRate=banana
ConnectionTimeout=60
[/Script/Engine.StreamingSettings]
s.AsyncLoadingThreadEnabled=1
EOF
out="$(check)"; rc=$?
assert_ne "$rc" "0" "unparseable value exits nonzero"
assert_not_contains "$out" "Traceback" "unparseable value does not crash"
assert_contains "$out" "NET_SERVER_MAX_TICK_RATE" "names the unparseable setting"

# --- a reset/blank config is called out clearly -----------------------------
# Unreal truncates a config holding only defaults to a single newline; operators
# need to know that is what happened rather than reading a wall of "Missing".
printf '\n' > "$INI"
out="$(check)"; rc=$?
assert_ne "$rc" "0" "blank config exits nonzero"
assert_not_contains "$out" "Traceback" "blank config does not crash"
assert_contains "$out" "no managed values" "blank config gets a specific message"

# --- a missing config file is handled too ----------------------------------
rm -f "$INI"
out="$(check)"; rc=$?
assert_ne "$rc" "0" "missing config exits nonzero"
assert_not_contains "$out" "Traceback" "missing config does not crash"

# --- duplicate managed key with conflicting values is flagged --------------
# The game appends its own sections; if a managed key ends up defined twice with
# different values, silently taking the last one would hide a real problem.
cat > "$INI" <<'EOF'
[/Script/OnlineSubsystemUtils.IpNetDriver]
NetServerMaxTickRate=60
ConnectionTimeout=60
[/Script/Engine.StreamingSettings]
s.AsyncLoadingThreadEnabled=1
[/Script/OnlineSubsystemUtils.IpNetDriver]
NetServerMaxTickRate=30
EOF
out="$(check)"; rc=$?
assert_ne "$rc" "0" "conflicting duplicate exits nonzero"
assert_contains "$out" "NET_SERVER_MAX_TICK_RATE" "names the conflicting setting"
assert_contains "$out" "more than once" "explains the duplicate"

# --- rollback: real backups only, and never through a symlink ---------------
# The backup directory is writable by the unprivileged web user while this tool
# runs as root, so a symlink planted there must not be copied over Engine.ini
# (which then gets chmod 0644). The name check alone cannot close that — the
# entry can be swapped between check and open — so the read uses O_NOFOLLOW.
rollback() {
  PALWORLD_ENGINE_INI="$INI" PALWORLD_ENGINE_ENV="$ENV_FILE" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$PRETTY" \
  PALWORLD_FPS_BIN=/bin/true \
    python3 "$ENGINE" rollback "$@" 2>&1
}

printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=42\n' \
  > "$WORK/backups/Engine.ini.20260710T182037Z"
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=60\n' > "$INI"
out="$(rollback -- Engine.ini.20260710T182037Z)"; rc=$?
assert_eq "$rc" "0" "a legitimate regular-file backup rolls back"
assert_contains "$out" "Restored" "reports the restore"
assert_file_contains "$INI" "NetServerMaxTickRate=42" "restored the backup's contents"

# --list must keep working (it lists names, it does not open anything)
out="$(rollback --list)"
assert_contains "$out" "Engine.ini.20260710T182037Z" "--list still lists backups"

# a symlink to a 0600 secret outside the backup dir must be refused, and must
# leave Engine.ini untouched
printf 'ADMIN_PASSWORD=hunter2\n' > "$WORK/secret.env"
chmod 0600 "$WORK/secret.env"
ln -sf "$WORK/secret.env" "$WORK/backups/Engine.ini.20260101T000000Z"
out="$(rollback -- Engine.ini.20260101T000000Z)"; rc=$?
assert_ne "$rc" "0" "a symlinked backup is refused"
assert_contains "$out" "symlink" "says why the symlink was refused"
assert_not_contains "$out" "Traceback" "the refusal is a message, not a crash"
assert_file_not_contains "$INI" "ADMIN_PASSWORD" "the secret never reached Engine.ini"
assert_file_contains "$INI" "NetServerMaxTickRate=42" "Engine.ini left as it was"

# --dry-run opens nothing, so resolve_backup's lstat pre-flight is the only guard
# on that path: it must still refuse, rather than printing "Would restore".
out="$(rollback --dry-run -- Engine.ini.20260101T000000Z)"; rc=$?
assert_ne "$rc" "0" "a symlinked backup is refused on the --dry-run path too"
assert_contains "$out" "backup must not be a symlink" "dry-run names the refusal"
assert_not_contains "$out" "Would restore" "dry-run does not offer to restore a symlink"

# the same refusal must come from the *open*, not only the pre-flight check:
# call rollback_engine directly with the check monkey-patched away, standing in
# for the entry being swapped after validation by a separate process.
raced="$(PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_FPS_BIN=/bin/true python3 - "$ENGINE" "$WORK" <<'EOF' 2>&1
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("engine_cfg", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod  # dataclasses needs the module registered
loader.exec_module(mod)
work = Path(sys.argv[2])
name = "Engine.ini.20260101T000000Z"
# pretend validation already passed: the symlink appeared afterwards
mod.resolve_backup = lambda n, d: d / n
try:
    mod.rollback_engine(name, work / "Engine.ini", work / "backups",
                        work / "Engine.pretty.ini", save_current=False)
    print("COPIED")
except ValueError as exc:
    print("REFUSED:", exc)
EOF
)"
assert_contains "$raced" "REFUSED" "O_NOFOLLOW refuses a link swapped in after validation"
assert_file_not_contains "$INI" "ADMIN_PASSWORD" "the raced swap still published nothing"

# --- apply: writes INTO the backup dir must not follow a planted symlink -----
# The same hole in the other direction, reachable as the engine_apply /
# engine_save_apply_restart jobd actions: the backup name is `Engine.ini.<UTC
# stamp>` at second resolution, so the web user can pre-plant links at the next
# few stamps and redirect root's write onto a file of its choosing.
apply_cfg() {
  PALWORLD_ENGINE_INI="$INI" PALWORLD_ENGINE_ENV="$ENV_FILE" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$PRETTY" \
  PALWORLD_FPS_BIN=/bin/true \
    python3 "$ENGINE" apply 2>&1
}

# a normal apply still works, and still leaves a real backup behind
rm -f "$WORK/backups"/Engine.ini.* "$WORK/backups"/notabackup
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=30\n' > "$INI"
out="$(apply_cfg)"; rc=$?
assert_eq "$rc" "0" "a normal apply still succeeds"
assert_file_contains "$INI" "NetServerMaxTickRate=60" "apply wrote the managed value"
backup_count="$(find "$WORK/backups" -maxdepth 1 -name 'Engine.ini.*' -type f | wc -l | tr -d ' ')"
assert_eq "$backup_count" "1" "apply left exactly one real backup file"

# now pre-plant symlinks at the next few stamps and prove the write is refused
printf 'ROOT_ONLY_SECRET_CONTENT\n' > "$WORK/victim"
chmod 0600 "$WORK/victim"
for i in 0 1 2 3 4 5; do
  ln -sf "$WORK/victim" "$WORK/backups/Engine.ini.$(date -u -d "+$i seconds" +%Y%m%dT%H%M%SZ)"
done
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=30\n' > "$INI"
out="$(apply_cfg)"; rc=$?
assert_ne "$rc" "0" "apply refuses to write its backup through a planted symlink"
assert_contains "$out" "Cannot write backup" "explains which write it refused"
assert_not_contains "$out" "Traceback" "the refusal is a message, not a crash"
assert_file_not_contains "$WORK/victim" "NetServerMaxTickRate" "root's write never reached the victim"
assert_file_contains "$WORK/victim" "ROOT_ONLY_SECRET_CONTENT" "the victim is untouched"
assert_eq "$(stat -c %a "$WORK/victim")" "600" "the victim's mode is untouched"
# refusing the backup must abort the apply: never edit Engine.ini with no backup
assert_file_contains "$INI" "NetServerMaxTickRate=30" "Engine.ini left alone when the backup failed"

# --- the CONFIG directory is untrusted too, and needs no race ----------------
# Engine.ini and Engine.pretty.ini live in a directory the unprivileged game/web
# user owns and must be able to write (the game rewrites Engine.ini itself). So it
# can simply replace one of those names with a symlink: root then writes through
# it, chmods 0644 and chowns to that user. No timing involved. Every write to
# these names is O_NOFOLLOW, with the owner/mode set on that same descriptor.
rm -f "$WORK/backups"/Engine.ini.*

plant_victim() {  # a root-only file outside the config directory
  printf 'ROOT_ONLY_SECRET_CONTENT\n' > "$WORK/victim"
  chmod 0600 "$WORK/victim"
}
assert_victim_untouched() {  # $1 = context
  assert_file_contains "$WORK/victim" "ROOT_ONLY_SECRET_CONTENT" "$1: victim content unchanged"
  assert_file_not_contains "$WORK/victim" "Human-readable reference copy" "$1: no pretty header written into the victim"
  assert_file_not_contains "$WORK/victim" "NetServerMaxTickRate" "$1: no managed key written into the victim"
  assert_eq "$(stat -c %a "$WORK/victim")" "600" "$1: victim mode still 0600"
  assert_eq "$(stat -c %U "$WORK/victim")" "$(id -un)" "$1: victim owner unchanged"
}

# apply, with the PRETTY destination symlinked at the victim
plant_victim
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=30\n' > "$INI"
rm -f "$PRETTY"; ln -s "$WORK/victim" "$PRETTY"
out="$(apply_cfg)"; rc=$?
assert_ne "$rc" "0" "apply refuses a symlinked Engine.pretty.ini"
assert_contains "$out" "must not be a symlink" "the pretty refusal says it is a symlink"
assert_contains "$out" "Engine.pretty.ini" "the pretty refusal names the file"
assert_not_contains "$out" "Too many levels" "the refusal is not raw ELOOP strerror"
assert_not_contains "$out" "Traceback" "the refusal is a message, not a crash"
assert_victim_untouched "pretty via apply"
rm -f "$PRETTY"

# apply, with ENGINE.INI itself symlinked at the victim
plant_victim
rm -f "$INI"; ln -s "$WORK/victim" "$INI"
out="$(apply_cfg)"; rc=$?
assert_ne "$rc" "0" "apply refuses a symlinked Engine.ini"
assert_contains "$out" "Engine.ini must not be a symlink" "the Engine.ini refusal is explicit"
assert_not_contains "$out" "Traceback" "the Engine.ini refusal is a message, not a crash"
assert_victim_untouched "Engine.ini via apply"
rm -f "$INI"

# rollback, with Engine.ini symlinked at the victim: refused before the backup's
# bytes (or root's chown/chmod) reach it
plant_victim
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=42\n' \
  > "$WORK/backups/Engine.ini.20260710T182037Z"
ln -s "$WORK/victim" "$INI"
out="$(rollback -- Engine.ini.20260710T182037Z)"; rc=$?
assert_ne "$rc" "0" "rollback refuses a symlinked Engine.ini"
assert_contains "$out" "Engine.ini must not be a symlink" "the rollback refusal is explicit"
assert_not_contains "$out" "Traceback" "the rollback refusal is a message, not a crash"
assert_file_not_contains "$WORK/victim" "NetServerMaxTickRate" "the backup's bytes never reached the victim"
assert_victim_untouched "Engine.ini via rollback"
rm -f "$INI"

# ...and the refusal must come from the *destination* open, not only from the
# pre-rollback read of the current Engine.ini: with save_current=False that read
# never happens, and the O_NOFOLLOW on the write is the only thing left.
plant_victim
ln -s "$WORK/victim" "$INI"
raced="$(PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_FPS_BIN=/bin/true python3 - "$ENGINE" "$WORK" <<'EOF' 2>&1
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("engine_cfg", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod  # dataclasses needs the module registered
loader.exec_module(mod)
work = Path(sys.argv[2])
try:
    mod.rollback_engine("Engine.ini.20260710T182037Z", work / "Engine.ini",
                        work / "backups", work / "Engine.pretty.ini",
                        save_current=False)
    print("WROTE")
except ValueError as exc:
    print("REFUSED:", exc)
EOF
)"
assert_contains "$raced" "REFUSED" "the Engine.ini write itself refuses the symlink"
assert_victim_untouched "Engine.ini write with save_current=False"
rm -f "$INI"

# --- a legitimate apply/rollback still lands owned and moded as before -------
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=30\n' > "$INI"
rm -f "$WORK/backups"/Engine.ini.*
out="$(apply_cfg)"; rc=$?
assert_eq "$rc" "0" "a legitimate apply succeeds after the hardening"
assert_file_contains "$INI" "NetServerMaxTickRate=60" "apply still wrote the managed value"
assert_file_contains "$PRETTY" "Human-readable reference copy" "apply still wrote the pretty copy"
assert_eq "$(stat -c %a "$INI")" "644" "Engine.ini is 0644"
assert_eq "$(stat -c %a "$PRETTY")" "644" "Engine.pretty.ini is 0644"
assert_eq "$(stat -c %U:%G "$PRETTY")" "$(id -un):$(id -gn)" "pretty copy owned by PALWORLD_USER:PALWORLD_GROUP"
backup_name="$(find "$WORK/backups" -maxdepth 1 -name 'Engine.ini.*' -type f -printf '%f\n')"
assert_eq "$(stat -c %a "$WORK/backups/$backup_name")" "644" "the backup is 0644"
assert_eq "$(stat -c %U:%G "$WORK/backups/$backup_name")" "$(id -un):$(id -gn)" "the backup is owned by PALWORLD_USER:PALWORLD_GROUP"

# an unknown owner is a configuration error, reported rather than swallowed —
# and it must not cost the operator the apply itself
# (a subshell, not a `VAR=x func` prefix: bash leaks those into the caller)
out="$(export PALWORLD_USER=definitely-no-such-user; apply_cfg)"; rc=$?
assert_eq "$rc" "0" "an unknown PALWORLD_USER does not fail the apply"
assert_contains "$out" "definitely-no-such-user" "names the owner it could not resolve"

# --- two applies in the same UTC second must BOTH succeed --------------------
# The stamp is second-resolution, so a double-clicked Apply (or a retried
# engine_save_apply_restart) lands two backups in one second. O_EXCL|O_NOFOLLOW is
# still on every attempt; only the *name* gives way, with a `-N` suffix.
same_second=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  rm -f "$WORK/backups"/Engine.ini.*
  printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=30\n' > "$INI"
  start="$(date -u +%Y%m%dT%H%M%SZ)"
  apply_cfg >/dev/null; rc1=$?
  out2="$(apply_cfg)"; rc2=$?
  end="$(date -u +%Y%m%dT%H%M%SZ)"
  if [ "$start" = "$end" ]; then same_second=1; break; fi
done
if [ "$same_second" = "1" ]; then
  assert_eq "$rc1" "0" "first apply in the second succeeds"
  assert_eq "$rc2" "0" "second apply in the SAME second also succeeds"
  assert_not_contains "$out2" "File exists" "no EEXIST failure on a same-second collision"
  assert_contains "$out2" "Backup: $WORK/backups/Engine.ini.$start-1" "the colliding backup got the -1 suffix"
  assert_eq "$(find "$WORK/backups" -maxdepth 1 -name 'Engine.ini.*' -type f | wc -l | tr -d ' ')" "2" "both backups are on disk"
else
  fail "could not get two applies into one UTC second after 10 tries"
fi

# --- FIFOs at the managed paths must not hang root (denial of service) ------
# O_NOFOLLOW refuses a symlink but says nothing about a FIFO: without
# O_NONBLOCK, opening one for read or write blocks until the other end shows
# up, wedging root's single job worker for the full subprocess timeout (30
# minutes in jobd). `timeout` wraps every one of these: a regression here
# should fail in a few seconds, not hang the whole suite.
rm -f "$WORK/backups"/Engine.ini.*
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=30\n' > "$INI"
rm -f "$PRETTY"; mkfifo "$PRETTY"
out="$(timeout 5 env \
  PALWORLD_ENGINE_INI="$INI" PALWORLD_ENGINE_ENV="$ENV_FILE" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$PRETTY" \
  PALWORLD_FPS_BIN=/bin/true python3 "$ENGINE" apply 2>&1)"; rc=$?
assert_ne "$rc" "0" "a FIFO at Engine.pretty.ini is refused, not followed"
assert_ne "$rc" "124" "the FIFO refusal happens well before the timeout fires"
assert_contains "$out" "Engine.pretty.ini" "the FIFO refusal names the file"
assert_contains "$out" "regular file" "the FIFO refusal says it is not a regular file"
assert_not_contains "$out" "Traceback" "the FIFO refusal is a message, not a crash"
rm -f "$PRETTY"

rm -f "$INI"; mkfifo "$INI"
out="$(timeout 5 env \
  PALWORLD_ENGINE_INI="$INI" PALWORLD_ENGINE_ENV="$ENV_FILE" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$PRETTY" \
  PALWORLD_FPS_BIN=/bin/true python3 "$ENGINE" apply 2>&1)"; rc=$?
assert_ne "$rc" "0" "a FIFO at Engine.ini is refused, not followed"
assert_ne "$rc" "124" "the FIFO refusal happens well before the timeout fires"
assert_contains "$out" "Engine.ini" "the FIFO refusal names the file"
assert_not_contains "$out" "Traceback" "the FIFO refusal is a message, not a crash"
rm -f "$INI"

# --- the Engine.pretty.ini FIFO, but with a reader already attached --------
# With no reader, O_NONBLOCK|O_WRONLY fails at open() with ENXIO before fstat
# ever runs. If the attacker keeps a reader attached instead, the open
# succeeds and it is the fstat/S_ISREG rejection that has to catch it —
# exercise that path explicitly, not just the ENXIO one.
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=30\n' > "$INI"
rm -f "$PRETTY"; mkfifo "$PRETTY"
( timeout 8 cat "$PRETTY" >/dev/null & )
sleep 0.3
out="$(timeout 5 env \
  PALWORLD_ENGINE_INI="$INI" PALWORLD_ENGINE_ENV="$ENV_FILE" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$PRETTY" \
  PALWORLD_FPS_BIN=/bin/true python3 "$ENGINE" apply 2>&1)"; rc=$?
assert_ne "$rc" "0" "a FIFO at Engine.pretty.ini with a reader attached is still refused"
assert_ne "$rc" "124" "the refusal with a reader attached happens well before the timeout fires"
assert_contains "$out" "Engine.pretty.ini" "the refusal names the file even with a reader attached"
assert_contains "$out" "regular file" "the refusal (via fstat, not ENXIO) says it is not a regular file"
assert_not_contains "$out" "Traceback" "the refusal is a message, not a crash"
wait
rm -f "$PRETTY"

# --- a partial apply still leaves an audit trail -----------------------------
# The pretty-write refusal above happens *after* Engine.ini was already
# rewritten. The operator must be told the primary change stands, and the
# audit trail (notify/mark_event) must still fire for the change that actually
# happened — otherwise jobd records a failed job with no evidence at all of
# what landed on Engine.ini. Uses the real palworld-fps (as
# test_service_events.sh does) against a private DB so the marker can be read
# back, rather than the /bin/true stub used everywhere else in this file.
FPS="$DIR/../../sbin/palworld-fps"
METRICS_DB="$WORK/metrics.sqlite3"
markers() { python3 "$FPS" --db "$METRICS_DB" events --window 24h --json 2>/dev/null; }

# timeout here too: this scenario plants a FIFO at $PRETTY, so a regression in
# the O_NONBLOCK/S_ISREG handling must fail in seconds, not hang the suite.
apply_cfg_marked() {
  timeout 5 env \
  PALWORLD_ENGINE_INI="$INI" PALWORLD_ENGINE_ENV="$ENV_FILE" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$PRETTY" \
  PALWORLD_FPS_BIN="$FPS" PALWORLD_METRICS_DB="$METRICS_DB" \
    python3 "$ENGINE" apply 2>&1
}

rm -f "$WORK/backups"/Engine.ini.* "$METRICS_DB"
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=30\n' > "$INI"
rm -f "$PRETTY"; mkfifo "$PRETTY"
out="$(apply_cfg_marked)"; rc=$?
assert_ne "$rc" "0" "a partial apply (pretty write refused) still exits nonzero"
assert_ne "$rc" "124" "the partial apply fails promptly, not via the timeout"
assert_file_contains "$INI" "NetServerMaxTickRate=60" "Engine.ini still got the new value despite the pretty-write failure"
assert_contains "$out" "the Engine.ini change stands" "apply's message says the primary change stands"
assert_contains "$(markers)" "partially applied" "a marker records the partial apply"
rm -f "$PRETTY"

# --- a partial rollback: same shape, and no opaque refusal on its own -------
# timeout here too: this scenario plants a FIFO at $PRETTY, so a regression in
# the O_NONBLOCK/S_ISREG handling must fail in seconds, not hang the suite.
rollback_marked() {
  timeout 5 env \
  PALWORLD_ENGINE_INI="$INI" PALWORLD_ENGINE_ENV="$ENV_FILE" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$PRETTY" \
  PALWORLD_FPS_BIN="$FPS" PALWORLD_METRICS_DB="$METRICS_DB" \
    python3 "$ENGINE" rollback "$@" 2>&1
}

rm -f "$METRICS_DB"
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=42\n' \
  > "$WORK/backups/Engine.ini.20260710T182037Z"
printf '[/Script/OnlineSubsystemUtils.IpNetDriver]\nNetServerMaxTickRate=60\n' > "$INI"
rm -f "$PRETTY"; mkfifo "$PRETTY"
out="$(rollback_marked -- Engine.ini.20260710T182037Z)"; rc=$?
assert_ne "$rc" "0" "a partial rollback (pretty write refused) still exits nonzero"
assert_ne "$rc" "124" "the partial rollback fails promptly, not via the timeout"
assert_file_contains "$INI" "NetServerMaxTickRate=42" "Engine.ini was still restored despite the pretty-write failure"
assert_contains "$out" "rollback stands" "rollback's message says the rollback itself stands"
assert_contains "$out" "Engine.pretty.ini" "rollback's message names the file it could not write"
assert_contains "$(markers)" "rollback partially applied" "a marker records the partial rollback"
rm -f "$PRETTY"

assert_report
