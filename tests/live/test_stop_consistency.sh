#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Two things a stub server cannot be asked, against a REAL Palworld server. They
# share one file because they share the expensive part — a cold start of the actual
# game — and nothing else: neither scenario reads anything the other wrote.
#
#   1. SAVE-ON-STOP CONSISTENCY. The container stops the server with SIGINT
#      (docker/s6-rc.d/palworld-server's down-signal, reached here through
#      palworld-graceful-stop's `s6-svc -wD -d`) precisely so the game saves on the
#      way down. That the resulting world is one the game will *load again* is
#      asserted nowhere today — it is asserted by reading the down-signal and
#      trusting it. So: stop it, start it, and make the game answer.
#
#   2. A REAL SCHEDULED BACKUP. `palworld-backups --if-due` is well covered
#      hermetically, but the fixture's `Pal/Saved` is a handful of text files, so the
#      one claim that matters to an operator — the archive the tick produced can
#      actually be unpacked and holds the world — is the one claim the fixture cannot
#      make. Here the input is a genuine multi-hundred-megabyte world written by the
#      game itself, and the archive is really extracted.
#
# SELF-CONTAINMENT IS THE RULE THAT MAKES THIS VALID, exactly as in
# test_restore_roundtrip.sh. The tier keeps its world between runs, with no snapshot
# and no reset, so an assertion about world *state* would eventually pass or fail for
# reasons that have nothing to do with this run. Everything below therefore asserts
# on something this process created:
#
#   * the marker file carries a fresh nonce, so a marker left by an earlier run
#     cannot satisfy the archive assertion;
#   * scenario 2 runs against a private, empty backups directory created for this
#     run, so "an archive was created" and "nothing else appeared" are statements
#     about this run's directory and not about a volume that accumulates;
#   * the one assertion that does involve the game's own state (the set of world
#     directories) compares a reading taken *before* the stop with one taken after —
#     both by this run — rather than expecting any particular world to be there.
#
# Off by default; needs a marked testbed with a real install. See
# tests/live/lib/testbed.sh and docker/compose.live.yaml.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
source "$DIR/lib/testbed.sh"

# The guard first and on its own line, before anything is built or started: this
# suite stops a server and, pointed at a real deployment, would stop *that* one, so
# it must refuse before it has done anything at all — including before Docker is
# asked for anything. live_require_testbed exits nonzero itself on refusal.
live_require_testbed

# How long the graceful stop may take. Its own bound rather than LIVE_JOB_TIMEOUT's
# 300s because what is being waited for is a real save of a real world flushed on
# SIGINT, and compose gives that up to `stop_grace_period`; bounded all the same, an
# unbounded live suite being one nobody watches long enough to notice.
STOP_TIMEOUT="${PALWARDEN_LIVE_STOP_TIMEOUT:-420}"

HOST_SAVED="$TESTBED/server/Pal/Saved"
# Inside SaveGames, not at the top of Pal/Saved, and this is the trap Task 2 hit:
# palworld-backup archives exactly two members (`tar -C "$SAVED_DIR" ... SaveGames
# Config`), so a marker beside those two never enters an archive and scenario 2's
# "the archive contains what we put in the world" assertion would pass vacuously
# against a file the archive never held.
#
# Dot-prefixed and named for this suite so the game does not manage it: Palworld
# writes `SaveGames/<n>/<id>/*.sav` and rewrites its own config, but it has no
# interest in a dotfile at the SaveGames root, so it cannot rewrite or prune the one
# file being asserted on underneath us.
MARKER_REL="SaveGames/.palwarden-live-stop-marker"
HOST_MARKER="$HOST_SAVED/$MARKER_REL"

# The nonce is the concrete form of the self-containment rule: the bytes asserted on
# did not exist before this process started, so a file with this exact path and
# plausibly this exact shape left by a previous run cannot satisfy anything below.
NONCE="$$-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}${RANDOM}"
MARKER_TEXT="palwarden-live-stop-consistency $NONCE"

# Scenario 2's private workspace, inside the container. On the backups *volume*
# rather than /tmp for one blunt reason: what gets written here is a real world
# archive and then its extraction, so this needs room measured in gigabytes, and the
# backups volume is the one place in the image sized for exactly that. Dot-prefixed
# and a directory, so it is invisible to `palworld-backups`' own listing (which
# accepts only `palworld-save-<stamp>.tar.gz` names, and only regular files) and
# therefore cannot be mistaken for an archive by a real prune or by /api/backups.
BDIR="/opt/palworld/backups/.palwarden-live-stop-$NONCE"

# --- bring the real thing up -------------------------------------------------
live_up || { fail "the live server did not become REST-ready"; assert_report; exit 1; }

# Only now, and never earlier: before live_up there is nothing to tear down, and
# live_down re-runs the guard, so a handler installed ahead of the guard would exit
# from inside itself on a refusal and bury the guard's message. Registered as a trap
# rather than called at the bottom so a failed assertion (or a `set -u` slip) still
# leaves the stack down instead of a real game server running for the next suite.
# The handler does not exit, so assert_report's status is still this script's status.
#
# BDIR is removed *before* the stack goes down because it lives on a persistent
# volume: `live_down` takes no `-v` (deliberately — see live_down), so an extracted
# world left behind here would still be occupying that volume at the next run.
trap 'live_exec rm -rf -- "$BDIR" >/dev/null 2>&1 || true
      live_down >/dev/null 2>&1 || true' EXIT

# The game creates both of these when it first opens a world, and live_up has just
# confirmed the REST API answers, so both must be here. Checked explicitly because a
# missing SaveGames would otherwise surface as an unexplained `tar` failure inside
# scenario 2 — a confusing place to learn the testbed was never fully installed.
if [[ -d "$HOST_SAVED/SaveGames" ]]; then pass; else
  fail "$HOST_SAVED/SaveGames does not exist — the testbed has no world"
  assert_report; exit 1
fi
assert_rc 0 test -d "$HOST_SAVED/Config"

# Written from the host as the invoking user, which live_require_testbed has already
# proved is the uid the game runs as — so the marker is not the one root-owned file
# in a tree the server has to be able to rewrite.
printf '%s\n' "$MARKER_TEXT" > "$HOST_MARKER" \
  || { fail "cannot write the world marker $HOST_MARKER"; assert_report; exit 1; }
assert_file_exists "$HOST_MARKER" "the world marker is in place"

# =============================================================================
# Scenario 2 first, deliberately, even though it is second in the spec: it is the
# cheap one, it needs nothing but a running server, and running it before the stop
# means a server that fails to come back in scenario 1 does not also cost us this
# result. Nothing here depends on scenario 1 and nothing in scenario 1 depends on
# this.
# =============================================================================
# --- a real scheduled backup -------------------------------------------------
# Both of `palworld-backups`' inputs are pointed at this run's own files, and that is
# what makes the two assertions below possible at all rather than merely tidy:
#
#   * PALWARDEN_SAVE_BACKUP_DIR — the real backups volume accumulates across runs,
#     and this testbed may well have a scheduled tick of its own plus whatever
#     test_restore_roundtrip.sh left there minutes ago. Against that directory
#     "--if-due creates an archive" is not a claim this suite can make: an archive
#     from the last hour makes the correct answer "not due". An empty directory makes
#     the first run unambiguously due and the second run unambiguously not.
#   * PALWORLD_BACKUP_SCHEDULE — for the same reason. The operator's schedule file on
#     this testbed may say BACKUP_ENABLED=false, which is a perfectly legitimate
#     setting under which the correct behaviour is to create nothing. The schedule is
#     the *input* to what is being tested, so this run supplies it.
#
# The variables are the tools' own documented overrides, used exactly as the hermetic
# suites use them; the world being read, the tar being written and the code path
# taken are all the real ones.
SCHED="$BDIR/backup.env"
if live_exec mkdir -p -- "$BDIR/backups" "$BDIR/unpack" \
  && live_exec sh -c "printf 'BACKUP_ENABLED=true\nBACKUP_INTERVAL_HOURS=24\n' > '$SCHED'"; then
  pass
else
  fail "could not create the private backup workspace $BDIR in the container"
  assert_report; exit 1
fi

# `env` rather than `docker compose exec -e`: live_exec passes everything after the
# service name as the command, which is where the flag would have to go.
backups_if_due() {
  live_exec env \
    PALWARDEN_SAVE_BACKUP_DIR="$BDIR/backups" \
    PALWORLD_BACKUP_SCHEDULE="$SCHED" \
    palworld-backups --if-due 2>&1
}

first_out="$(backups_if_due)"; first_rc=$?
assert_eq "$first_rc" "0" "palworld-backups --if-due exits 0 against a real world"
# Pinned to the branch that was taken, not just to the outcome: an empty directory is
# due *because* nothing is in it, and saying so proves the decision came from
# newest_archive_mtime rather than from a schedule that could not be read.
assert_contains "$first_out" "if-due: due - no archive exists" \
  "...and reports the backup as due, on this run's empty backups directory"

# Read out of the tool's own output rather than by listing the directory: the name is
# what palworld-backup prints as its last line, and taking it from there is the same
# discipline test_restore_roundtrip.sh uses.
ARCHIVE="$(printf '%s' "$first_out" \
  | grep -oE 'palworld-save-[0-9]{8}T[0-9]{6}Z\.tar\.gz' | head -1)"
if [[ -n "$ARCHIVE" ]]; then pass; else
  fail "the scheduled backup did not name an archive (output: $first_out)"
  assert_report; exit 1
fi
# The private workspace is inside a container volume, not the testbed bind mount, so
# every check on it goes through live_exec rather than assert_file_exists.
assert_rc 0 live_exec test -f "$BDIR/backups/$ARCHIVE"

# --- ...and it actually unpacks ----------------------------------------------
# THE POINT OF PUTTING THIS SCENARIO IN THE LIVE TIER. A `tar -tzf` listing would
# only show that the member names are readable; the archive is extracted instead,
# because a truncated or half-written gzip stream lists further than it extracts.
# Against the fixture's few text files this would prove nothing interesting — against
# a real world written by the game while it was running, it is the whole claim the
# backup feature makes.
if live_exec tar -xzf "$BDIR/backups/$ARCHIVE" -C "$BDIR/unpack"; then pass; else
  fail "the archive $ARCHIVE does not extract — the scheduled tick wrote something unusable"
fi
# Spelled with assert_rc (which reports the command it ran) rather than a message,
# because the interesting failure is the extraction above; this is the shape check.
assert_rc 0 live_exec test -d "$BDIR/unpack/SaveGames"
# The strongest form of the claim, and the self-contained one: not "SaveGames exists"
# (a directory the game manages, which could have come from anywhere) but "this run's
# bytes came back out of the archive". A stale marker cannot satisfy it — the nonce
# did not exist before this process.
assert_eq "$(live_exec cat "$BDIR/unpack/$MARKER_REL" 2>/dev/null | tr -d '\r\n')" \
  "$MARKER_TEXT" \
  "...and what was in the live world is what comes out of the archive"

# --- ...and a second tick creates nothing ------------------------------------
# Run immediately, so the archive above is seconds old against a 24h interval. This
# is the other half of the tick's contract: a tick that always backed up would pass
# every assertion so far.
second_out="$(backups_if_due)"; second_rc=$?
assert_eq "$second_rc" "0" "a second --if-due immediately after also exits 0"
assert_contains "$second_out" "if-due: not due" \
  "...and declines, because the archive it just made is inside the interval"
# Not "the count is still 1" but "the directory holds exactly the one name this run
# created" — which is a statement this suite can make only because the directory is
# its own. A `.partial` left by a tar that died would show up here too.
assert_eq "$(live_exec sh -c "ls -1A -- '$BDIR/backups'" | tr -d '\r' | sort | tr '\n' ' ')" \
  "$ARCHIVE " \
  "...and created nothing at all — no second archive, no partial"

# =============================================================================
# Scenario 1: save-on-stop consistency.
# =============================================================================
# The world directories as they are *now*, while the server is running and before
# anything has been stopped. This is the one reading that touches state the game
# owns, and it is compared only against a second reading taken by this same run —
# never against an expected value — which is what keeps it valid in a tier where the
# world drifts between runs.
#
# Depth 1 and 2 under SaveGames: Palworld's layout is `SaveGames/<n>/<world-id>/`, so
# that range is the *identity* of the worlds present and nothing deeper (player saves,
# level chunks) that a boot legitimately rewrites. What it catches is the failure that
# matters here — a server that came up on a freshly generated world instead of
# reopening the one it saved, which would otherwise satisfy every other assertion
# below.
world_dirs() { (cd "$HOST_SAVED/SaveGames" && find . -mindepth 1 -maxdepth 2 -type d | sort); }
worlds_before="$(world_dirs)"
# Without this the comparison after the restart could be "" == "", which is to say no
# comparison at all. live_up has confirmed the game's REST API answers, so a world
# exists and this cannot be empty for any innocent reason.
if [[ -n "$worlds_before" ]]; then pass; else
  fail "no world directories under $HOST_SAVED/SaveGames, so the reload comparison would be vacuous"
  assert_report; exit 1
fi

# wait:0 skips the player-warning window (nobody is playing); confirm:true is the gate
# jobd puts in front of every disruptive action. In the container the stop resolves to
# `s6-svc -wD -d`, which does not return until the service is actually down — so a
# succeeded job here already means the game process has exited, not merely that it was
# signalled.
s_id="$(live_enqueue graceful_stop '{"wait":0,"confirm":true}')" \
  || { fail "could not enqueue the graceful_stop job"; assert_report; exit 1; }
s_state="$(live_wait_job "$s_id" "$STOP_TIMEOUT")"
assert_eq "$s_state" "succeeded" "graceful_stop runs to success against a real server (job $s_id)"

# Asked of the supervisor, because "the job succeeded" is not the same claim. If the
# server were still running, the start below would be a no-op and the whole scenario
# would pass without the game ever having reloaded anything. The shim's `is-active`
# exits 3 for inactive, matching systemctl, and it can read s6 here because a
# `compose exec` runs as root (an unprivileged caller would fall back to pgrep).
if live_exec systemctl is-active palworld-server >/dev/null 2>&1; then
  fail "the server is still active after graceful_stop, so the restart below would be a no-op and this scenario would pass without the game ever reloading a world"
else
  pass
fi

# --- bring it back up on the world the stop wrote ----------------------------
# Through the systemctl shim, which is how every script in this repo starts the
# service in the container, rather than reaching for s6-svc directly.
if live_exec systemctl start palworld-server; then pass; else
  fail "could not start palworld-server again after the graceful stop"
  assert_report; exit 1
fi
# live_up for the readiness poll rather than a loop of our own: it is already bounded
# (LIVE_UP_TIMEOUT) and it measures readiness the same way every job does, through
# palworld-api inside the container. Its `compose up -d --build` is a no-op on a
# stack that is already up with an image built minutes ago; what is wanted from it
# here is the poll.
live_up || { fail "the server did not become REST-ready again after the graceful stop — the world it saved on SIGINT may not be loadable"; assert_report; exit 1; }

# --- the world it saved is the world it reopened -----------------------------
# Independently of live_up, and through the same /api/health the operator would look
# at. Parsed with python3 rather than grepped because the two fields that matter are
# both called `ok` at different depths and are not even the same type — collect_service
# stringifies its own while collect_api's is a real boolean — so a flat grep for
# '"ok": true' cannot say which one it found. Duplicated from
# test_restore_roundtrip.sh rather than lifted into testbed.sh: this task must not
# change shared live infrastructure, and quietly editing a file every other live suite
# sources is not a thing to do on the way past.
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
  "after the SIGINT stop and a restart /api/health reports the service active"
assert_eq "$(printf '%s\n' "$h_vals" | sed -n 2p)" "true" \
  "...and the game's own REST API answers, so it loaded the world it saved on the way down"

# The marker survived the stop and the start. Weaker than the health check on its own
# — the game has no reason to touch a dotfile — but it is what rules out the world
# tree having been replaced or wiped underneath the restart, which a healthy server on
# a brand-new world would otherwise look identical to.
assert_file_contains "$HOST_MARKER" "$MARKER_TEXT" \
  "the world tree survived the stop/start intact"
# And the same worlds are there: this run's before against this run's after. A server
# that generated a new world rather than reopening the saved one is healthy, answers
# REST, and leaves the marker alone — this is the assertion that separates the two.
assert_eq "$(world_dirs)" "$worlds_before" \
  "...and the server reopened the same world it saved, not a freshly generated one"

# live_down runs from the EXIT trap installed above, on every path out of here.
assert_report
