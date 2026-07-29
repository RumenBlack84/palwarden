#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Two things a stub server cannot be asked, against a REAL Palworld server.
#
#   1. DRIFT AFTER A REAL REWRITE. `palworld-engine-config`'s check compares
#      Engine.ini against /etc/palworld/engine.env *semantically*, not textually,
#      for one reason: the game rewrites its own config in its own format, so
#      `True` has to equal `1` and `60.000000` has to equal `60`. Every test to
#      date has fed that comparison files **we** wrote — which proves only that
#      the normaliser agrees with itself. Only a real boot proves it survives the
#      game's own reformatting, and this is the one piece of logic in the repo
#      that cannot be tested any other way. Same question for
#      PalWorldSettings.ini, whose applied values must still be there (and whose
#      secrets must still be redacted) after the game has been through the file.
#
#   2. `update_check` AGAINST REAL STEAM. `palworld-update --check` has never
#      talked to Valve. What is asserted here is that it *settles* and that it
#      reports a buildid — deliberately NOT that no update is available, which
#      depends on Valve's release schedule and would be a flaky assertion by
#      construction.
#
# They share one file because they share the expensive part — a cold start of the
# actual game — and nothing else: neither scenario reads anything the other wrote.
#
# SELF-CONTAINMENT IS THE RULE THAT MAKES THIS VALID, exactly as in
# test_restore_roundtrip.sh and test_stop_consistency.sh. The tier keeps its world
# between runs, with no snapshot and no reset, so an assertion that could be
# satisfied by a previous run's leftovers is not an assertion at all. Concretely:
#
#   * the PalWorldSettings value carries a fresh nonce, so the applied value found
#     after the restart cannot be one an earlier run applied;
#   * the Engine.ini values are chosen to *differ from what is on disk right now*,
#     and the file is asserted not to have held them before the apply — so a stale
#     Engine.ini left by an earlier run cannot make the drift check pass without
#     this run's apply having written anything;
#   * engine.env and settings.env, the two expected-value files both checks
#     compare against, live in the container's writable layer (/etc/palworld is
#     not a volume — see docker/compose.yaml), so `live_down` destroys them and
#     every run starts from a file this run's container rendered.
#
# WHICH VALUES, AND WHY THOSE. Both Engine.ini keys are set to values that are
# genuinely non-default, because Unreal writes only non-default values: a
# defaults-only config is truncated (CLAUDE.md records PalWorldSettings.ini being
# reduced to a single newline on first start, and `format_check`'s own "no managed
# values" branch says the same of Engine.ini), and a test that picked a default
# would be measuring that truncation instead of the comparison.
#
#   * NET_SERVER_MAX_TICK_RATE — an `int` setting (Unreal's own default is 30, so
#     50/55 is non-default), and the example the brief names.
#   * CONNECTION_TIMEOUT — a `float` setting (default 60, so 90/95 is
#     non-default), and the one that actually exercises the documented
#     `60.000000` == `60` case: `normalize_value` folds a float through
#     `f"{n:g}"`, whereas its `int` branch is plain `int(v)`. Testing only an int
#     key would leave the decimal half of the semantic comparison unexercised.
#   * ServerDescription for PalWorldSettings.ini — a quoted free-text field, so it
#     can carry this run's nonce (which is what makes the assertion
#     self-contained); empty in Palworld's shipped config, so setting it is
#     unambiguously non-default; and read by nothing in this repo or the game for
#     behaviour, so writing it cannot perturb anything else the tier tests.
#
# Off by default; needs a marked testbed with a real install. See
# tests/live/lib/testbed.sh and docs/tools.md ("Test tiers").
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
source "$DIR/lib/testbed.sh"

# The guard first and on its own line, before anything is built or started: this
# suite restarts a server and rewrites its config, so pointed at a real deployment
# it would restart *that* one — it must refuse before it has done anything at all,
# including before Docker is asked for anything. live_require_testbed exits nonzero
# itself on refusal.
live_require_testbed

# How long the graceful restart may take: a real save flushed on SIGINT plus a cold
# start of the game. Its own bound rather than LIVE_JOB_TIMEOUT's 300s, matching
# test_stop_consistency.sh's reasoning, and bounded all the same — an unbounded live
# suite is one nobody watches long enough to notice.
RESTART_TIMEOUT="${PALWARDEN_LIVE_RESTART_TIMEOUT:-420}"
# SteamCMD has to fetch app info from Valve on a cold cache, which is comfortably
# slower than any local job. Also bounded.
UPDATE_TIMEOUT="${PALWARDEN_LIVE_UPDATE_TIMEOUT:-600}"

# Both files live in the config directory of the world mount, so they are visible
# on the host side of the testbed bind mount and can be read directly.
CONFIG_DIR="$TESTBED/server/Pal/Saved/Config/LinuxServer"
ENGINE_INI="$CONFIG_DIR/Engine.ini"
SETTINGS_INI="$CONFIG_DIR/PalWorldSettings.ini"
# Where the applied *expected* values live inside the container.
SETTINGS_ENV=/etc/palworld/settings.env
ENGINE_ENV=/etc/palworld/engine.env
# Restored by the EXIT trap: this suite appends to settings.env, which is rendered
# from the environment at container start, and putting it back keeps a hard-killed
# run from leaving a second copy of the line for the next one to append to.
SETTINGS_ENV_BAK=/etc/palworld/settings.env.live-drift-bak

# The nonce is the concrete form of the self-containment rule: the value asserted on
# did not exist before this process started, so a ServerDescription left by an
# earlier run — with this exact shape — cannot satisfy anything below. Dashes only,
# no spaces or quotes, so it is safe in an env file, in the INI's quoted value, in
# JSON and in a shell word.
NONCE="$$-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}${RANDOM}"
DESCRIPTION="palwarden-live-drift-$NONCE"

# --- helpers -----------------------------------------------------------------

# ini_value <file> <key> -> the last value assigned to <key>, or "" if absent.
# `Engine.ini` is INI-with-sections, but the two keys read here are unique across
# the file, and the drift check itself is what is under test — so this reads the
# file the crude way on purpose, rather than importing the tool's own parser and
# asserting the tool against itself.
#
# The `tr -d '\r'` is not decoration: palworld-engine-config's own split_sections
# normalises CRLF, so Engine.ini demonstrably can arrive with it, and a trailing
# carriage return would make pick_alt below think the file does *not* already hold
# the preferred value — quietly turning the apply into a no-op and letting the drift
# check pass on a previous run's bytes. That is precisely the hole this suite's
# self-containment rule exists to close.
ini_value() {
  [[ -f "$1" ]] || return 0
  grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | tail -1 \
    | sed 's/^[^=]*=[[:space:]]*//' | tr -d '\r' | sed 's/[[:space:]]*$//'
}

# pick_alt <current> <preferred> <fallback>
# The preferred value, unless the file already holds it, in which case the
# fallback. This is what stops a stale Engine.ini from satisfying the drift check
# on its own: whatever this run applies is a value the file did not have.
# `${1%%.*}` compares integer parts, so a game-written `50.000000` counts as 50.
pick_alt() {
  case "${1%%.*}" in
    "$2") printf '%s\n' "$3" ;;
    *)    printf '%s\n' "$2" ;;
  esac
}

# engine_check -> three lines: ok, drift_ok, and the check text on one line.
# Parsed with python3 rather than grepped because `ok` (did the endpoint manage to
# run the tool) and `drift_ok` (did the tool find the config clean) are different
# claims, and a flat grep for '"ok": true' cannot say which one it matched — this is
# the assertion that must not be fooled. Duplicated from the /api/health parse in
# the other two live suites rather than lifted into testbed.sh: this task must not
# change shared live infrastructure, and quietly editing a file every live suite
# sources is not a thing to do on the way past.
engine_check() {
  live_api GET /api/engine | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("unparseable"); print("unparseable"); print("unparseable")
    raise SystemExit(0)
print("true" if doc.get("ok") is True else "false")
print("true" if doc.get("drift_ok") is True else "false")
print(" ".join((doc.get("text") or doc.get("error") or "no text").split()))
'
}

# config_values <body> <key>... -> one line per key: its value, or "missing".
# Same reasoning as engine_check: the values are wanted exactly, and "<redacted>"
# has to be distinguishable from a key that is simply absent.
config_values() {
  local body="$1"; shift
  printf '%s' "$body" | python3 -c '
import json, sys
keys = sys.argv[1:]
try:
    doc = json.load(sys.stdin)
except Exception:
    for _ in keys:
        print("unparseable")
    raise SystemExit(0)
data = (doc.get("data") or {}) if doc.get("ok") is True else {}
for key in keys:
    value = data.get(key)
    print("missing" if value is None else str(value))
' "$@"
}

# --- bring the real thing up -------------------------------------------------
live_up || { fail "the live server did not become REST-ready"; assert_report; exit 1; }

# Only now, and never earlier: before live_up there is nothing to tear down, and
# live_down re-runs the guard, so a handler installed ahead of the guard would exit
# from inside itself on a refusal and bury the guard's message. Registered as a trap
# rather than called at the bottom so a failed assertion (or a `set -u` slip) still
# leaves the stack down instead of a real game server running for the next suite.
# The handler does not exit, so assert_report's status is still this script's status.
#
# settings.env is put back *before* the stack goes down, best-effort. It would go
# away with the container anyway (/etc is the writable layer), but a run that is
# killed hard never reaches live_down at all, and then the leftover line is still
# there when the next run appends its own.
trap 'live_exec test -f "$SETTINGS_ENV_BAK" >/dev/null 2>&1 \
        && live_exec mv -f "$SETTINGS_ENV_BAK" "$SETTINGS_ENV" >/dev/null 2>&1
      live_down >/dev/null 2>&1 || true' EXIT

# =============================================================================
# Scenario 2 first, deliberately, even though it is second above: it is
# independent of everything else here, it needs nothing but a running container,
# and running it before the config work means a failure in that longer scenario
# does not also cost us this result. Same ordering choice, for the same reason, as
# test_stop_consistency.sh.
# =============================================================================
# --- update_check against real Steam ----------------------------------------
# confirm:true because update_check is flagged disruptive in palwarden-jobd's
# action table (it is the entry point to a flow that stops the server), even though
# `--check` itself stops nothing.
u_id="$(live_enqueue update_check '{"confirm":true}')" \
  || { fail "could not enqueue the update_check job"; assert_report; exit 1; }
u_state="$(live_wait_job "$u_id" "$UPDATE_TIMEOUT")"
u_body="$(live_api GET "/api/jobs/$u_id")"

# A terminal state, not a *particular* terminal state, and this is the whole
# subtlety of testing this against Valve. `palworld-update --check` exits 0 when
# the local build is current and **10** when an update is available, and
# palwarden-jobd maps any nonzero exit to "failed" — so on the day Palworld ships a
# patch, a correct check reports `failed`. Asserting "succeeded" would make this
# suite fail for a reason that has nothing to do with this repo. What it must not
# be is queued/running (wedged) or unknown (unparseable).
case "$u_state" in
  succeeded|failed) pass ;;
  *) fail "update_check did not reach a terminal state (job $u_id, last state: $u_state)" ;;
esac

# The exit code narrows "failed" to the one failure that is legitimate. rc 10 is
# "an update is available"; anything else nonzero is a real problem — SteamCMD
# missing, no network, Valve unreachable — and this is what separates the two.
u_rc="$(printf '%s' "$u_body" | sed -n 's/.*"exit_code": *\([0-9-]*\).*/\1/p' | head -1)"
case "$u_rc" in
  0|10) pass ;;
  *) fail "update_check exited $u_rc; only 0 (current) and 10 (update available) mean it reached Steam (job $u_id)" ;;
esac

# The buildid is the evidence that it really talked to Steam rather than failing
# early: `remote_buildid` parses it out of `steamcmd +app_info_print`, and neither
# of the tool's two success messages can be printed without one. Both wordings are
# accepted because which one appears depends on Valve:
#   "no Palworld update available; buildid 12345678 is current."
#   "Palworld update available: local=12345678, remote=12345679."
u_build="$(printf '%s' "$u_body" \
  | grep -oE '(buildid [0-9]{4,}|remote=[0-9]{4,})' | head -1)"
if [[ -n "$u_build" ]]; then pass; else
  fail "update_check reported no Steam buildid, so it never got an answer from Valve (job $u_id, body: $u_body)"
fi

# =============================================================================
# Scenario 1: drift after a real rewrite.
# =============================================================================
# Both files must already exist: `palworld-engine-config apply` refuses on a
# missing Engine.ini ("Cannot read …", exit 1) and the config parser needs the live
# PalWorldSettings.ini as its schema. live_up has just confirmed the game's REST API
# answers, so a booted server has written both — checked explicitly because
# otherwise a testbed that was never fully installed surfaces as an obscure job
# failure several steps from here.
if [[ -f "$ENGINE_INI" ]]; then pass; else
  fail "$ENGINE_INI does not exist — the game has not written its Engine.ini, so there is nothing to apply to"
  assert_report; exit 1
fi
assert_file_exists "$SETTINGS_INI" "the live PalWorldSettings.ini is present"

# --- Engine.ini: save, apply, and prove the apply is what wrote it ------------
TICK_BEFORE="$(ini_value "$ENGINE_INI" NetServerMaxTickRate)"
TIMEOUT_BEFORE="$(ini_value "$ENGINE_INI" ConnectionTimeout)"
TICK="$(pick_alt "$TICK_BEFORE" 50 55)"
CTIMEOUT="$(pick_alt "$TIMEOUT_BEFORE" 90 95)"
live_log "Engine.ini before: NetServerMaxTickRate=${TICK_BEFORE:-absent} ConnectionTimeout=${TIMEOUT_BEFORE:-absent}"
live_log "applying NetServerMaxTickRate=$TICK ConnectionTimeout=$CTIMEOUT"

# Numbers as JSON numbers, which is what the Engine editor posts;
# palwarden-jobd's validate_settings accepts int/float and normalises them. No
# `confirm` here or on engine_apply/config_apply: those three are not flagged
# disruptive, and jobd rejects any parameter an action does not recognise — so
# sending it "to be safe" would get the enqueue refused with a 400.
e_id="$(live_enqueue engine_save \
  "{\"settings\":{\"NET_SERVER_MAX_TICK_RATE\":$TICK,\"CONNECTION_TIMEOUT\":$CTIMEOUT}}")" \
  || { fail "could not enqueue the engine_save job"; assert_report; exit 1; }
e_state="$(live_wait_job "$e_id")"
assert_eq "$e_state" "succeeded" "engine_save writes engine.env (job $e_id)"

# engine.env is what the drift check compares *against*, so it is worth one direct
# look: a check that passes because both sides are empty is the failure mode
# `format_check`'s "no managed values" branch exists for.
assert_contains "$(live_exec cat "$ENGINE_ENV" 2>/dev/null)" "NET_SERVER_MAX_TICK_RATE=$TICK" \
  "engine.env now holds this run's expected tick rate"

a_id="$(live_enqueue engine_apply '{}')" \
  || { fail "could not enqueue the engine_apply job"; assert_report; exit 1; }
a_state="$(live_wait_job "$a_id")"
assert_eq "$a_state" "succeeded" "engine_apply writes Engine.ini (job $a_id)"

# Exact text, and only here: these are bytes *we* just wrote, so their form is
# known. Nothing below assumes the game keeps that form — that is the entire point.
assert_file_contains "$ENGINE_INI" "NetServerMaxTickRate=$TICK" \
  "the apply put this run's tick rate into Engine.ini"
assert_file_contains "$ENGINE_INI" "ConnectionTimeout=$CTIMEOUT" \
  "...and this run's connection timeout"
# Both values were chosen to differ from what was on disk, so the two assertions
# above are statements about this run's apply and not about a leftover file.
assert_ne "${TICK_BEFORE%%.*}" "$TICK" "the tick rate applied is not the one Engine.ini already had"
assert_ne "${TIMEOUT_BEFORE%%.*}" "$CTIMEOUT" "...nor is the connection timeout"

# The baseline reading: the check agrees with our own writing. Weak on its own —
# it compares a file we wrote against a file we wrote — but without it, a
# post-restart "no drift" could not be attributed to the game's rewrite surviving
# the comparison rather than to the comparison having been clean all along.
e_vals="$(engine_check)"
assert_eq "$(printf '%s\n' "$e_vals" | sed -n 2p)" "true" \
  "before the restart /api/engine reports no drift (baseline: our own bytes)"

# --- PalWorldSettings.ini: apply through the real env file --------------------
# Appended to settings.env because that is exactly what the file looks like after
# an operator sets PALWORLD_CFG_SERVER_DESCRIPTION: palwarden-render-config turns
# every PALWORLD_CFG_<KEY> into a bare `<KEY>="value"` line here, and
# palworld-config-apply-env then feeds this file to the parser. Compose cannot pass
# a PALWORLD_CFG_* variable through without editing compose.yaml's `environment:`
# list, so the file is written directly — the same file, the same reader, the same
# code path. A later duplicate key wins in the parser's env reader, so appending is
# safe whether or not the key is already there.
if live_exec cp -p "$SETTINGS_ENV" "$SETTINGS_ENV_BAK"; then pass; else
  fail "could not back up $SETTINGS_ENV before appending to it"
  assert_report; exit 1
fi
if live_exec sh -c "printf 'SERVER_DESCRIPTION=\"%s\"\n' '$DESCRIPTION' >> '$SETTINGS_ENV'"; then pass; else
  fail "could not append SERVER_DESCRIPTION to $SETTINGS_ENV"
  assert_report; exit 1
fi

c_id="$(live_enqueue config_apply '{}')" \
  || { fail "could not enqueue the config_apply job"; assert_report; exit 1; }
c_state="$(live_wait_job "$c_id")"
assert_eq "$c_state" "succeeded" "config_apply applies settings.env to PalWorldSettings.ini (job $c_id)"
# The parser exits 0 and merely *warns* when an env name resolves to no INI key, so
# "the job succeeded" is not the same claim as "the value was applied". Asserted on
# the file, before the restart, for the same reason as the Engine.ini baseline.
assert_file_contains "$SETTINGS_INI" "ServerDescription=\"$DESCRIPTION\"" \
  "the applied description is in the live PalWorldSettings.ini"

# --- restart, and let the game rewrite both files -----------------------------
# THE POINT OF THE WHOLE SCENARIO. Through the real operator path — the same
# graceful_restart the Overview page's button queues — because that is what
# palworld-config-apply-env's own closing message tells the operator to do, and
# because the shutdown half (SIGINT, save) and the startup half (read, normalise,
# rewrite) are both parts of the rewriting under test. wait:0 skips the
# player-warning window (nobody is playing); confirm:true is the gate jobd puts in
# front of every disruptive action.
ENGINE_SHA_BEFORE="$(sha256sum "$ENGINE_INI" 2>/dev/null | cut -d' ' -f1)"
r_id="$(live_enqueue graceful_restart '{"wait":0,"confirm":true}')" \
  || { fail "could not enqueue the graceful_restart job"; assert_report; exit 1; }
r_state="$(live_wait_job "$r_id" "$RESTART_TIMEOUT")"
assert_eq "$r_state" "succeeded" "graceful_restart runs to success against a real server (job $r_id)"

# live_up for the readiness poll rather than a loop of our own: it is already
# bounded (LIVE_UP_TIMEOUT) and it measures readiness the same way every job does,
# through palworld-api inside the container. Its `compose up -d --build` is a no-op
# on a stack that is already up with an image built minutes ago; what is wanted from
# it here is the poll. Without it the checks below could run against a server that
# has not finished writing its config yet.
live_up || { fail "the server did not become REST-ready again after the restart"; assert_report; exit 1; }

# Reported, not asserted. Whether the game rewrites Engine.ini byte-for-identically
# is the game's business and could change with any patch, so making it an assertion
# would be asserting on Palworld rather than on this repo — but if the bytes never
# changed, the semantic comparison below was not actually put to the test, and the
# operator reading this output should be able to see that.
ENGINE_SHA_AFTER="$(sha256sum "$ENGINE_INI" 2>/dev/null | cut -d' ' -f1)"
if [[ "$ENGINE_SHA_BEFORE" == "$ENGINE_SHA_AFTER" ]]; then
  live_log "note: the game left Engine.ini byte-identical, so the reformatting the drift check normalises was not exercised on this run"
else
  live_log "the game rewrote Engine.ini; it now reads NetServerMaxTickRate=$(ini_value "$ENGINE_INI" NetServerMaxTickRate) ConnectionTimeout=$(ini_value "$ENGINE_INI" ConnectionTimeout)"
fi

# --- the assertion the whole file exists for ---------------------------------
e_vals="$(engine_check)"
assert_eq "$(printf '%s\n' "$e_vals" | sed -n 1p)" "true" \
  "/api/engine can still run the drift check after the restart"
assert_eq "$(printf '%s\n' "$e_vals" | sed -n 2p)" "true" \
  "...and reports NO DRIFT after the game rewrote Engine.ini itself — the semantic comparison holds: $(printf '%s\n' "$e_vals" | sed -n 3p)"
# The wording as well as the flag, because `drift_ok` is derived from an exit code
# and an exit code has only two values: this pins the branch that produced it.
assert_contains "$(printf '%s\n' "$e_vals" | sed -n 3p)" "Engine.ini check OK" \
  "...and says so in the words the operator sees"

# --- and the same question of PalWorldSettings.ini ---------------------------
cfg_body="$(live_api GET /api/config)"
cfg_vals="$(config_values "$cfg_body" ServerDescription AdminPassword)"
assert_eq "$(printf '%s\n' "$cfg_vals" | sed -n 1p)" "$DESCRIPTION" \
  "/api/config still reports this run's applied value after the game rewrote PalWorldSettings.ini"
# Redaction: the key must be *there* and its value must be the placeholder, which
# is why "missing" is parsed distinctly from a value above — an absent key would
# otherwise look like successful redaction.
assert_eq "$(printf '%s\n' "$cfg_vals" | sed -n 2p)" "<redacted>" \
  "...and the admin password is redacted, not reported"

# The sharper form of the same claim: the real password does not appear anywhere in
# the response. Read from settings.env inside the container and never echoed — the
# failure message below is deliberately fixed text, because a message that printed
# the value it was looking for would leak it into the test log. Skipped for a very
# short password, where a coincidental match somewhere in the body is likelier than
# a leak.
admin_pw="$(live_exec sh -c ". '$SETTINGS_ENV'; printf %s \"\${ADMIN_PASSWORD:-}\"" 2>/dev/null | tr -d '\r\n')"
if [[ ${#admin_pw} -ge 8 ]]; then
  case "$cfg_body" in
    *"$admin_pw"*) fail "the admin password appears verbatim in the /api/config response" ;;
    *) pass ;;
  esac
else
  live_log "note: skipping the verbatim-password check (the testbed's ADMIN_PASSWORD is too short to distinguish a leak from a coincidence)"
fi

# live_down runs from the EXIT trap installed above, on every path out of here.
assert_report
