#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Volume persistence: `docker compose down` followed by `up` must preserve the
# world and the config. Exercises the real docker/compose.yaml, including the
# nested submount (palworld-saved mounted *inside* palworld-server).
#
# Runs under its own compose project/ports so it cannot disturb a real stack.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/assert.sh"

PROJECT="palwarden-persist-test"
FAKE="$REPO/tests/fixtures/fake-server"
WORK="$(mktemp -d)"

export COMPOSE_PROFILES=embedded
export UPDATE_ON_START=false
export ADMIN_PASSWORD=not-a-real-admin-password
export PALWORLD_GAME_PORT=18211
export WEBUI_PORT=18088

# Server settings go through an env file, the documented mechanism (compose
# forwards .env into the container so open-ended PALWORLD_CFG_* keys work).
set_server_name() { printf 'PALWORLD_CFG_SERVER_NAME=%s\n' "$1" > "$WORK/test.env"; }
set_server_name "persistence probe"

# Distinct container name so a running stack does not clash.
cat > "$WORK/override.yml" <<EOF
services:
  palwarden:
    container_name: palwarden-persist-test
    env_file:
      - path: $WORK/test.env
        required: true
EOF

dc() { docker compose -p "$PROJECT" -f "$REPO/docker/compose.yaml" -f "$WORK/override.yml" "$@"; }
cleanup() {
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  # Volumes seeded with `docker run -v` lack compose's labels, so `down -v` skips
  # them; remove by name so the test never leaks state.
  for v in palworld-server palworld-saved palwarden-state palwarden-backups \
           palwarden-config-snapshots palwarden-config-backups; do
    docker volume rm -f "${PROJECT}_${v}" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

if ! docker compose version >/dev/null 2>&1; then
  echo "  docker compose unavailable — skipping"; assert_report; exit 0
fi

SAVED_MARKER=/opt/palworld/server/Pal/Saved/SaveGames/world-marker.txt
CFG=/opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini

# Start clean, then seed the game volume with the dummy server (no 5GB download).
dc down -v --remove-orphans >/dev/null 2>&1 || true
echo "  building + seeding ..."
dc build >/dev/null 2>&1 || { fail "compose build failed"; assert_report; exit 1; }
docker run --rm -v "${PROJECT}_palworld-server":/dst -v "$FAKE":/src:ro \
  --entrypoint sh palwarden:latest -c 'cp -a /src/. /dst/ && chown -R steam:steam /dst' >/dev/null 2>&1 \
  || { fail "seeding the game volume failed"; assert_report; exit 1; }

wait_ready() {
  docker exec "$1" sh -c 'i=0; until s6-svstat /run/service/palworld-server 2>/dev/null | grep -q "^up"; do
    i=$((i+1)); [ $i -gt 30 ] && exit 1; sleep 1; done'
}

# ---------------------------------------------------------------- first boot --
dc up -d >/dev/null 2>&1 || { fail "first compose up failed"; assert_report; exit 1; }
C=palwarden-persist-test
wait_ready "$C" || fail "server did not come up on first boot"

# config from the environment was applied
assert_rc 0 docker exec "$C" grep -qF 'ServerName="persistence probe"' "$CFG"
# write world data, as the server would
docker exec --user root "$C" sh -c "mkdir -p \$(dirname $SAVED_MARKER) && \
  echo 'world-data-v1' > $SAVED_MARKER && chown -R steam:steam /opt/palworld/server/Pal/Saved/SaveGames" >/dev/null 2>&1
assert_rc 0 docker exec "$C" grep -qx 'world-data-v1' "$SAVED_MARKER"

# the save must live in the palworld-saved volume, not the parent server volume
saved_in_saved="$(docker run --rm -v "${PROJECT}_palworld-saved":/v --entrypoint sh palwarden:latest \
  -c 'cat /v/SaveGames/world-marker.txt 2>/dev/null' 2>/dev/null || true)"
assert_eq "$saved_in_saved" "world-data-v1" "save data lands in the palworld-saved volume"

# --------------------------------------------------------------- down and up --
dc down >/dev/null 2>&1 || fail "compose down failed"
# `down` without -v must keep the volumes
assert_rc 0 docker volume inspect "${PROJECT}_palworld-saved"
assert_rc 0 docker volume inspect "${PROJECT}_palworld-server"
# and the container really is gone
out="$(docker ps -a --filter "name=^${C}$" --format '{{.Names}}')"
assert_eq "$out" "" "container removed by down"

dc up -d >/dev/null 2>&1 || { fail "second compose up failed"; assert_report; exit 1; }
wait_ready "$C" || fail "server did not come up on second boot"

# ------------------------------------------------------------ what persisted --
assert_rc 0 docker exec "$C" grep -qx 'world-data-v1' "$SAVED_MARKER"
assert_rc 0 docker exec "$C" grep -qF 'ServerName="persistence probe"' "$CFG"
# the game install itself persisted too (no re-download needed)
assert_rc 0 docker exec "$C" test -x /opt/palworld/server/PalServer.sh

# second boot re-applied config cleanly
logs="$(docker logs "$C" 2>&1)"
assert_not_contains "$logs" "Operation not permitted" "no permission error on re-apply"
assert_not_contains "$logs" "Traceback" "no traceback on the second boot"

# ------------------------------------------- backups survive --force-recreate --
# The bug the palwarden-backups volume exists to fix, pinned. /opt/palworld/backups
# used to live in the container's writable layer, so `docker compose up
# --force-recreate` — an ordinary upgrade — destroyed every archive. A scheduled
# backup that cannot survive a recreate is not a backup.
#
# A REAL archive, written by the real tool as root, not a file dropped in with
# `docker exec`: the ownership split is part of what has to survive.
bk_out="$(docker exec --user root "$C" palworld-backup 2>&1 | tail -1)"
bk_name="$(basename "$bk_out")"
assert_contains "$bk_name" "palworld-save-" "an archive was created before the recreate ($bk_out)"
bk_sum="$(docker exec "$C" sh -c "sha256sum < '/opt/palworld/backups/$bk_name'" | awk '{print $1}')"
if [ "${#bk_sum}" -eq 64 ]; then pass; else fail "could not hash the archive before the recreate"; fi

# --force-recreate replaces the container (and its writable layer) while keeping
# the named volumes — exactly what `git pull && docker compose up -d` does.
dc up -d --force-recreate >/dev/null 2>&1 || fail "compose up --force-recreate failed"
wait_ready "$C" || fail "server did not come up after --force-recreate"
assert_rc 0 docker exec "$C" test -f "/opt/palworld/backups/$bk_name"
after_sum="$(docker exec "$C" sh -c "sha256sum < '/opt/palworld/backups/$bk_name' 2>/dev/null" | awk '{print $1}')"
assert_eq "$after_sum" "$bk_sum" "the archive survived --force-recreate byte for byte"
# The directory's ownership is the other half: palworld-backup writes into it as
# root and palworld-restore refuses to work from a directory (or parent) any lesser
# account can write. A volume seeded with the wrong ownership would break both
# while the archive itself still sat there.
assert_eq "$(docker exec "$C" stat -c '%U %a' /opt/palworld/backups)" "root 755" \
  "...and the backups directory is still root-owned 0755"
assert_eq "$(docker exec "$C" stat -c '%U' /opt/palworld)" "root" \
  "...and so is its parent, which is what palworld-restore checks"
# The archive itself belongs to the service account, as palworld-backup left it.
assert_eq "$(docker exec "$C" stat -c '%U' "/opt/palworld/backups/$bk_name")" "steam" \
  "...and the archive still belongs to the service account"
# The backups volume's two siblings are volumes for the same reason.
assert_rc 0 docker volume inspect "${PROJECT}_palwarden-config-snapshots"
assert_rc 0 docker volume inspect "${PROJECT}_palwarden-config-backups"

# a changed setting is picked up on reboot even though the file was locked
dc down >/dev/null 2>&1
set_server_name "renamed after restart"
dc up -d >/dev/null 2>&1
wait_ready "$C" || fail "server did not come up on third boot"
assert_rc 0 docker exec "$C" grep -qF 'ServerName="renamed after restart"' "$CFG"
assert_rc 0 docker exec "$C" grep -qx 'world-data-v1' "$SAVED_MARKER"

# --- tearing the stack down for real ----------------------------------------
# Config is mutable, so `down -v` removes the volumes with no extra steps.
dc down -v >/dev/null 2>&1
assert_rc 1 docker volume inspect "${PROJECT}_palworld-saved"

assert_report
