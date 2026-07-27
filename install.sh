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
for d in /var/lib/palworld /var/log/palworld \
         /opt/palworld/backups /opt/palworld/config-backups /opt/palworld/config-snapshots; do
  run install -d -m 0755 "${owner_args[@]}" "$d"
done
# The control plane's job queue: written only by the unprivileged web UI (hence
# the service account, not root), read and updated by the root worker
# palwarden-jobd. 0700 because job files can carry config values.
run install -d -m 0700 "${owner_args[@]}" /var/lib/palworld/jobs

# 7. Reload systemd so the new/updated units are visible.
run systemctl daemon-reload

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
echo "  See README.md for the full list and security notes."
