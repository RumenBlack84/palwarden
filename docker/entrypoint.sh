#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden container entrypoint (PID 1).
#
# One image, two roles, selected by PALWARDEN_MODE:
#   embedded  - install/update the Palworld server, seed its config, then run it
#               under s6 alongside the config web UI and (if configured) the
#               telemetry sampler. Self-contained.
#   external  - do NOT run the server; run only the tooling (telemetry sampler)
#               targeting an existing server at PALWORLD_TARGET_HOST.
#
# Which s6 services start is decided here at runtime by writing markers into the
# s6 `user` bundle before handing off to /init. Runtime config (REST connection,
# Discord webhook) is rendered from environment variables — no secrets in the
# image. Embedded server startup follows docs/palworld-service-runbook.md §12.

set -euo pipefail

MODE="${PALWARDEN_MODE:-embedded}"
INSTALL_DIR="${PALWORLD_INSTALL_DIR:-/opt/palworld/server}"
APP_ID="${PALWORLD_APP_ID:-2394010}"
AS_STEAM="/command/s6-setuidgid steam"
S6_USER_CONTENTS="/etc/s6-overlay/s6-rc.d/user/contents.d"

log() { printf '[palwarden] %s\n' "$*"; }

case "$MODE" in
  embedded|external) ;;
  *) log "Unknown PALWARDEN_MODE='$MODE' (expected 'embedded' or 'external')." >&2; exit 64 ;;
esac

# ---------------------------------------------------------------------------
# Render runtime config from env (both modes). No secrets are baked in the image.
# ---------------------------------------------------------------------------
mkdir -p /etc/palworld
install -d -o steam -g steam /var/lib/palworld   # telemetry DB lives here

if [[ "$MODE" == "external" && -z "${PALWORLD_TARGET_HOST:-}" ]]; then
  log "MODE=external requires PALWORLD_TARGET_HOST (the existing server's host)." >&2
  exit 64
fi

TELEMETRY_READY=0
if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
  # REST connection settings consumed by palworld-api (and thus the sampler).
  rest_host="${PALWORLD_TARGET_HOST:-127.0.0.1}"
  [[ "$MODE" == "embedded" ]] && rest_host="127.0.0.1"
  ( umask 077
    cat > /etc/palworld/settings.env <<EOF
# Rendered by the palwarden entrypoint at container start. Do not edit by hand;
# set the corresponding environment variables instead.
REST_API_ENABLED=True
REST_API_HOST=${rest_host}
REST_API_PORT=${PALWORLD_REST_PORT:-8212}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF
  )
  chown steam:steam /etc/palworld/settings.env
  TELEMETRY_READY=1
else
  log "ADMIN_PASSWORD not set — telemetry/management disabled (no REST access)."
fi

if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
  ( umask 077
    cat > /etc/palworld/notify.env <<EOF
PALWORLD_DISCORD_WEBHOOK=${DISCORD_WEBHOOK}
PALWORLD_NOTIFY_NAME=${PALWORLD_NOTIFY_NAME:-Palworld}
EOF
  )
  chown steam:steam /etc/palworld/notify.env
fi

# ---------------------------------------------------------------------------
# Select which s6 services run this boot (idempotent across restarts).
# ---------------------------------------------------------------------------
mkdir -p "$S6_USER_CONTENTS"
rm -f "$S6_USER_CONTENTS"/palworld-server \
      "$S6_USER_CONTENTS"/config-webui \
      "$S6_USER_CONTENTS"/fps-sample \
      "$S6_USER_CONTENTS"/memory-watch \
      "$S6_USER_CONTENTS"/daily-report
enable_service() { : > "$S6_USER_CONTENTS/$1"; log "service enabled: $1"; }

if [[ "$MODE" == "embedded" ]]; then
  # --- bootstrap the server (as steam) ---
  STEAMCMD="${STEAMCMDDIR:-/home/steam/steamcmd}/steamcmd.sh"
  if [[ ! -f "$STEAMCMD" ]]; then
    if command -v steamcmd >/dev/null 2>&1; then STEAMCMD="$(command -v steamcmd)"; else
      log "steamcmd not found (looked for $STEAMCMD)." >&2; exit 1; fi
  fi
  if [[ "${UPDATE_ON_START:-true}" == "true" ]]; then
    log "Updating Palworld dedicated server (Steam app ${APP_ID})..."
    $AS_STEAM "$STEAMCMD" +force_install_dir "$INSTALL_DIR" +login anonymous \
      +app_update "$APP_ID" validate +quit
  else
    log "UPDATE_ON_START=false — skipping SteamCMD update."
  fi
  if [[ ! -x "$INSTALL_DIR/PalServer.sh" ]]; then
    log "PalServer.sh missing under $INSTALL_DIR — is the game volume mounted/installed?" >&2
    log "Set UPDATE_ON_START=true for the first run so SteamCMD can install it." >&2
    exit 1
  fi
  CFG_DIR="$INSTALL_DIR/Pal/Saved/Config/LinuxServer"
  CFG="$CFG_DIR/PalWorldSettings.ini"
  $AS_STEAM install -d "$CFG_DIR"
  if [[ ! -s "$CFG" && -f "$INSTALL_DIR/DefaultPalWorldSettings.ini" ]]; then
    log "Seeding PalWorldSettings.ini from DefaultPalWorldSettings.ini."
    $AS_STEAM cp "$INSTALL_DIR/DefaultPalWorldSettings.ini" "$CFG"
  fi
  $AS_STEAM chmod +x "$INSTALL_DIR/PalServer.sh" || true
  # Replicate PalServer.sh's binary prep so we can supervise the game binary
  # directly (clean SIGINT delivery): copy steamclient.so and mark it +x.
  if [[ -f "$INSTALL_DIR/linux64/steamclient.so" ]]; then
    $AS_STEAM install -Dm644 "$INSTALL_DIR/linux64/steamclient.so" \
      "$INSTALL_DIR/Pal/Binaries/Linux/steamclient.so" 2>/dev/null || true
  fi
  $AS_STEAM chmod +x "$INSTALL_DIR/Pal/Binaries/Linux/PalServer-Linux-Shipping" 2>/dev/null || true
  # NOTE: env-driven rendering of the server's own PalWorldSettings.ini (enabling
  # the REST API, etc.) lands in a later increment. For embedded telemetry to
  # collect data, enable the REST API in that file with a matching ADMIN_PASSWORD.

  enable_service palworld-server
  enable_service config-webui
  # Memory watchdog runs as root (needs s6 service control) and restarts the
  # server's s6 service when memory is high.
  enable_service memory-watch
fi

if [[ "$TELEMETRY_READY" == "1" ]]; then
  enable_service fps-sample
fi

# Daily Discord report (both modes) when a webhook is configured.
if [[ -n "${DISCORD_WEBHOOK:-}" ]]; then
  enable_service daily-report
fi

# Nothing to do (external mode without telemetry configured)?
if [[ -z "$(ls -A "$S6_USER_CONTENTS" 2>/dev/null)" ]]; then
  log "MODE=external and no telemetry configured — nothing to run."
  log "Set ADMIN_PASSWORD (and PALWORLD_TARGET_HOST) to collect telemetry. Exiting."
  exit 0
fi

log "Bootstrap complete; handing off to s6 supervisor..."
exec /init "$@"
