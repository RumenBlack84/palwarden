#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden container entrypoint (PID 1).
#
# One image, two roles, selected by PALWARDEN_MODE:
#   embedded  - install/update the Palworld server, seed its config, then hand
#               off to the s6 supervisor which runs the server + config web UI
#               (and, from the next increment, the background tooling).
#   external  - do NOT run the server; the tooling targets an existing server at
#               PALWORLD_TARGET_HOST. The active part of this mode lands in a
#               later increment.
#
# Embedded server startup follows docs/palworld-service-runbook.md §12.

set -euo pipefail

MODE="${PALWARDEN_MODE:-embedded}"
INSTALL_DIR="${PALWORLD_INSTALL_DIR:-/opt/palworld/server}"
APP_ID="${PALWORLD_APP_ID:-2394010}"
# Drop to the unprivileged service account for any privileged-context work.
AS_STEAM="/command/s6-setuidgid steam"

log() { printf '[palwarden] %s\n' "$*"; }

case "$MODE" in
  external)
    log "MODE=external — managing an existing Palworld server."
    log "Target: ${PALWORLD_TARGET_HOST:-<unset>}:${PALWORLD_REST_PORT:-8212}"
    log "The management tooling is containerized in a later increment; there is"
    log "nothing to run in external mode yet. Exiting cleanly."
    exit 0
    ;;
  embedded)
    : # fall through to server bootstrap + supervisor handoff below
    ;;
  *)
    log "Unknown PALWARDEN_MODE='$MODE' (expected 'embedded' or 'external')." >&2
    exit 64
    ;;
esac

# --- embedded: install/update the server (as steam) -------------------------
STEAMCMD="${STEAMCMDDIR:-/home/steam/steamcmd}/steamcmd.sh"
if [[ ! -f "$STEAMCMD" ]]; then
  if command -v steamcmd >/dev/null 2>&1; then
    STEAMCMD="$(command -v steamcmd)"
  else
    log "steamcmd not found (looked for $STEAMCMD)." >&2
    exit 1
  fi
fi

if [[ "${UPDATE_ON_START:-true}" == "true" ]]; then
  log "Updating Palworld dedicated server (Steam app ${APP_ID})..."
  $AS_STEAM "$STEAMCMD" +force_install_dir "$INSTALL_DIR" \
    +login anonymous \
    +app_update "$APP_ID" validate \
    +quit
else
  log "UPDATE_ON_START=false — skipping SteamCMD update."
fi

if [[ ! -x "$INSTALL_DIR/PalServer.sh" ]]; then
  log "PalServer.sh missing under $INSTALL_DIR — is the game volume mounted and installed?" >&2
  log "Set UPDATE_ON_START=true for the first run so SteamCMD can install it." >&2
  exit 1
fi

# --- embedded: seed the live config if absent (as steam) --------------------
CFG_DIR="$INSTALL_DIR/Pal/Saved/Config/LinuxServer"
CFG="$CFG_DIR/PalWorldSettings.ini"
$AS_STEAM install -d "$CFG_DIR"
if [[ ! -s "$CFG" && -f "$INSTALL_DIR/DefaultPalWorldSettings.ini" ]]; then
  log "Seeding PalWorldSettings.ini from DefaultPalWorldSettings.ini."
  $AS_STEAM cp "$INSTALL_DIR/DefaultPalWorldSettings.ini" "$CFG"
fi
# NOTE: env-driven config rendering (palworld-config-apply-env) is wired in a
# later increment; for now the server uses whatever is in PalWorldSettings.ini.
$AS_STEAM chmod +x "$INSTALL_DIR/PalServer.sh" || true

# --- hand off to the s6 supervisor ------------------------------------------
# s6-overlay (/init) becomes PID 1 as root and supervises the server + web UI,
# each of which drops to the steam user. See docker/s6-rc.d/.
log "Bootstrap complete; handing off to s6 supervisor (server + config web UI)..."
exec /init "$@"
