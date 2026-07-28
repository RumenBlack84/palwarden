#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Helpers for palwarden's *live* test tier: suites that drive a real Palworld
# dedicated server, not tests/fixtures/fake-server. Sourced, never executed.
#
# The tier exists because the fake server cannot answer the questions that matter
# most — does the game actually reopen a world we restored, does a save land where
# the backup tool looks, does a graceful stop really finish writing. Answering them
# means running the real binary, so the install lives on a persistent bind mount
# (the "testbed") that survives between runs; see docker/compose.live.yaml.
#
# SAFETY CONTRACT — the reason this file is shaped the way it is:
#
#   Every function here that mutates anything (live_up, live_down, live_enqueue,
#   live_reset_world) calls live_require_testbed first, and live_require_testbed
#   refuses unless the directory is a marked testbed owned by the right uid with a
#   game installed. The tier stops the server, deletes worlds and restarts it —
#   aimed at a real deployment by one mistyped path it would destroy it. The marker
#   file is what makes a typo unable to name a real deployment, and it is checked
#   by tests/unit/test_live_guard.sh, which runs in ordinary CI with neither a game
#   nor Docker: a destructive suite's safety check cannot be verified only by a
#   tier nobody runs automatically.
#
# No `set -e`/`set -u` here: this is sourced into callers that choose their own
# shell options (the guard suite runs under `set -u`), and flipping them for a
# caller from a library is how a sourced helper breaks a suite it never saw.

# Where the throwaway install lives. Everything below is relative to this.
TESTBED="${PALWARDEN_LIVE_TESTBED:-$HOME/palworld-testbed}"
# Presence of this file is the operator's explicit "yes, this directory is
# disposable". Nothing else distinguishes a testbed from a real deployment, whose
# layout is identical by design.
MARKER="$TESTBED/.palwarden-live-testbed"

# Repo root, so the helpers can be sourced from anywhere. lib -> live -> tests -> repo.
LIVE_REPO="${PALWARDEN_LIVE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

# The web UI is published on the loopback host port by compose.yaml. Credentials
# come from the environment when the operator pinned them in docker/.env; otherwise
# live_creds reads the generated ones back out of the running container.
LIVE_WEBUI_PORT="${PALWARDEN_LIVE_WEBUI_PORT:-${WEBUI_PORT:-8088}}"
LIVE_WEBUI_USER="${PALWARDEN_LIVE_WEBUI_USER:-${WEBUI_USER:-admin}}"
LIVE_WEBUI_PASSWORD="${PALWARDEN_LIVE_WEBUI_PASSWORD:-${WEBUI_PASSWORD:-}}"
LIVE_WEBUI_TOKEN="${PALWARDEN_LIVE_WEBUI_TOKEN:-${WEBUI_TOKEN:-}}"

# Bounds. Every wait in this file is bounded: a live suite that hangs is worse
# than one that fails, because nobody watches it long enough to notice.
LIVE_UP_TIMEOUT="${PALWARDEN_LIVE_UP_TIMEOUT:-420}"   # seconds for REST readiness
LIVE_JOB_TIMEOUT="${PALWARDEN_LIVE_JOB_TIMEOUT:-300}" # seconds for a job to settle

live_log()  { printf 'live: %s\n' "$*" >&2; }
live_fail() { printf 'live: %s\n' "$*" >&2; exit 1; }

# --- the guard --------------------------------------------------------------
# Checks, in this order, with a distinct message each time:
#   1. the testbed directory exists
#   2. the marker file exists
#   3. the directory's owning uid matches the container's steam account
#   4. the game is installed
# The order is the contract, not an accident: a path that is simply absent must be
# reported as absent. Reported as a uid mismatch instead, it sends the operator to
# chown a directory that is not there.
live_require_testbed() {
  local expect_uid="${PALWARDEN_LIVE_EXPECT_UID:-1000}" owner

  if [[ ! -d "$TESTBED" ]]; then
    live_fail "testbed directory does not exist: $TESTBED
Point PALWARDEN_LIVE_TESTBED at a disposable directory, then mark it:
  mkdir -p \"$TESTBED/server/Pal/Saved\" && touch \"$TESTBED/.palwarden-live-testbed\""
  fi

  if [[ ! -f "$MARKER" ]]; then
    live_fail "$TESTBED is not a marked live testbed.
The live tier stops the server, deletes worlds and restarts it, so it refuses to
touch any directory that has not been declared disposable. If this really is a
throwaway testbed and not a live deployment, mark it:
  touch \"$MARKER\""
  fi

  # The container's steam account is uid 1000. A testbed owned by anyone else is
  # unwritable by the game, and this repo has already broken CI once on a
  # 1000-vs-1001 mismatch, so it is refused here with the expected value named
  # rather than surfacing later as a permission error inside the game.
  owner="$(stat -c %u "$TESTBED" 2>/dev/null)"
  if [[ "$owner" != "$expect_uid" ]]; then
    live_fail "$TESTBED is owned by uid ${owner:-unknown}, but the container's game
account is uid $expect_uid — the server could not write its own save.
Fix the ownership (sudo chown -R $expect_uid \"$TESTBED\"), or set
PALWARDEN_LIVE_EXPECT_UID if your image builds steam with a different uid."
  fi

  if [[ ! -x "$TESTBED/server/PalServer.sh" ]]; then
    # Wording deliberately mirrors docker/entrypoint.sh's own not-installed
    # message, so an operator who hits either one is told the same thing and the
    # two cannot drift apart.
    live_fail "PalServer.sh missing under $TESTBED/server — the testbed has no game installed.
Set UPDATE_ON_START=true for the first run so SteamCMD can install it:
  UPDATE_ON_START=true COMPOSE_PROFILES=embedded PALWARDEN_LIVE_TESTBED=\"$TESTBED\" \\
    docker compose -f docker/compose.yaml -f docker/compose.live.yaml up -d --build
That download is several GB and is a one-time step; no suite performs it."
  fi
}

# --- compose ----------------------------------------------------------------
# Always both files, always the embedded profile: the web UI and the job worker
# are embedded-only by design (external mode manages someone else's server and has
# no local world to test against), and the overlay carries a distinct project name
# so a live run cannot adopt a real deployment's containers.
live_compose() {
  COMPOSE_PROFILES=embedded PALWARDEN_LIVE_TESTBED="$TESTBED" \
    docker compose \
      --project-directory "$LIVE_REPO/docker" \
      -f "$LIVE_REPO/docker/compose.yaml" \
      -f "$LIVE_REPO/docker/compose.live.yaml" "$@"
}

# Run a command inside the live container. -T because suites are not a terminal.
live_exec() { live_compose exec -T palwarden "$@"; }

live_up() {
  live_require_testbed

  # The REST API is what readiness is measured against, and the server only enables
  # it when ADMIN_PASSWORD is set. Without one, the poll below could only ever time
  # out — so say so now instead of after LIVE_UP_TIMEOUT seconds of silence.
  if [[ -z "${ADMIN_PASSWORD:-}" ]] && ! grep -qE '^[[:space:]]*ADMIN_PASSWORD=.' "$LIVE_REPO/docker/.env" 2>/dev/null; then
    live_fail "ADMIN_PASSWORD is not set (neither in the environment nor in docker/.env).
The live tier drives the server through its REST API, which the game only enables
when an admin password exists, so readiness could never be reached."
  fi

  live_log "bringing the live stack up (testbed: $TESTBED)"
  live_compose up -d --build || live_fail "compose up failed"

  # Bounded readiness poll. palworld-api reads the rendered settings.env inside the
  # container, which is the same path the tooling uses, so a 200 here means the
  # server is up *and* reachable the way every job will reach it.
  local deadline=$((SECONDS + LIVE_UP_TIMEOUT))
  while ((SECONDS < deadline)); do
    if live_exec palworld-api info 2>/dev/null | grep -q 'HTTP 200'; then
      live_log "server is REST-ready"
      return 0
    fi
    sleep 5
  done
  live_log "server did not become REST-ready within ${LIVE_UP_TIMEOUT}s; recent logs:"
  live_compose logs --tail 40 palwarden >&2 2>/dev/null || true
  return 1
}

# Tear the stack down but keep the testbed. No `-v`: that would delete the named
# volumes the overlay did *not* replace (state, backups, snapshots) and, more to
# the point, a live suite's job is to leave the multi-GB install exactly where it
# found it. Bind mounts are never removed by compose in any case.
live_down() {
  live_require_testbed
  live_compose down --remove-orphans
}

# --- HTTP -------------------------------------------------------------------
# Resolve the web UI credentials once. Pinned values from the environment win;
# otherwise they are read from the root-only file the entrypoint generated, which
# is why this needs the container to be running.
live_creds() {
  [[ -n "$LIVE_WEBUI_PASSWORD" && -n "$LIVE_WEBUI_TOKEN" ]] && return 0
  local env_file
  env_file="$(live_exec cat /etc/palworld/webui.env 2>/dev/null)"
  [[ -n "$env_file" ]] || { live_log "could not read /etc/palworld/webui.env from the container"; return 1; }
  [[ -n "$LIVE_WEBUI_PASSWORD" ]] || \
    LIVE_WEBUI_PASSWORD="$(printf '%s\n' "$env_file" | sed -n 's/^WEBUI_PASSWORD="\(.*\)"$/\1/p')"
  [[ -n "$LIVE_WEBUI_TOKEN" ]] || \
    LIVE_WEBUI_TOKEN="$(printf '%s\n' "$env_file" | sed -n 's/^WEBUI_TOKEN="\(.*\)"$/\1/p')"
  [[ -n "$LIVE_WEBUI_PASSWORD" && -n "$LIVE_WEBUI_TOKEN" ]]
}

# live_api <method> <path> [data] -> response body on stdout
# Sends Basic auth *and* X-Palwarden-Token: the token is the CSRF gate every
# mutating request must pass, so sending only Basic auth gets a 403, not a 401 —
# a confusing failure to debug from inside a suite.
live_api() {
  local method="$1" path="$2" data="${3-}"
  live_creds || return 1
  local -a args=(-sS --max-time 30 -X "$method"
                 -u "$LIVE_WEBUI_USER:$LIVE_WEBUI_PASSWORD"
                 -H "X-Palwarden-Token: $LIVE_WEBUI_TOKEN")
  [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' --data "$data")
  curl "${args[@]}" "http://127.0.0.1:${LIVE_WEBUI_PORT}${path}"
}

# live_enqueue <action> <params-json> -> job id on stdout
# Mutates (the queue, and then whatever the job does), so it is guarded.
live_enqueue() {
  live_require_testbed
  local action="$1" params="${2-}" body id
  [[ -n "$params" ]] || params='{}'
  body="$(printf '{"action":"%s","params":%s}' "$action" "$params")"
  id="$(live_api POST /api/jobs "$body" | grep -oE '[0-9a-f]{32}' | head -1)"
  [[ ${#id} -eq 32 ]] || { live_log "enqueue of $action returned no job id"; return 1; }
  printf '%s\n' "$id"
}

# live_wait_job <id> [timeout] -> final state on stdout
# Bounded: on timeout it echoes the last state seen and fails, so a wedged worker
# fails the suite instead of hanging it.
live_wait_job() {
  local id="$1" timeout="${2:-$LIVE_JOB_TIMEOUT}" state=""
  local deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    state="$(live_api GET "/api/jobs/$id" | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p' | head -1)"
    case "$state" in
      queued|running|"") sleep 2 ;;
      *) printf '%s\n' "$state"; return 0 ;;
    esac
  done
  printf '%s\n' "${state:-unknown}"
  live_log "job $id did not settle within ${timeout}s (last state: ${state:-unknown})"
  return 1
}

# Delete the world so the server regenerates a fresh one on the next start.
# GUARDED ON PURPOSE, and this is the function the guard exists for: it removes a
# directory outright, so live_require_testbed must pass first and it can therefore
# never run against an unmarked directory. Stop the server first (live_down) — the
# game holds the save open and would write it back out on shutdown.
live_reset_world() {
  live_require_testbed
  local saved="$TESTBED/server/Pal/Saved"
  live_log "resetting world: $saved"
  rm -rf -- "$saved" || return 1
  # Recreate it empty: it is a bind-mount *source*, and the overlay sets
  # create_host_path: false, so leaving it absent makes the next `up` fail (which
  # is the right default for a typo, but not for our own deliberate wipe).
  mkdir -p -- "$saved"
}
