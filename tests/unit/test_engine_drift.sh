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

assert_report
