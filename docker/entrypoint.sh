#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden container entrypoint.
#
# One image, two roles, selected by PALWARDEN_MODE:
#   embedded  - install/update and run the Palworld dedicated server in this
#               container (self-contained). Tooling (added next increment) runs
#               alongside and talks to the server over localhost.
#   external  - do NOT run the server; the management tooling instead targets an
#               existing Palworld server at PALWORLD_TARGET_HOST. The active part
#               of this mode lands in the next increment.
#
# The server half (embedded mode) follows docs/palworld-service-runbook.md §12.

set -euo pipefail

MODE="${PALWARDEN_MODE:-embedded}"
INSTALL_DIR="${PALWORLD_INSTALL_DIR:-/opt/palworld/server}"
APP_ID="${PALWORLD_APP_ID:-2394010}"

log() { printf '[palwarden] %s\n' "$*"; }

case "$MODE" in
  external)
    log "MODE=external — managing an existing Palworld server."
    log "Target: ${PALWORLD_TARGET_HOST:-<unset>}:${PALWORLD_REST_PORT:-8212}"
    log "The management tooling is containerized in the next increment; there is"
    log "nothing to run in external mode yet. Exiting cleanly."
    exit 0
    ;;
  embedded)
    : # fall through to server startup below
    ;;
  *)
    log "Unknown PALWARDEN_MODE='$MODE' (expected 'embedded' or 'external')." >&2
    exit 64
    ;;
esac

# --- embedded: install/update the server ------------------------------------
# Locate steamcmd from the cm2network base (STEAMCMDDIR) with a sane fallback.
STEAMCMD="${STEAMCMDDIR:-/home/steam/steamcmd}/steamcmd.sh"
if [[ ! -x "$STEAMCMD" && ! -f "$STEAMCMD" ]]; then
  if command -v steamcmd >/dev/null 2>&1; then
    STEAMCMD="$(command -v steamcmd)"
  else
    log "steamcmd not found (looked for $STEAMCMD)." >&2
    exit 1
  fi
fi

if [[ "${UPDATE_ON_START:-true}" == "true" ]]; then
  log "Updating Palworld dedicated server (Steam app ${APP_ID})..."
  "$STEAMCMD" +force_install_dir "$INSTALL_DIR" \
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

# --- embedded: seed the live config if absent -------------------------------
CFG_DIR="$INSTALL_DIR/Pal/Saved/Config/LinuxServer"
CFG="$CFG_DIR/PalWorldSettings.ini"
install -d "$CFG_DIR"
if [[ ! -s "$CFG" && -f "$INSTALL_DIR/DefaultPalWorldSettings.ini" ]]; then
  log "Seeding PalWorldSettings.ini from DefaultPalWorldSettings.ini."
  cp "$INSTALL_DIR/DefaultPalWorldSettings.ini" "$CFG"
fi
# NOTE: env-driven config rendering (palworld-config-apply-env) is wired in the
# tooling increment; for now the server uses whatever is in PalWorldSettings.ini.

chmod +x "$INSTALL_DIR/PalServer.sh" || true
cd "$INSTALL_DIR"

log "Starting Palworld dedicated server on UDP ${PALWORLD_GAME_PORT:-8211}..."
exec "$INSTALL_DIR/PalServer.sh" \
  -useperfthreads \
  -NoAsyncLoadingThread \
  -UseMultithreadForDS \
  "$@"
