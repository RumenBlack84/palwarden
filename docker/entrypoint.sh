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
# Drop to steam with a correct HOME — s6-setuidgid changes uid/gid but not HOME,
# and SteamCMD writes its state under $HOME (fails with "Missing file
# permissions" if it inherits root's /root).
AS_STEAM="env HOME=/home/steam /command/s6-setuidgid steam"
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
install -d -o steam -g steam /var/lib/palworld /opt/palworld/config-backups
# Job queue for the control plane. Owned by the *web* user (steam) because the
# unprivileged web UI is the only writer; the root worker reads and updates the
# files it finds and is not constrained by the mode. 0700 keeps job files — which
# can carry config values — off-limits to anything else in the container.
# Only the mount point's own child is created here (never a recursive chown of a
# mounted volume; see CLAUDE.md / runbook §11).
install -d -o steam -g steam -m 0700 /var/lib/palworld/jobs
# Upload staging for the backup panel, and the deliberate counterpart to the
# scratch directory below: these two have *opposite* ownership on purpose.
#
#   uploads        - steam (the web user), 0700. The unprivileged web process
#                    streams a browser upload straight into it, exactly as it
#                    writes the job queue above, and palwarden-webui refuses to
#                    accept an upload unless it owns this directory with no
#                    group/other bits. palwarden-webui also creates it on demand;
#                    that stays, but packaging it here means the very first upload
#                    is not the thing that discovers a packaging gap.
#   restore-scratch- root:root, 0700, and under the ROOT-OWNED /opt/palworld.
#                    palworld-restore copies an archive here and validates the
#                    copy, because archives in the backups directory are chowned to
#                    the service account and are therefore writable by the web
#                    process — validating one in place would prove the name and not
#                    the bytes. That argument only holds if neither the directory
#                    NOR ANY PARENT is writable by that account, so it cannot live
#                    under /var/lib/palworld (steam-owned 0755, right above):
#                    steam could pre-create it, or rename root's aside and put its
#                    own there, and a substituted archive would restore while
#                    reporting success. /opt/palworld is the root-owned parent this
#                    image already puts backups and config-snapshots under.
# Both are mount-point children only — never a recursive chown of a mounted
# volume (see CLAUDE.md / runbook §11).
install -d -o steam -g steam -m 0700 /var/lib/palworld/uploads
install -d -o root -g root -m 0700 /opt/palworld/restore-scratch
# Pre-create the telemetry DB owned by steam so root-context boot steps (e.g.
# config-apply-env's event marker) don't leave it root-owned.
[[ -e /var/lib/palworld/metrics.sqlite3 ]] \
  || install -o steam -g steam -m 0644 /dev/null /var/lib/palworld/metrics.sqlite3

if [[ "$MODE" == "external" && -z "${PALWORLD_TARGET_HOST:-}" ]]; then
  log "MODE=external requires PALWORLD_TARGET_HOST (the existing server's host)." >&2
  exit 64
fi

# Render settings.env (REST connection + any PALWORLD_CFG_* server settings) and
# notify.env from env. No secrets are baked into the image.
palwarden-render-config /etc/palworld/settings.env /etc/palworld/notify.env
chown steam:steam /etc/palworld/settings.env 2>/dev/null || true
if [[ -f /etc/palworld/notify.env ]]; then
  chown steam:steam /etc/palworld/notify.env 2>/dev/null || true
fi

# Scheduled-backup settings, rendered from BACKUP_* env **only if the file is
# absent**. Unlike settings.env this is not re-rendered on every start, and that
# asymmetry is the point: the schedule file is also written by palwarden-jobd's
# backup_schedule_save action when the operator saves the schedule form, so
# re-rendering it from the compose file would silently revert every change made
# from the browser on the next `docker compose up`. The env vars are the *seed*;
# the panel owns it thereafter. Root-owned 0644 — it is tuning, not a secret.
#
# **Where** it lives is a container-only difference and it matters as much as the
# seeding rule. The bare-metal default is /etc/palworld/backup.env, which is
# genuinely persistent on a real host; in the container /etc is the writable layer,
# which `docker compose up --force-recreate` throws away — so a schedule saved from
# the panel reverted to the 14-day retention default on the next recreate and the
# next --prune then deleted the very history the operator had raised retention to
# keep. compose.yaml therefore points PALWORLD_BACKUP_SCHEDULE at the
# palwarden-state volume, and this seeding follows the variable rather than the
# literal path so the two cannot drift. The default here matches the tools' own
# default, so running the image without compose.yaml still behaves.
SCHEDULE_FILE="${PALWORLD_BACKUP_SCHEDULE:-/etc/palworld/backup.env}"
# Only when it is missing: both real destinations already exist by now, and an
# unconditional `install -d` would reassign the *owner* of one of them —
# /var/lib/palworld is deliberately steam-owned (it is the web user's job queue and
# telemetry directory), and taking it to root would break the unprivileged writers.
_sched_dir="$(dirname "$SCHEDULE_FILE")"
[[ -d "$_sched_dir" ]] || install -d -o root -g root "$_sched_dir"
unset _sched_dir
# Carry a schedule saved by a pre-volume image across the upgrade that moved the
# file, rather than making the operator notice their retention policy reset. Same
# shape as the palwarden-backups upgrade guard below: /etc/palworld/backup.env
# still exists in a *restarted* old container's writable layer.
if [[ ! -e "$SCHEDULE_FILE" && "$SCHEDULE_FILE" != /etc/palworld/backup.env
      && -f /etc/palworld/backup.env ]]; then
  if cat /etc/palworld/backup.env > "$SCHEDULE_FILE" 2>/dev/null; then
    chown root:root "$SCHEDULE_FILE" 2>/dev/null || true
    chmod 0644 "$SCHEDULE_FILE" 2>/dev/null || true
    log "migrated the saved backup schedule from /etc/palworld/backup.env to $SCHEDULE_FILE (it is on a volume now, so it survives a recreate)."
  fi
fi
#
# Only the four keys palworld-backups reads, and only the ones actually set, so an
# unset variable leaves the tool's own default in place rather than pinning it into
# a file. BACKUP_TICK_SECONDS is deliberately not among them: it is this
# container's tick, read by the s6 service, not part of the schedule.
if [[ ! -e "$SCHEDULE_FILE" ]]; then
  _sched=""
  for _key in BACKUP_ENABLED BACKUP_INTERVAL_HOURS BACKUP_RETENTION_DAYS BACKUP_KEEP_MIN; do
    # Indirect expansion with a default, so `set -u` cannot trip on an unset name.
    _value="${!_key-}"
    [[ -n "$_value" ]] || continue
    _sched+="${_key}=${_value}"$'\n'
  done
  if [[ -n "$_sched" ]]; then
    # No umask here: it would leak into the rest of PID 1 (there is no subshell
    # around this block), and the explicit chmod below already decides the mode.
    {
      printf '# Rendered by palwarden-entrypoint from BACKUP_* environment variables.\n'
      printf '# Seeded once: the backup panel (palwarden-jobd backup_schedule_save)\n'
      printf '# owns this file afterwards, so edits made in the browser survive a\n'
      printf '# container recreate. Delete it to re-seed from the environment.\n\n'
      printf '%s' "$_sched"
    } > "$SCHEDULE_FILE"
    chown root:root "$SCHEDULE_FILE" 2>/dev/null || true
    chmod 0644 "$SCHEDULE_FILE" 2>/dev/null || true
    log "rendered $SCHEDULE_FILE from BACKUP_* env."
  fi
  unset _sched _key _value
elif [[ "$(stat -c %U "$SCHEDULE_FILE" 2>/dev/null || echo root)" != "root" ]]; then
  # Only root (the entrypoint, or palwarden-jobd acting on the panel's behalf)
  # should ever have written this. The state volume's directory is steam-owned, so
  # a non-root owner here means the unprivileged web process replaced the file
  # behind the validated path — worth saying out loud rather than reading silently.
  log "WARNING: $SCHEDULE_FILE is not owned by root; it may have been replaced outside the backup panel. Values are still range-checked when read." >&2
fi

# Web UI credentials (root-only file; generated once, honouring WEBUI_* from env).
# Suppress stdout: on first creation this prints the generated WEBUI_PASSWORD/
# WEBUI_TOKEN, which must never land in `docker logs`.
palwarden-webui --init-credentials >/dev/null || log "could not initialise web UI credentials."
# Owned by root, readable by the unprivileged webui server's group (steam) only.
# The webui server itself must never be able to rewrite WEBUI_TOKEN, which the
# root job worker (increment 2) will trust.
chown root:steam /etc/palworld/webui.env 2>/dev/null || true
chmod 0640 /etc/palworld/webui.env 2>/dev/null || true

TELEMETRY_READY=0
if [[ -n "${ADMIN_PASSWORD:-}" ]]; then
  TELEMETRY_READY=1
else
  log "ADMIN_PASSWORD not set — telemetry/management disabled (no REST access)."
fi

# ---------------------------------------------------------------------------
# Select which s6 services run this boot (idempotent across restarts).
# ---------------------------------------------------------------------------
mkdir -p "$S6_USER_CONTENTS"
rm -f "$S6_USER_CONTENTS"/palworld-server \
      "$S6_USER_CONTENTS"/config-webui \
      "$S6_USER_CONTENTS"/fps-sample \
      "$S6_USER_CONTENTS"/memory-watch \
      "$S6_USER_CONTENTS"/daily-report \
      "$S6_USER_CONTENTS"/update-check \
      "$S6_USER_CONTENTS"/public-info-watch \
      "$S6_USER_CONTENTS"/service-events \
      "$S6_USER_CONTENTS"/jobd \
      "$S6_USER_CONTENTS"/backup-auto
enable_service() { : > "$S6_USER_CONTENTS/$1"; log "service enabled: $1"; }

if [[ "$MODE" == "embedded" ]]; then
  # --- bootstrap the server (as steam) ---
  STEAMCMD="${STEAMCMDDIR:-/home/steam/steamcmd}/steamcmd.sh"
  if [[ ! -f "$STEAMCMD" ]]; then
    if command -v steamcmd >/dev/null 2>&1; then STEAMCMD="$(command -v steamcmd)"; else
      log "steamcmd not found (looked for $STEAMCMD)." >&2; exit 1; fi
  fi
  # Mounted volumes often come up root-owned; make the mount points writable by
  # steam (NON-recursive — cheap and safe even with the game installed) so
  # SteamCMD installs into the volume instead of falling back to steam's home.
  for d in "$INSTALL_DIR" "$INSTALL_DIR/Pal" "$INSTALL_DIR/Pal/Saved"; do
    if [[ -d "$d" ]]; then chown steam:steam "$d" 2>/dev/null || true; fi
  done
  if [[ "${UPDATE_ON_START:-true}" == "true" ]]; then
    log "Updating Palworld dedicated server (Steam app ${APP_ID})..."
    # SteamCMD self-updates and restarts on first run, and that restart can drop
    # the app context ("Missing configuration"). Retry so the second pass — on an
    # already-updated SteamCMD — installs the game.
    for attempt in 1 2 3; do
      if $AS_STEAM "$STEAMCMD" +force_install_dir "$INSTALL_DIR" +login anonymous \
           +app_update "$APP_ID" validate +quit; then
        break
      fi
      log "SteamCMD attempt ${attempt} did not complete (often the self-update restart); retrying..."
    done
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

  # Apply env-driven settings to the server's PalWorldSettings.ini before it
  # starts: enables the REST API (so embedded telemetry works out of the box),
  # sets passwords, and any PALWORLD_CFG_* server settings. Runs as root so it
  # can chown to steam; best-effort so a parser hiccup never blocks boot.
  # Also when the web editor has saved overrides: those live on the state
  # volume and must be re-asserted onto the (possibly recreated) config file.
  if [[ -n "${ADMIN_PASSWORD:-}" ]] || compgen -e | grep -q '^PALWORLD_CFG_' \
      || [[ -r "${PALWORLD_SETTINGS_OVERRIDES:-/etc/palworld/settings-overrides.env}" ]]; then
    log "Applying settings.env to PalWorldSettings.ini..."
    # PALWORLD_USER/GROUP come from the image env (steam).
    /usr/local/sbin/palworld-config-apply-env \
      || log "config apply reported an issue (continuing)."
  fi

  enable_service palworld-server
  enable_service config-webui
  # Steam auto-update checker (opt-in; restarts the server via s6 when a new
  # build lands). Runs as root; SteamCMD drops to steam.
  [[ "${UPDATE_CHECK:-false}" == "true" ]] && enable_service update-check
  # Public join-info watcher (opt-in via PUBLIC_HOSTNAME); publishes IP/port/
  # password changes to Discord.
  [[ -n "${PUBLIC_HOSTNAME:-}" ]] && enable_service public-info-watch
  # Crash/restart watchdog: records unexpected restarts for the health report.
  enable_service service-events
  # Memory watchdog runs as root (needs s6 service control) and restarts the
  # server's s6 service when memory is high.
  enable_service memory-watch
  # Root half of the web UI control plane. Paired with config-webui (enabled
  # just above): without it, jobs the UI accepts would sit in the queue forever.
  enable_service jobd
  # Scheduled world-save backups + retention, embedded only (there is no world
  # tree to tar in external mode). Enabled unconditionally and *not* gated on a
  # BACKUP_* variable: whether a backup happens is BACKUP_ENABLED's business,
  # decided per tick inside palworld-backups, so switching backups off from the
  # panel needs no service change and switching them back on needs no recreate.
  enable_service backup-auto

  # Upgrade guard for the release that moved /opt/palworld/backups onto its own
  # volume. Before it, archives lived in the container's writable layer, which
  # `docker compose up --force-recreate` (or `up -d` after a `git pull`) destroys
  # along with the old container — and the fresh, EMPTY palwarden-backups volume
  # that replaces it looks exactly like a first boot. Losing the operator's whole
  # backup history on the upgrade whose entire point is that backups survive a
  # recreate is the worst possible ordering, so say so rather than start quietly.
  #
  # "Not a first boot" is inferred from the world: palworld-saved carrying a
  # SaveGames tree while the backups directory is empty is the shape an upgraded
  # stack has and a genuinely fresh one does not. It over-warns for one case (a
  # pre-seeded world with no backups yet), which is the right way round — the line
  # is advice, nothing acts on it.
  BACKUPS_DIR="${PALWARDEN_SAVE_BACKUP_DIR:-/opt/palworld/backups}"
  if [[ -d "$BACKUPS_DIR" && -z "$(ls -A "$BACKUPS_DIR" 2>/dev/null)" \
        && -n "$(ls -A "$INSTALL_DIR/Pal/Saved/SaveGames" 2>/dev/null)" ]]; then
    log "WARNING: $BACKUPS_DIR is empty but this world already has saves — if you just upgraded, older archives lived in the previous container's writable layer and are NOT in the palwarden-backups volume; they are recoverable only from a still-existing old container ('docker compose cp <old-container>:/opt/palworld/backups ./backups-migrate'). See docker/README.md, 'Upgrading from a pre-volume image'." >&2
  fi
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
