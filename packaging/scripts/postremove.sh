#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Shared postremove for deb/rpm/arch: forget the removed unit files. Runs on
# upgrade too (harmless — postinstall reloads again after the new files land).
# Live state is deliberately left behind: /etc/palworld/{settings,notify,
# webui}.env, /var/lib/palworld (telemetry, jobs), /opt/palworld (game,
# saves, backups) are operator data, not package payload.
set -eu

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
