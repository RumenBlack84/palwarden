#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Shared postinstall for deb/rpm/arch (nfpm embeds this one script in all
# three, so it must stay POSIX sh and tolerate every packager's arguments:
# dpkg passes "configure", rpm passes 1/2, pacman passes version strings).
# Runs on both fresh install and upgrade; every step below is idempotent and
# correct for either case, so the argument is deliberately ignored.
set -eu

# 1. Service account, then the runtime directory tree that references it.
#    Both tools work standalone (no booted systemd required) and are also
#    re-applied by systemd on every boot, making ownership self-healing.
if command -v systemd-sysusers >/dev/null 2>&1; then
  systemd-sysusers /usr/lib/sysusers.d/palwarden.conf
elif ! getent passwd palworld >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /opt/palworld/server \
    --no-create-home --shell /usr/sbin/nologin palworld
fi
if command -v systemd-tmpfiles >/dev/null 2>&1; then
  # tmpfiles exits nonzero for lines it merely could not fully apply (e.g.
  # under a container overlay); the units still enforce it at boot.
  systemd-tmpfiles --create /usr/lib/tmpfiles.d/palwarden.conf || true
fi

# 2. Web UI credentials: generated once, never overwritten. Root-owned,
#    group-readable so the unprivileged webui (User=palworld) can read but
#    never rewrite WEBUI_TOKEN (install.sh step 4b).
/usr/local/sbin/palwarden-webui --init-credentials
chown root:palworld /etc/palworld/webui.env
chmod 0640 /etc/palworld/webui.env

# An operator-created settings.env from before the authenticated webui is
# typically 0600 root:root — but the webui answers /api/health by running
# palworld-health-report as the service account, which reads the REST
# AdminPassword from this file. Unreadable, every REST-backed panel degrades
# (the dashboard shows "?/?" players). Same posture as webui.env: root-writable
# only, service-account-readable. The docker path does the equivalent chown in
# entrypoint.sh.
if [ -f /etc/palworld/settings.env ]; then
  chown root:palworld /etc/palworld/settings.env
  chmod 0640 /etc/palworld/settings.env
fi

# 3. Unit refresh — same logic and reasoning as install.sh's refresh_units():
#    daemon-reload alone does not touch running processes, and a stale
#    palworld-config-webui once kept serving unauthenticated after upgrade.
#    try-restart only acts on already-running units, and jobd is enabled only
#    when the web UI already is, so this never starts anything the operator
#    chose not to run. /run/systemd/system is the canonical booted-with-
#    systemd test (is-system-running fails on merely degraded systems).
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  if systemctl is-enabled --quiet palworld-config-webui.service 2>/dev/null \
     && ! systemctl is-enabled --quiet palwarden-jobd.service 2>/dev/null; then
    echo "palwarden: enabling palwarden-jobd.service (the web UI is enabled and" >&2
    echo "palwarden: cannot execute any queued action without it)" >&2
    systemctl enable palwarden-jobd.service
  fi
  # The .timer, not the backup .service: daemon-reload does not re-arm a
  # running timer, and try-restart on a Type=oneshot would fire a backup.
  for unit in palworld-config-webui.service palwarden-jobd.service \
              palworld-backup-auto.timer; do
    systemctl try-restart "$unit" || true
  done
else
  echo "palwarden: systemd not running; run 'systemctl daemon-reload' and" >&2
  echo "palwarden: restart palworld-config-webui.service / palwarden-jobd.service" >&2
  echo "palwarden: on the target host." >&2
fi
