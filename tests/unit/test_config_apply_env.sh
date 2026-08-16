#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palworld-config-apply-env: settings.env is applied first and the web editor's
# overrides file second, so a value saved in the browser wins over its
# PALWORLD_CFG_* variable — and a host with no overrides file behaves exactly
# as before. The notify/pretty/diff helpers are all best-effort absolute paths
# that may not exist here; the script must still apply and exit 0.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
TOOL="$DIR/../../sbin/palworld-config-apply-env"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/backups"
cp "$DIR/../fixtures/PalWorldSettings.full.ini" "$WORK/PalWorldSettings.ini"

# ExpRate through both files: env says 2, the editor said 3. The editor wins.
cat > "$WORK/settings.env" <<'EOF'
EXP_RATE=2
SERVER_NAME="From Env"
EOF
cat > "$WORK/settings-overrides.env" <<'EOF'
ExpRate="3"
bIsPvP="True"
EOF

apply() {
  PALWORLD_SETTINGS_ENV="$WORK/settings.env" \
  PALWORLD_SETTINGS_OVERRIDES="${OVERRIDES_OVERRIDE:-$WORK/settings-overrides.env}" \
  PALWORLD_CONFIG_FILE="$WORK/PalWorldSettings.ini" \
  PALWORLD_BACKUP_DIR="$WORK/backups" \
  PALWORLD_PARSER_BIN="$DIR/../../bin/palworld-config-parser" \
  PALWORLD_USER="$(id -un)" PALWORLD_GROUP="$(id -gn)" \
    bash "$TOOL" 2>&1
}

apply >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "apply succeeds with both env files"
assert_file_contains "$WORK/PalWorldSettings.ini" 'ExpRate=3' "the editor's value won over PALWORLD_CFG_*"
assert_file_contains "$WORK/PalWorldSettings.ini" 'ServerName="From Env"' "keys only in settings.env still applied"
assert_file_contains "$WORK/PalWorldSettings.ini" 'bIsPvP=True' "keys only in the overrides applied too"
assert_eq "$(find "$WORK/backups" -mindepth 1 | wc -l | tr -d ' ')" "1" "one backup covers both passes"

# No overrides file: the pre-editor behaviour, byte for byte the same path.
cp "$DIR/../fixtures/PalWorldSettings.full.ini" "$WORK/PalWorldSettings.ini"
OVERRIDES_OVERRIDE="$WORK/no-such-file.env" apply >/dev/null 2>&1; rc=$?
assert_eq "$rc" "0" "apply succeeds when the overrides file is absent"
assert_file_contains "$WORK/PalWorldSettings.ini" 'ExpRate=2' "settings.env value applied unshadowed"

assert_report
