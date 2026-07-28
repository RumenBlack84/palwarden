#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palworld-backup runs as ROOT — jobd's `backup` action, or a hand-run command —
# and hardcoded the account name twice: `install -d -o palworld -g palworld` and
# `chown palworld:palworld`. There is no `palworld` account in the container (it is
# `steam`), so the very first command failed with "invalid user 'palworld'" before
# tar ever ran: the `backup` action could never succeed there, and nothing covered
# it. The same bug palworld-config-snapshot already had fixed.
#
# The save-backup root is also root-owned now, not service-account-owned: root
# writes a path derived from the current UTC second — entirely predictable — so an
# unprivileged owner of that directory could plant a symlink at the name and have
# root's tar and chown follow it out of the tree. Same reasoning as
# sbin/palworld-config-snapshot's note.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
BACKUP="$DIR/../../sbin/palworld-backup"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A minimal Saved tree: the tool tars exactly SaveGames and Config from it.
mkdir -p "$WORK/saved/SaveGames" "$WORK/saved/Config"
printf 'save\n' > "$WORK/saved/SaveGames/level.sav"
printf 'cfg\n' > "$WORK/saved/Config/PalWorldSettings.ini"

ME="$(id -un)"
MY_GROUP="$(id -gn)"
# A secondary group is the only ownership change an unprivileged test can observe:
# creation already gives the primary group, so asserting on it would pass whether
# or not the chown ran at all.
ALT_GROUP="$(id -Gn | tr ' ' '\n' | grep -vx "$MY_GROUP" | head -1)"

backup() {  # backup <dest-root> [env...]
  env PALWARDEN_SAVE_BACKUP_DIR="$1" PALWORLD_SAVED_DIR="$WORK/saved" \
      "${@:2}" bash "$BACKUP"
}

# --- the happy path, with no PALWORLD_USER at all ----------------------------
# Directory creation must no longer depend on the account resolving: that is the
# half that made the container fail outright. Nothing is passed for
# PALWORLD_USER/GROUP here, so they default to `palworld` — which does not exist on
# a dev box or in the container — and the backup must still be produced.
out="$(backup "$WORK/b1" 2>"$WORK/err1")"
rc=$?
assert_eq "$rc" "0" "backup succeeds even when the default account does not exist"
if [ -s "$out" ]; then pass; else fail "no tarball produced at '$out'"; fi
assert_contains "$out" "palworld-save-" "the archive keeps its documented name shape"
assert_eq "$(stat -c '%a' "$WORK/b1")" "755" "the backup dir is 0755"
# tar really captured both trees, so a passing run is not an empty archive.
listing="$(tar -tzf "$out")"
assert_contains "$listing" "SaveGames/level.sav" "the archive contains the saves"
assert_contains "$listing" "Config/PalWorldSettings.ini" "and the config"

# --- the account name comes from the environment -----------------------------
# The chown of the finished archive is the one place a name is still used. Ask for
# a secondary group: an unprivileged chown to it succeeds, so the group on the
# tarball proves the value was read from PALWORLD_GROUP rather than hardcoded.
if [ -n "$ALT_GROUP" ]; then
  out="$(backup "$WORK/b2" PALWORLD_USER="$ME" PALWORLD_GROUP="$ALT_GROUP" 2>"$WORK/err2")"
  assert_eq "$(stat -c '%U %G' "$out")" "$ME $ALT_GROUP" \
    "the archive owner comes from PALWORLD_USER/PALWORLD_GROUP"
  assert_eq "$(wc -c < "$WORK/err2" | tr -d ' ')" "0" "a resolvable account is silent"
else
  echo "  SKIP: $ME has no secondary group, so an unprivileged chown is unobservable"
fi

# --- an unresolvable account warns, and the backup still succeeds ------------
# Non-fatal on purpose (a root-owned backup beats no backup) but never silent —
# the swallowed LookupError in palworld-config-snapshot is exactly how the
# container breakage stayed invisible for so long.
out="$(backup "$WORK/b3" PALWORLD_USER="definitely-no-such-user" \
        PALWORLD_GROUP="definitely-no-such-group" 2>"$WORK/err3")"
rc=$?
assert_eq "$rc" "0" "an unresolvable account does not fail the backup"
if [ -s "$out" ]; then pass; else fail "no tarball produced with an unresolvable account"; fi
assert_file_contains "$WORK/err3" "definitely-no-such-user" \
  "the warning names the account it could not use"
assert_file_contains "$WORK/err3" "Warning" "and says it is a warning, not a failure"

# --- a failed tar leaves nothing that looks like an archive ------------------
# The whole reason the archive is written to a dot-prefixed `.partial` name and
# renamed only on success. A tar that dies mid-write used to leave a truncated
# `palworld-save-<stamp>.tar.gz` at the final name — and `palworld-backups
# --if-due` accepts an archive *by name*, so that file made the tick believe a
# backup had just been taken and create nothing for the whole interval, while the
# panel offered the corrupt file for restore.
#
# The failure is provoked the way the container actually hit it: a Saved tree with
# no SaveGames. tar prints "Cannot stat", exits 2, and (before this fix) still left
# a valid Config-only archive at the final name.
mkdir -p "$WORK/half/Config"
printf 'cfg\n' > "$WORK/half/Config/PalWorldSettings.ini"
out="$(env PALWARDEN_SAVE_BACKUP_DIR="$WORK/b4" PALWORLD_SAVED_DIR="$WORK/half" \
        bash "$BACKUP" 2>"$WORK/err4")"
rc=$?
assert_ne "$rc" "0" "a tar that cannot read the world fails the backup"
left="$(find "$WORK/b4" -maxdepth 1 -name 'palworld-save-*.tar.gz' | wc -l | tr -d ' ')"
assert_eq "$left" "0" "...and leaves no archive at the final name"
# Nor a stray partial: it is invisible to the tool either way (the dot prefix fails
# valid_archive_name), but leaking one per failed tick would fill the volume the
# next real backup needs.
left="$(find "$WORK/b4" -maxdepth 1 -name '.palworld-save-*' | wc -l | tr -d ' ')"
assert_eq "$left" "0" "...and cleans up its own partial"

# --- no hardcoded account name survives in the source ------------------------
# A deletion tripwire: the assertions above run unprivileged, where `install -d -o`
# is a no-op we cannot exercise, so pin the source directly. Any `-o palworld` or
# `chown palworld:` is the container-breaking bug returning.
assert_file_not_contains "$BACKUP" "-o palworld" "no hardcoded install owner"
assert_file_not_contains "$BACKUP" "chown palworld:palworld" "no hardcoded chown target"

assert_report
