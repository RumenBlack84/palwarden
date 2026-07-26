#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Tests for chattr +i config protection (stops Palworld overwriting managed
# config on restart) and — critically — that it DEGRADES GRACEFULLY where the
# immutable bit is unavailable, e.g. inside a container, which has neither
# e2fsprogs by default nor CAP_LINUX_IMMUTABLE. Losing protection is acceptable
# there; failing to write the config is not.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
REPO="$(cd "$DIR/../.." && pwd)"
HELPER="$REPO/lib/palworld-fileattr"
ENGINE="$REPO/sbin/palworld-engine-config"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- fake chattr/lsattr that record calls and report a settable state --------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/lsattr" <<EOF
#!/usr/bin/env bash
# state file holds the attr string, e.g. "----i---------" or "--------------"
printf '%s %s\n' "\$(cat "$WORK/attrs" 2>/dev/null || echo '--------------')" "\${*: -1}"
EOF
cat > "$WORK/bin/chattr" <<EOF
#!/usr/bin/env bash
echo "chattr \$*" >> "$WORK/calls"
case "\$1" in
  +i) echo '----i---------' > "$WORK/attrs" ;;
  -i) echo '--------------' > "$WORK/attrs" ;;
esac
EOF
chmod +x "$WORK/bin/lsattr" "$WORK/bin/chattr"
reset_fakes() { : > "$WORK/calls"; echo '--------------' > "$WORK/attrs"; }

with_fakes()    { PATH="$WORK/bin:$PATH" "$@"; }
without_fakes() { PATH="/nonexistent-for-tests:/usr/bin:/bin" "$@"; }

# ===========================================================================
# The shared shell helper
# ===========================================================================
target="$WORK/target.ini"; echo "x" > "$target"

# detects a clear bit, sets it, detects it again
reset_fakes
out="$(with_fakes bash -c "source '$HELPER'; fileattr_is_immutable '$target' && echo yes || echo no")"
assert_eq "$out" "no" "helper: not immutable initially"
with_fakes bash -c "source '$HELPER'; fileattr_set_immutable '$target' on" >/dev/null 2>&1
assert_file_contains "$WORK/calls" "chattr +i" "helper: lock calls chattr +i"
out="$(with_fakes bash -c "source '$HELPER'; fileattr_is_immutable '$target' && echo yes || echo no")"
assert_eq "$out" "yes" "helper: immutable after lock"
with_fakes bash -c "source '$HELPER'; fileattr_set_immutable '$target' off" >/dev/null 2>&1
assert_file_contains "$WORK/calls" "chattr -i" "helper: unlock calls chattr -i"

# with the tools missing it must report "not immutable" and succeed, not error out
out="$(without_fakes bash -c "source '$HELPER'; fileattr_is_immutable '$target' && echo yes || echo no" 2>/dev/null)"
assert_eq "$out" "no" "helper: unsupported -> reports not immutable"
assert_rc 0 without_fakes bash -c "source '$HELPER'; fileattr_set_immutable '$target' on"

# ===========================================================================
# palworld-engine-config: the immutability helpers must not raise when the
# tooling is missing (this is the container crash we are fixing).
# ===========================================================================
py() { python3 - "$ENGINE" "$@"; }

assert_rc 0 py <<'PY'
import importlib.machinery, importlib.util, subprocess, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("ec", sys.argv[1])
spec = importlib.util.spec_from_loader("ec", loader)
ec = importlib.util.module_from_spec(spec)
sys.modules["ec"] = ec          # @dataclass resolves types via sys.modules
loader.exec_module(ec)

def missing(*a, **k):
    raise FileNotFoundError(2, "No such file or directory", "lsattr")
def denied(*a, **k):
    raise subprocess.CalledProcessError(1, "chattr", stderr="Operation not permitted")

p = Path("/tmp/does-not-matter")
assert ec.file_is_immutable(p, runner=missing) is False, "should report False, not raise"
assert ec.file_is_immutable(p, runner=denied) is False, "should report False, not raise"
ec.set_immutable(p, True, runner=missing)   # must not raise
ec.set_immutable(p, True, runner=denied)    # must not raise

ran = []
with ec.mutable_engine_file(p, protect=True, runner=missing):
    ran.append("body")
assert ran == ["body"], "the write must still happen when chattr is unavailable"
PY

# ===========================================================================
# End-to-end: engine-config apply must write the value even with no chattr.
# ===========================================================================
srv="$WORK/server"; ini_dir="$srv/Pal/Saved/Config/LinuxServer"
mkdir -p "$ini_dir" "$WORK/backups"
printf '[/Script/Engine.Engine]\nNetServerMaxTickRate=30\n' > "$ini_dir/Engine.ini"
printf 'NET_SERVER_MAX_TICK_RATE=60\n' > "$WORK/engine.env"

run_engine() {
  PALWORLD_ENGINE_INI="$ini_dir/Engine.ini" \
  PALWORLD_ENGINE_ENV="$WORK/engine.env" \
  PALWORLD_BACKUP_DIR="$WORK/backups" \
  PALWORLD_ENGINE_PRETTY_INI="$ini_dir/Engine.pretty.ini" \
    "$@"
}

out="$(without_fakes run_engine python3 "$ENGINE" apply 2>&1)"; rc=$?
assert_eq "$rc" "0" "engine apply exits 0 without chattr available"
assert_file_contains "$ini_dir/Engine.ini" "NetServerMaxTickRate=60" "engine apply writes the value anyway"
assert_not_contains "$out" "Traceback" "engine apply does not traceback"

# with chattr available it should also lock the file afterwards
printf '[/Script/Engine.Engine]\nNetServerMaxTickRate=30\n' > "$ini_dir/Engine.ini"
reset_fakes
with_fakes run_engine python3 "$ENGINE" apply >/dev/null 2>&1
assert_file_contains "$WORK/calls" "chattr +i" "engine apply re-locks Engine.ini when supported"

# ===========================================================================
# PalWorldSettings.ini protection: apply-env must unlock -> write -> relock, so
# the server cannot revert managed settings when it shuts down.
# ===========================================================================
APPLY="$REPO/sbin/palworld-config-apply-env"
PROTECT="$REPO/sbin/palworld-config-protect"

settings_ini="$ini_dir/PalWorldSettings.ini"
make_settings() {
  printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(ServerName="",ServerPlayerMaxNum=32)\n' \
    > "$settings_ini"
}
run_apply() {
  PALWORLD_SETTINGS_ENV="$WORK/settings.env" \
  PALWORLD_CONFIG_FILE="$settings_ini" \
  PALWORLD_BACKUP_DIR="$WORK/backups" \
  PALWORLD_PARSER_BIN="$REPO/bin/palworld-config-parser" \
  PALWORLD_USER="$(id -un)" PALWORLD_GROUP="$(id -gn)" \
    bash "$APPLY" "$@"
}
printf 'SERVER_NAME="Protected"\n' > "$WORK/settings.env"

# default: applies the setting AND locks the file afterwards
make_settings; reset_fakes
out="$(with_fakes run_apply 2>&1)"; rc=$?
assert_eq "$rc" "0" "apply-env exits 0"
assert_file_contains "$settings_ini" 'ServerName="Protected"' "apply-env applied the setting"
assert_file_contains "$WORK/calls" "chattr +i" "apply-env locks PalWorldSettings.ini by default"

# an already-locked file is unlocked first, written, then relocked
make_settings; reset_fakes
echo '----i---------' > "$WORK/attrs"     # pretend it is already immutable
with_fakes run_apply >/dev/null 2>&1
assert_file_contains "$WORK/calls" "chattr -i" "apply-env unlocks a locked file before writing"
assert_file_contains "$settings_ini" 'ServerName="Protected"' "apply-env writes through the lock"
assert_eq "$(tail -1 "$WORK/calls")" "chattr +i -- $settings_ini" "relocked as the final step"

# --no-protect leaves the file mutable
make_settings; reset_fakes
with_fakes run_apply --no-protect >/dev/null 2>&1
assert_file_not_contains "$WORK/calls" "chattr +i" "--no-protect does not lock"
assert_file_contains "$settings_ini" 'ServerName="Protected"' "--no-protect still applies settings"

# where chattr is unavailable (container) the apply must still succeed
make_settings
out="$(without_fakes run_apply 2>&1)"; rc=$?
assert_eq "$rc" "0" "apply-env exits 0 without chattr available"
assert_file_contains "$settings_ini" 'ServerName="Protected"' "apply-env applies without chattr"
assert_not_contains "$out" "Traceback" "no traceback without chattr"

# ===========================================================================
# palworld-config-protect: manual lock/unlock/status for PalWorldSettings.ini
# ===========================================================================
run_protect() { PALWORLD_CONFIG_FILE="$settings_ini" bash "$PROTECT" "$@"; }

make_settings; reset_fakes
with_fakes run_protect lock >/dev/null 2>&1
assert_file_contains "$WORK/calls" "chattr +i" "protect lock sets the immutable bit"
out="$(with_fakes run_protect status 2>&1)"
assert_contains "$out" "yes" "protect status reports locked"
with_fakes run_protect unlock >/dev/null 2>&1
assert_file_contains "$WORK/calls" "chattr -i" "protect unlock clears the immutable bit"
out="$(with_fakes run_protect status 2>&1)"
assert_contains "$out" "no" "protect status reports unlocked"
# unsupported environment: report, do not fail
assert_rc 0 without_fakes run_protect lock

assert_report
