#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# The restore round-trip, against a REAL Palworld server. The highest-value test in
# the live tier, because `backup_restore` is the one flow whose every moving part —
# the graceful stop, the extraction, the swap by rename, the chown, the start, and
# the REST readiness confirmation — has only ever met tests/fixtures/fake-server.
# The disaster-recovery feature's central promise is "a world comes back", and a
# dummy server cannot be asked whether the game reopens what we put back.
#
# What separates this from scenario L of tests/integration/test_docker.sh is not the
# assertions; it is the subject. Scenario L bind-mounts a single fixture tree at
# /opt/palworld/server, so `Pal/Saved` there is an ordinary subdirectory. Both
# compose files mount the world on its own volume *at* /opt/palworld/server/Pal/Saved,
# which is the layout every real deployment runs. That difference is exactly the kind
# of thing a stub cannot surface, and it is the reason this file exists.
#
# SELF-CONTAINMENT IS THE RULE THAT MAKES THIS VALID. The tier accepts world drift:
# the testbed keeps its world between runs, there is no pristine snapshot and no
# reset. So every assertion below references something *this run* created, and the
# marker's contents carry a fresh nonce — an identical file left by an earlier run
# cannot satisfy them. Nothing here asserts on a file list, a save size, or any
# directory the game manages.
#
# Off by default; needs a marked testbed with a real install. See
# tests/live/lib/testbed.sh and docker/compose.live.yaml.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
source "$DIR/lib/testbed.sh"

# The guard first and on its own line, before anything is built or started: pointed
# at a real deployment this suite would stop the server and replace its world, so it
# must refuse before it has done anything at all — including before Docker is asked
# for anything. live_require_testbed exits nonzero itself on refusal.
live_require_testbed

# How long the restore job may take. Deliberately not LIVE_JOB_TIMEOUT's 300s: this
# one job contains a real save-on-stop, an extraction of a real world, a cold start of
# the game, and up to palworld-restore's own 180s readiness poll. Bounded all the
# same — an unbounded live suite is one nobody watches long enough to notice.
RESTORE_TIMEOUT="${PALWARDEN_LIVE_RESTORE_TIMEOUT:-900}"

# The marker lives *inside* SaveGames, not at the top of Pal/Saved, because
# palworld-backup archives exactly two members: `tar -C "$SAVED_DIR" ... SaveGames
# Config`. A marker beside those two would never enter the archive, and the round-trip
# assertion would then be checking a file the restore never touched — which would pass
# for entirely the wrong reason.
#
# Dot-prefixed and named for this suite so the game does not manage it: Palworld
# writes `SaveGames/<id>/*.sav` and rewrites its own config, but it has no interest in
# a dotfile at the SaveGames root, so it cannot rewrite or prune the one thing being
# asserted on underneath us.
HOST_SAVED="$TESTBED/server/Pal/Saved"
MARKER_REL="SaveGames/.palwarden-live-restore-marker"
HOST_MARKER="$HOST_SAVED/$MARKER_REL"

# A nonce, so that a marker file left behind by a previous run of this suite — with
# this exact path and plausibly this exact shape — cannot satisfy the round-trip
# assertion. This is the concrete form of the self-containment rule: the bytes being
# looked for did not exist before this process started.
NONCE="$$-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}${RANDOM}"
ORIGINAL="palwarden-live-restore ORIGINAL $NONCE"
MODIFIED="palwarden-live-restore MODIFIED $NONCE"

# --- bring the real thing up -------------------------------------------------
live_up || { fail "the live server did not become REST-ready"; assert_report; exit 1; }

# Only now, and never earlier: before live_up there is nothing to tear down, and
# live_down re-runs the guard, so a handler installed ahead of the guard would exit
# from inside itself on a refusal and bury the guard's message. Registered as a trap
# rather than called at the bottom so a failed assertion (or a `set -u` slip) still
# leaves the stack down instead of a real game server running for the next suite.
# The handler does not exit, so assert_report's status is still this script's status.
trap 'live_down >/dev/null 2>&1 || true' EXIT

# The game creates both of these when it first opens a world, and live_up has just
# confirmed the REST API answers, so both must be here. Checked explicitly because a
# missing SaveGames would otherwise surface much later as a `tar` failure inside a
# backup job — a confusing place to learn the testbed was never fully installed.
if [[ -d "$HOST_SAVED/SaveGames" ]]; then pass; else
  fail "$HOST_SAVED/SaveGames does not exist — the testbed has no world to back up"
  assert_report; exit 1
fi
assert_rc 0 test -d "$HOST_SAVED/Config"

# Write from the host, as the invoking user, which live_require_testbed has already
# proved is the uid the game runs as — so the marker is not the one root-owned file in
# a tree the server has to be able to rewrite.
printf '%s\n' "$ORIGINAL" > "$HOST_MARKER" \
  || { fail "cannot write the world marker $HOST_MARKER"; assert_report; exit 1; }
assert_file_exists "$HOST_MARKER" "the world marker is in place before the backup"

# --- 1. back the world up through the real queue -----------------------------
b_id="$(live_enqueue backup '{}')" || { fail "could not enqueue the backup job"; assert_report; exit 1; }
b_state="$(live_wait_job "$b_id")"
assert_eq "$b_state" "succeeded" "a backup of the real world runs to success (job $b_id)"

b_body="$(live_api GET "/api/jobs/$b_id")"
# palworld-backup prints the archive path as its last line, so the name is read out of
# the job's own output rather than by listing the directory: the scheduled tick may be
# enabled on this testbed, and `ls | head -1` would happily pick up its archive
# instead of the one this test just made.
ARCHIVE="$(printf '%s' "$b_body" | grep -oE 'palworld-save-[0-9]{8}T[0-9]{6}Z\.tar\.gz' | head -1)"
if [[ -n "$ARCHIVE" ]]; then pass; else
  fail "the backup job did not name an archive (body: $b_body)"
  assert_report; exit 1
fi

# --- 2. break the world ------------------------------------------------------
# Without this a restore that silently did nothing would pass every assertion below.
printf '%s\n' "$MODIFIED" > "$HOST_MARKER"
assert_file_contains "$HOST_MARKER" "$MODIFIED" "the world is modified before the restore"

# --- 3. restore it -----------------------------------------------------------
# wait:0 skips the player-warning window (nobody is playing), confirm:true is the gate
# jobd puts in front of every disruptive action.
r_id="$(live_enqueue backup_restore \
  "{\"backup\":\"$ARCHIVE\",\"wait\":0,\"confirm\":true}")" \
  || { fail "could not enqueue the restore job"; assert_report; exit 1; }
r_state="$(live_wait_job "$r_id" "$RESTORE_TIMEOUT")"
r_body="$(live_api GET "/api/jobs/$r_id")"
assert_eq "$r_state" "succeeded" "backup_restore runs to success against a real server (job $r_id)"

# --- 4. the world came back --------------------------------------------------
# The single assertion the whole tier is for. Against the ORIGINAL bytes, which
# carried this run's nonce, so nothing that predates this process can satisfy it.
assert_eq "$(cat "$HOST_MARKER" 2>/dev/null)" "$ORIGINAL" \
  "the restored world is the one that was backed up (real game, real world)"

# --- 5. the server genuinely came up -----------------------------------------
# Not "the job said succeeded": a restore that reports success over a dead server is
# precisely the failure this suite exists to catch, and palworld-restore's own
# readiness check is one of the parts that has never met a real game. So the question
# is put to /api/health, independently, after the fact.
#
# Parsed with python3 rather than grepped because the two fields that matter are both
# called `ok` at different depths and are not even the same type — collect_service
# stringifies its own (`"True"`), while collect_api's is a real boolean — so a flat
# grep for '"ok": true' cannot say *which* one it found. This is the assertion that
# must not be fooled.
h_body="$(live_api GET /api/health)"
h_vals="$(printf '%s' "$h_body" | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("unparseable"); print("unparseable"); raise SystemExit(0)
data = doc.get("data") or {}
service = data.get("service") or {}
api = data.get("api") or {}
print(service.get("active_state") or "missing")
print("true" if api.get("ok") is True else "false")
')"
assert_eq "$(printf '%s\n' "$h_vals" | sed -n 1p)" "active" \
  "after the restore /api/health reports the service active"
assert_eq "$(printf '%s\n' "$h_vals" | sed -n 2p)" "true" \
  "...and the game's REST API is reachable, so the world really did reopen"

# --- 6. the pre-restore safety archive ---------------------------------------
# A restore is supposed to archive what it is about to replace. Read out of the job's
# output rather than counted, because this testbed's backups directory accumulates
# across runs, so "there are now two archives" is not a statement that can hold here.
SAFETY="$(printf '%s' "$r_body" \
  | grep -oE 'safety backup: palworld-save-[0-9]{8}T[0-9]{6}Z\.tar\.gz' \
  | head -1 | sed 's/^safety backup: //')"
if [[ -n "$SAFETY" ]]; then pass; else
  fail "the restore job did not name a pre-restore safety archive (body: $r_body)"
fi
assert_ne "$SAFETY" "$ARCHIVE" "the safety archive is a new one, not the archive being restored"
# The backups directory is a named volume, not part of the testbed bind mount, so it
# is checked from inside the container rather than with assert_file_exists.
if [[ -n "$SAFETY" ]]; then
  assert_rc 0 live_exec test -f "/opt/palworld/backups/$SAFETY"
  assert_contains "$(live_api GET /api/backups)" "$SAFETY" \
    "...and /api/backups lists it, so the operator can actually undo this restore"
fi

# --- 7. the displaced tree ---------------------------------------------------
# palworld-restore renames the live world aside as Pal/Saved.replaced-<stamp>-<hex>
# and deletes it only on a *positive* readiness confirmation, so on a successful
# restore it must be gone.
#
# "Gone" is a weak claim on its own: an absent path is equally consistent with the
# tree never having been created — which is exactly what happens if the swap was
# skipped. So both halves are asserted. The job output naming the tree is what proves
# the rename happened; the path being absent is what proves the cleanup ran. Neither
# assertion is worth much without the other.
REPLACED="$(printf '%s' "$r_body" \
  | grep -oE 'Saved\.replaced-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}' | head -1)"
if [[ -n "$REPLACED" ]]; then pass; else
  fail "the restore job never named a replaced world tree, so the live world was not moved aside (body: $r_body)"
fi
assert_contains "$r_body" "cleaned up: removed the replaced world" \
  "the replaced tree is removed only on a confirmed startup, and that branch ran"
# Pal/ is inside the testbed's server bind mount, so the displaced tree is visible on
# the host and its absence is checkable directly.
if [[ -n "$REPLACED" ]]; then
  assert_path_absent "$TESTBED/server/Pal/$REPLACED" \
    "...so the tree the job named is no longer on disk"
fi

# live_down runs from the EXIT trap installed above, on every path out of here.
assert_report
