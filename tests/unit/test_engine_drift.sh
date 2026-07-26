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

check() {
  PALWORLD_ENGINE_INI="$INI" PALWORLD_ENGINE_ENV="$ENV_FILE" \
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$WORK/Engine.pretty.ini" \
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
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$WORK/Engine.pretty.ini" \
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
  PALWORLD_BACKUP_DIR="$WORK/backups" PALWORLD_ENGINE_PRETTY_INI="$WORK/Engine.pretty.ini" \
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

assert_report
