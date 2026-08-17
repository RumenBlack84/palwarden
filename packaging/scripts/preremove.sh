#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Shared preremove for deb/rpm/arch. Only stop things on REAL removal, never
# on upgrade: dpkg calls prerm with "upgrade" when upgrading, rpm calls preun
# with "1"; pacman only runs pre_remove on true removal (upgrades use
# pre_upgrade, which nfpm does not install), so its version-string argument
# falls through to the removal branch by design.
set -eu

case "${1:-}" in
  upgrade|1|2) exit 0 ;;
esac

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  # palworld.service last and stopped gracefully: KillSignal=SIGINT with
  # TimeoutStopSec=120 gives the server time to save the world.
  for unit in palworld-backup-auto.timer palworld-fps-sample.timer \
              palworld-fps-daily-report.timer palworld-memory-watch.timer \
              palworld-public-info-watch.timer palworld-service-events.timer \
              palworld-update-check.timer palworld-1dot0-watch.timer \
              palworld-config-webui.service palwarden-jobd.service \
              palworld.service; do
    systemctl disable --now "$unit" 2>/dev/null || true
  done
fi
