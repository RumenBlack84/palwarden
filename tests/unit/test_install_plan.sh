#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# install.sh is the *only* place the bare-metal platform is described, and the
# integration suite is Docker/s6 only — it structurally cannot exercise a systemd
# install. So four findings that only exist on that path are pinned here, through
# the installer's own --dry-run plan (real output from the real code path, not a
# grep of the source):
#
#   * the snapshot and save-backup roots are root-owned, not service-account-owned
#     (the arbitrary-root-write/chown class removed in palworld-config-snapshot);
#   * /var/lib/palworld/metrics.sqlite3 is pre-created service-account-owned, as
#     docker/entrypoint.sh already did — SQLite runs `PRAGMA journal_mode=WAL` on
#     every connect(), so a root-created DB made /api/fps, /api/events,
#     /api/service-events and part of /api/health fail with "attempt to write a
#     readonly database" for the unprivileged web UI on every fresh install;
#   * the `current` symlink into the live config directory is created at install
#     time (only the container's s6 run script did it, so the Engine.ini editor's
#     `fetch('current/Engine.ini')` preloaded nothing on bare metal);
#   * the two control-plane units are refreshed, not just daemon-reloaded. This
#     release changed palworld-config-webui.service's ExecStart from an
#     UNAUTHENTICATED `python3 -m http.server` to `palwarden-webui --serve`, so an
#     upgrade that only ran daemon-reload left the old unauthenticated server live.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
INSTALL="$DIR/../../install.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PLAN="$WORK/plan.txt"

# --dry-run touches nothing and needs no root, so this is the whole plan.
bash "$INSTALL" --dry-run > "$PLAN" 2>&1
assert_eq "$?" "0" "install.sh --dry-run exits cleanly"

# --- nothing is actually done ------------------------------------------------
# The point of asserting on --dry-run at all: every line is prefixed, so a command
# that escaped `run` would show up as a side effect instead.
assert_file_contains "$PLAN" "DRY-RUN: install -d" "the plan is printed, not executed"
if [ -e /opt/palworld/config-snapshots ] && [ ! -d /opt/palworld ]; then
  fail "--dry-run created something under /opt"
else
  pass
fi

# --- the snapshot and save-backup roots are root-owned ------------------------
assert_file_contains "$PLAN" "install -d -m 0755 -o root -g root /opt/palworld/backups" \
  "the save-backup root is created root-owned"
assert_file_contains "$PLAN" "install -d -m 0755 -o root -g root /opt/palworld/config-snapshots" \
  "the snapshot root is created root-owned"
# ...and are NOT in the service-account loop, which is where they used to be. A
# second `install -d` with -o "$SVC_USER" would silently undo the line above.
snap_lines="$(grep -c 'install -d.*config-snapshots' "$PLAN")"
assert_eq "$snap_lines" "1" "the snapshot root is created exactly once"
backup_lines="$(grep -c 'install -d.*/opt/palworld/backups' "$PLAN")"
assert_eq "$backup_lines" "1" "the save-backup root is created exactly once"

# The queue directory, by contrast, MUST stay service-account-owned: the
# unprivileged web UI is its only writer and it is 0700, so a root-owned queue
# means the UI cannot enqueue anything at all.
assert_file_contains "$PLAN" "install -d -m 0700" "the job queue keeps its 0700 mode"
assert_file_not_contains "$PLAN" "install -d -m 0700 -o root -g root /var/lib/palworld/jobs" \
  "the job queue is NOT forced root-owned"

# --- the telemetry DB is pre-created ----------------------------------------
assert_file_contains "$PLAN" "/var/lib/palworld/metrics.sqlite3" \
  "the telemetry DB is pre-created so the unprivileged web UI can open it"
assert_file_contains "$PLAN" "install -m 0644" "and as a file, not a directory"

# --- the `current` symlink ---------------------------------------------------
assert_file_contains "$PLAN" \
  "ln -sfn /opt/palworld/server/Pal/Saved/Config/LinuxServer /opt/palworld/tools/config-webui/current" \
  "the current -> live config symlink is created at install time"
# It must not come with a ReadWritePaths for the web root: root creates it at
# install time precisely so the service does not need write access at runtime.
assert_file_not_contains "$DIR/../../systemd/palworld-config-webui.service" \
  "ReadWritePaths=/opt/palworld/tools" \
  "the web UI unit is not given write access to its own web root just for that link"

# --- the control-plane units are refreshed ----------------------------------
assert_file_contains "$PLAN" "systemctl daemon-reload" "systemd is reloaded"
assert_file_contains "$PLAN" "try-restart" "running control-plane units are restarted"
assert_file_contains "$PLAN" "palworld-config-webui.service" "the web UI is one of them"
assert_file_contains "$PLAN" "palwarden-jobd.service" "and the job worker is the other"
assert_file_contains "$PLAN" "enable palwarden-jobd.service" \
  "jobd is enabled when the web UI already is (they are a required pair)"
# try-restart, never restart/start: the installer must not start a unit the
# operator chose not to run. Asserted against the ACTIONS only — the plan also
# prints "Next steps" advice that legitimately suggests `enable --now` to the
# operator, and matching that would make this assertion vacuous.
grep '^DRY-RUN:' "$PLAN" > "$WORK/actions.txt"
assert_file_not_contains "$WORK/actions.txt" "systemctl start" "no unit is started outright"
assert_file_not_contains "$WORK/actions.txt" "enable --now" "and none is enabled --now"
assert_file_not_contains "$WORK/actions.txt" "systemctl restart" "restart is never unconditional"
# --dry-run must not query the live system to decide what to print, either.
assert_file_not_contains "$WORK/actions.txt" "is-enabled" "the dry run does not resolve live unit state"

assert_report
