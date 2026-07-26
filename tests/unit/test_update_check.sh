#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Unit tests for palworld-update's buildid comparison + exit codes, using a fake
# SteamCMD and a fake app manifest (no real Steam, no s6). Exercises only the
# check paths (no update applied), which don't touch the server.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
UPDATE="$DIR/../../sbin/palworld-update"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/steamapps"
# Fake SteamCMD: prints app_info whose public branch buildid is 100.
cat > "$WORK/steamcmd" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
"2394010"
{
  "depots"
  {
    "branches"
    {
      "public"
      {
        "buildid"  "100"
      }
    }
  }
}
OUT
EOF
chmod +x "$WORK/steamcmd"

set_local_build() { printf '"AppState"\n{\n\t"buildid"\t\t"%s"\n}\n' "$1" > "$WORK/steamapps/appmanifest_2394010.acf"; }

run_update() {
  PALWORLD_INSTALL_DIR="$WORK" PALWORLD_STEAMCMD="$WORK/steamcmd" PALWORLD_DROP_PRIV="" \
    bash "$UPDATE" "$@"
}

# local == remote -> "no update", exit 0
set_local_build 100
assert_rc 0 run_update --check
out="$(run_update 2>&1)"; assert_contains "$out" "no Palworld update available" "reports current"

# local != remote, --check -> exit 10 (update available), server untouched
set_local_build 99
assert_rc 10 run_update --check
out="$(run_update --check 2>&1)"; assert_contains "$out" "update available" "reports available"

# unknown local build (no manifest) still detects an available update via --check
rm -f "$WORK/steamapps/appmanifest_2394010.acf"
assert_rc 10 run_update --check

assert_report
