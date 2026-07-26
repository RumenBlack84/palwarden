#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palworld-config-pretty renders the human-readable copy of PalWorldSettings.ini.
#
# It runs as root (jobd's config_pretty action, which is non-disruptive and needs
# no confirmation) against a directory the unprivileged game/web user owns and
# must be able to write. So both ends of the render are attacker-controlled names:
# a symlink at the destination would take root's write plus the chown/chmod that
# follows it, and a symlink at the source would copy a root-only file into a 0644
# output owned by that user. Both must be refused, with the plain output and
# ownership unchanged for a legitimate run.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
TOOL="$DIR/../../sbin/palworld-config-pretty"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cfg"

SRC="$WORK/cfg/PalWorldSettings.ini"
DST="$WORK/cfg/PalWorldSettings.pretty.ini"
# fchown needs a real uid/gid; use whoever runs the suite so the ownership path
# is genuinely exercised on a host with no palworld user.
PALWORLD_USER="$(id -un)"; PALWORLD_GROUP="$(id -gn)"
export PALWORLD_USER PALWORLD_GROUP

pretty() {
  PALWORLD_CONFIG_FILE="$SRC" PALWORLD_CONFIG_PRETTY_INI="$DST" bash "$TOOL" 2>&1
}

cat > "$SRC" <<'EOF'
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(Difficulty=None,DayTimeSpeedRate=1.000000,ServerName="my, server",ServerPassword="")
EOF

# --- a legitimate render still works, unchanged -----------------------------
out="$(pretty)"; rc=$?
assert_eq "$rc" "0" "a legitimate render succeeds"
assert_eq "$out" "$DST" "still prints the destination path and nothing else"
assert_file_contains "$DST" "Human-readable reference only" "wrote the header"
assert_file_contains "$DST" "    Difficulty=None," "split one setting per line"
assert_file_contains "$DST" "ServerName=\"my, server\"" "a comma inside a quoted value did not split it"
assert_eq "$(stat -c %a "$DST")" "644" "destination is 0644"
assert_eq "$(stat -c %U:%G "$DST")" "$(id -un):$(id -gn)" "destination owned by PALWORLD_USER:PALWORLD_GROUP"

# --- a symlinked DESTINATION is refused -------------------------------------
# Pre-fix this overwrote the target, chmod'd it 0644 and chowned it to the web
# user: point it at /etc/shadow and that is full root.
printf 'ROOT_ONLY_SECRET_CONTENT\n' > "$WORK/victim"
chmod 0600 "$WORK/victim"
rm -f "$DST"; ln -s "$WORK/victim" "$DST"
out="$(pretty)"; rc=$?
assert_ne "$rc" "0" "a symlinked destination is refused"
assert_contains "$out" "must not be a symlink" "says it refused a symlink"
assert_contains "$out" "PalWorldSettings.pretty.ini" "names the file it refused"
assert_not_contains "$out" "Too many levels" "not the raw ELOOP strerror"
assert_not_contains "$out" "Traceback" "the refusal is a message, not a crash"
assert_file_contains "$WORK/victim" "ROOT_ONLY_SECRET_CONTENT" "victim content unchanged"
assert_file_not_contains "$WORK/victim" "Human-readable reference only" "nothing was written through the link"
assert_eq "$(stat -c %a "$WORK/victim")" "600" "victim mode still 0600"
rm -f "$DST"

# --- a symlinked SOURCE is refused too --------------------------------------
# The output is 0644 and owned by the web user, so reading the source through a
# link publishes whatever it points at.
printf 'ADMIN_PASSWORD=hunter2\n' > "$WORK/secret.env"
chmod 0600 "$WORK/secret.env"
mv "$SRC" "$WORK/real-settings.ini"
ln -s "$WORK/secret.env" "$SRC"
out="$(pretty)"; rc=$?
assert_ne "$rc" "0" "a symlinked source is refused"
assert_contains "$out" "must not be a symlink" "says why the source was refused"
assert_eq "$([ -e "$DST" ] && echo present || echo absent)" "absent" "no output written from a symlinked source"
rm -f "$SRC"
mv "$WORK/real-settings.ini" "$SRC"

# --- an unknown owner is reported, but does not cost the render --------------
out="$(export PALWORLD_USER=definitely-no-such-user; pretty)"; rc=$?
assert_eq "$rc" "0" "an unknown PALWORLD_USER does not fail the render"
assert_contains "$out" "definitely-no-such-user" "names the owner it could not resolve"
assert_file_contains "$DST" "Human-readable reference only" "the render still happened"

# --- a FIFO at the destination must not hang root (denial of service) ------
# O_NOFOLLOW refuses a symlink but says nothing about a FIFO: without
# O_NONBLOCK, opening one for write blocks until a reader attaches, wedging
# root's job worker for the full subprocess timeout. `timeout` wraps this call
# so a regression fails in a few seconds instead of hanging the suite.
rm -f "$DST"; mkfifo "$DST"
# shellcheck disable=SC2016  # $1/$2/$3 expand in the inner bash -c, not here
out="$(timeout 5 bash -c 'PALWORLD_CONFIG_FILE="$1" PALWORLD_CONFIG_PRETTY_INI="$2" bash "$3"' _ "$SRC" "$DST" "$TOOL" 2>&1)"; rc=$?
assert_ne "$rc" "0" "a FIFO at the destination is refused, not followed"
assert_ne "$rc" "124" "the FIFO refusal happens well before the timeout fires"
assert_contains "$out" "PalWorldSettings.pretty.ini" "the FIFO refusal names the file"
assert_contains "$out" "regular file" "the FIFO refusal says it is not a regular file"
assert_not_contains "$out" "Traceback" "the FIFO refusal is a message, not a crash"
rm -f "$DST"

# --- the same FIFO, but with a reader already attached ----------------------
# With no reader, O_NONBLOCK|O_WRONLY fails at open() with ENXIO before the
# fstat check ever runs. That is not the only guard: if the attacker keeps a
# reader attached (so the open succeeds), the fstat/S_ISREG rejection is what
# still catches it. Exercise that path explicitly, not just the ENXIO one.
mkfifo "$DST"
( timeout 8 cat "$DST" >/dev/null & )
sleep 0.3
# shellcheck disable=SC2016  # $1/$2/$3 expand in the inner bash -c, not here
out="$(timeout 5 bash -c 'PALWORLD_CONFIG_FILE="$1" PALWORLD_CONFIG_PRETTY_INI="$2" bash "$3"' _ "$SRC" "$DST" "$TOOL" 2>&1)"; rc=$?
assert_ne "$rc" "0" "a FIFO with a reader attached is still refused"
assert_ne "$rc" "124" "the refusal with a reader attached happens well before the timeout fires"
assert_contains "$out" "PalWorldSettings.pretty.ini" "the refusal names the file even with a reader attached"
assert_contains "$out" "regular file" "the refusal (via fstat, not ENXIO) says it is not a regular file"
assert_not_contains "$out" "Traceback" "the refusal is a message, not a crash"
wait
rm -f "$DST"

assert_report
