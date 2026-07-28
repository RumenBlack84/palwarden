#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden installer
#
# Deploys the Palworld operational tooling from this repository to the
# filesystem locations the scripts and systemd units expect. This reproduces
# the original absolute-path layout that used to live under raw-root/.
#
# Usage:
#   sudo ./install.sh [--dry-run] [--force-config]
#
#   --dry-run        Print what would be installed without changing anything.
#   --force-config   Overwrite existing /etc/palworld/engine.env (normally
#                    preserved because it is live tuning state, not a template).
#
# This installer does NOT install the Palworld dedicated server itself, and it
# does NOT create live secret files (/etc/palworld/settings.env,
# /etc/palworld/notify.env). See README.md for those steps.

set -euo pipefail

DRY_RUN=0
FORCE_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force-config) FORCE_CONFIG=1 ;;
    -h|--help) sed -n '5,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVC_USER="palworld"
SVC_GROUP="palworld"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    "$@"
  fi
}

need_root() {
  if [[ "$DRY_RUN" -eq 0 && "$(id -u)" -ne 0 ]]; then
    echo "This installer must run as root (or with --dry-run). Try: sudo $0" >&2
    exit 1
  fi
}

# install_files <mode> <dest-dir> <src...>
install_files() {
  local mode="$1" dest="$2"; shift 2
  run install -d -m 0755 "$dest"
  local f
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    run install -m "$mode" "$f" "$dest/$(basename "$f")"
  done
}

need_root

echo "==> Installing palwarden from $REPO_DIR"

# 1. Operational scripts, helper binary, and libraries.
install_files 0755 /usr/local/sbin "$REPO_DIR"/sbin/*
install_files 0755 /usr/local/bin  "$REPO_DIR"/bin/palworld-config-parser
install_files 0755 /usr/local/lib  "$REPO_DIR"/lib/*

# 2. systemd units and timers.
install_files 0644 /etc/systemd/system "$REPO_DIR"/systemd/*.service "$REPO_DIR"/systemd/*.timer

# 3. needrestart guard/restart hooks.
install_files 0644 /etc/needrestart/conf.d    "$REPO_DIR"/needrestart/conf.d/*
install_files 0755 /etc/needrestart/restart.d "$REPO_DIR"/needrestart/restart.d/*

# 4. Config templates. Never clobber live settings.env / notify.env.
run install -d -m 0755 /etc/palworld
install_files 0644 /etc/palworld "$REPO_DIR"/config/settings.env.example
if [[ -f /etc/palworld/engine.env && "$FORCE_CONFIG" -eq 0 ]]; then
  echo "    keeping existing /etc/palworld/engine.env (use --force-config to overwrite)"
else
  install_files 0644 /etc/palworld "$REPO_DIR"/config/engine.env
fi
# The scheduled-backup settings, treated exactly like engine.env and for the same
# reason: it is live tuning state, not a template. The backup panel rewrites this
# whole file through palwarden-jobd's backup_schedule_save action, so overwriting
# it on every install would silently revert a retention policy the operator set
# from the browser.
if [[ -f /etc/palworld/backup.env && "$FORCE_CONFIG" -eq 0 ]]; then
  echo "    keeping existing /etc/palworld/backup.env (use --force-config to overwrite)"
else
  install_files 0644 /etc/palworld "$REPO_DIR"/config/backup.env
fi

# 4b. Web UI credentials (generated once; never overwritten). Owned by root,
# readable only by the webui service group, so the unprivileged palwarden-webui
# process (User=palworld) can read it but never rewrite WEBUI_TOKEN, which a
# future root job worker will trust.
run /usr/local/sbin/palwarden-webui --init-credentials
if getent group "$SVC_GROUP" >/dev/null 2>&1; then
  run chown root:"$SVC_GROUP" /etc/palworld/webui.env
  run chmod 0640 /etc/palworld/webui.env
else
  echo "    note: group '$SVC_GROUP' not found; webui.env left root:root 0600." \
       "Create the group and 'chown root:$SVC_GROUP /etc/palworld/webui.env; chmod 0640 ...' before starting the service."
fi

# 5. Web UI and reference docs under /opt/palworld/tools.
install_files 0644 /opt/palworld/tools/config-webui "$REPO_DIR"/webui/*
install_files 0644 /opt/palworld/tools "$REPO_DIR"/docs/config-tools.md "$REPO_DIR"/docs/backlog.md

# 5b. The `current` symlink into the live config directory. palwarden-webui serves
# it read-only (see allowed_roots there) and both editors fetch through it —
# EngineIniPerformanceEditor.html does `fetch('current/Engine.ini')` to preload the
# values it is about to edit. The container's s6 run script creates it at start,
# but nothing on the systemd path did, so on bare metal the editors silently
# preloaded nothing. Created here, by root, at install time: the service runs under
# ProtectSystem=strict without ReadWritePaths for its own web root and does not
# need to create it at runtime, so it must not be given write access just for this.
run ln -sfn /opt/palworld/server/Pal/Saved/Config/LinuxServer \
  /opt/palworld/tools/config-webui/current

# 6. Runtime directories used by the tooling (owned by the service account when
#    it exists; otherwise left root-owned for the operator to adjust).
owner_args=()
if getent passwd "$SVC_USER" >/dev/null 2>&1; then
  owner_args=(-o "$SVC_USER" -g "$SVC_GROUP")
else
  echo "    note: user '$SVC_USER' not found; runtime dirs left root-owned. Create it and chown as needed."
  # Not merely inconvenient for one of them: /var/lib/palworld/jobs is 0700 and
  # the web UI runs as $SVC_USER, so root ownership means it cannot create a
  # single job file — every button in the UI fails with no way to retry.
  echo "          in particular /var/lib/palworld/jobs must be owned by '$SVC_USER':"
  echo "          it is 0700 and the web UI writes jobs into it, so while it is"
  echo "          root-owned the UI cannot queue ANY action (every request fails)."
fi
for d in /var/lib/palworld /var/log/palworld /opt/palworld/config-backups; do
  run install -d -m 0755 "${owner_args[@]}" "$d"
done
# Snapshot and save-backup roots are deliberately root-owned, unlike the dirs
# above. Both are written *only* by root (palwarden-jobd's snapshot_create /
# backup actions, or a hand-run sudo) and only ever listed by the unprivileged
# web UI, which 0755 already allows. When they were service-account-owned, root
# wrote predictable, attacker-named paths into a directory a less-privileged
# process could rename out from under it — see the long note in
# sbin/palworld-config-snapshot.
for d in /opt/palworld/backups /opt/palworld/config-snapshots; do
  run install -d -m 0755 -o root -g root "$d"
done
# The control plane's job queue: written only by the unprivileged web UI (hence
# the service account, not root), read and updated by the root worker
# palwarden-jobd. 0700 because job files can carry config values.
run install -d -m 0700 "${owner_args[@]}" /var/lib/palworld/jobs
# The backup panel's two directories, 0700 with deliberately *opposite* owners.
#
# uploads is the job queue's twin: the unprivileged web UI streams a browser
# upload straight into it, and palwarden-webui refuses an upload outright unless it
# owns this directory with no group/other bits. Service-account-owned for exactly
# the reason the queue is. (palwarden-webui also creates it on demand, so a host
# that skipped this line still works — but the first upload is not the place to
# discover a packaging gap.)
run install -d -m 0700 "${owner_args[@]}" /var/lib/palworld/uploads
# restore-scratch is the opposite: root:root, and under the root-owned
# /opt/palworld rather than beside uploads. palworld-restore copies an archive here
# and validates *the copy*, because every archive in the backups directory is
# chowned to the service account and so is writable by the web process —
# validating one in place would prove the name and not the bytes. That argument
# needs the whole parent chain root-owned, which /var/lib/palworld is not (it is
# 0755 service-account-owned, a few lines up): the service account could
# pre-create the scratch directory, or rename root's aside and drop its own at the
# same name, and a substituted archive would then be restored while the job
# reported success. palworld-restore verifies the directory it opened and refuses
# otherwise, so getting this wrong is a clean refusal rather than a silent hole.
run install -d -m 0700 -o root -g root /opt/palworld/restore-scratch

# The telemetry DB, pre-created service-account-owned — the same thing
# docker/entrypoint.sh does, and for the same reason. SQLite runs
# `PRAGMA journal_mode=WAL` on *every* connect(), which is a write, so a
# root-owned DB is unreadable to the unprivileged side: palworld-fps-sample.service
# has no User= and so created it as root on first use, after which palwarden-webui
# (User=$SVC_USER) failed /api/fps, /api/events, /api/service-events and part of
# /api/health with "attempt to write a readonly database". Never clobbered: an
# existing DB is live telemetry.
if [[ ! -e /var/lib/palworld/metrics.sqlite3 ]]; then
  run install -m 0644 "${owner_args[@]}" /dev/null /var/lib/palworld/metrics.sqlite3
fi

# 7. Reload systemd so the new/updated units are visible, then refresh the two
#    control-plane units in place.
#
# A re-run of this installer used to stop at daemon-reload, which does not touch a
# running process. That was actively unsafe for one unit: this release changed
# palworld-config-webui.service's ExecStart from `python3 -m http.server 8088` — an
# unauthenticated static server for the config directory — to
# `palwarden-webui --serve`, which requires Basic auth and a token. So an operator
# re-ran install.sh, saw "Done", and kept serving the config directory with no
# authentication at all until the next reboot. And palwarden-jobd is new, so the
# web UI queued jobs nothing ever executed.
#
# try-restart, not restart: it restarts a unit only if it is already running, so
# this never *starts* something the operator chose not to run. Ditto the enable
# below, which is gated on the web UI already being enabled — the two halves of the
# control plane are now a required pair, but neither is enabled by this installer
# on its own.
refresh_units() {
  # /run/systemd/system is the canonical "booted with systemd" test (what Debian's
  # maintainer scripts use). `systemctl is-system-running` is not: it exits nonzero
  # for a merely `degraded` system, which is a perfectly restartable one.
  if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    echo "    note: systemd is not running here; skipped daemon-reload and unit refresh."
    echo "          run 'systemctl daemon-reload' and restart palworld-config-webui.service"
    echo "          and palwarden-jobd.service on the target host."
    return 0
  fi
  run systemctl daemon-reload
  if systemctl is-enabled --quiet palworld-config-webui.service 2>/dev/null \
     && ! systemctl is-enabled --quiet palwarden-jobd.service 2>/dev/null; then
    echo "    enabling palwarden-jobd.service (the web UI is enabled and cannot"
    echo "    execute any queued action without it)"
    run systemctl enable palwarden-jobd.service
  fi
  # palworld-backup-auto.timer joins the two control-plane units here rather than
  # being left to daemon-reload alone. daemon-reload re-reads unit files but does
  # not re-arm a timer that is already running, so an operator upgrading from a
  # release with a different tick would keep the old cadence until the next reboot.
  # The .timer and not the .service: try-restart only acts on a *running* unit, and
  # a Type=oneshot backup is running for a few seconds a day — restarting the timer
  # is what actually picks up a change, and it never triggers a backup itself.
  local unit
  for unit in palworld-config-webui.service palwarden-jobd.service \
              palworld-backup-auto.timer; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      echo "    restarting running unit $unit so it picks up this release"
    fi
    run systemctl try-restart "$unit"
  done
}
if [[ "$DRY_RUN" -eq 1 ]]; then
  # --dry-run must not query the live system either: is-enabled/is-active on the
  # installing host would decide what gets printed, so state the conditional
  # actions instead of resolving them.
  printf 'DRY-RUN: systemctl daemon-reload\n'
  printf 'DRY-RUN: systemctl enable palwarden-jobd.service (only if palworld-config-webui.service is already enabled)\n'
  printf 'DRY-RUN: systemctl try-restart palworld-config-webui.service palwarden-jobd.service palworld-backup-auto.timer (running units only)\n'
else
  refresh_units
fi

echo "==> Done."
echo
echo "Next steps:"
echo "  1. Create /etc/palworld/settings.env from the template and set your values:"
echo "       cp /etc/palworld/settings.env.example /etc/palworld/settings.env"
echo "  2. (Optional) Create /etc/palworld/notify.env with PALWORLD_DISCORD_WEBHOOK=... for alerts."
echo "  3. Enable the units/timers you want, e.g.:"
echo "       systemctl enable --now palworld.service"
echo "       systemctl enable --now palworld-fps-sample.timer palworld-update-check.timer"
echo "     The web UI needs both halves of the control plane — the unprivileged"
echo "     server and the root worker that executes the jobs it queues:"
echo "       systemctl enable --now palworld-config-webui.service palwarden-jobd.service"
echo "     Scheduled world-save backups + retention (the schedule itself lives in"
echo "     /etc/palworld/backup.env and is editable from the web UI's Backups page,"
echo "     so this timer only decides how often the tool is *asked*):"
echo "       systemctl enable --now palworld-backup-auto.timer"
echo "  See README.md for the full list and security notes."
