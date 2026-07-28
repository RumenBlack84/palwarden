# Live test tier — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the tooling against a real, throwaway Palworld server on a persistent bind mount, exercising the paths that only a real game can reach — without weakening the hermetic suites that gate CI.

**Architecture:** A `docker/compose.live.yaml` overlay swaps the game's named volumes for bind mounts into `~/palworld-testbed`. A marker file guards a destructive suite against being pointed at a real deployment. `tests/run.sh` grows a `--live` mode, off by default. New suites live in `tests/live/`.

**Tech Stack:** Bash + `tests/lib/assert.sh`. Docker Compose overlays. No new dependencies.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-live-test-tier-design.md`. Read it first.
- **The live suites cannot be executed during implementation.** They need a real game install (~8–10 GB via SteamCMD) that only the repository owner will create. **Do not attempt that download.** Each task states exactly what you *can* verify — the gate, the guard, the uid check, the skip path, shell syntax — and what must be left for the owner's testbed. Say plainly in your report which assertions you ran and which you could not.
- **CI stays hermetic.** Nothing in this plan may make the unit or integration suites depend on a real server, and nothing may run the live tier in CI. `.github/workflows/ci.yml` must not gain a live step.
- **`docker/compose.yaml` is not modified.** The live configuration is an overlay only, so the normal deployment cannot drift into the test one.
- **Every live test is self-contained.** It asserts against an artefact it created in the same run — never an assumed world state, a fixed file list, or a specific save size. World drift is accepted precisely because of this rule; a test that needs particular world content creates it first.
- Host-portable: paths from env with sane defaults (`PALWARDEN_LIVE_TESTBED`, default `~/palworld-testbed`).
- Bash suites source `tests/lib/assert.sh`, end with `assert_report`, and are `chmod +x`. Helpers `assert_file_exists` and `assert_path_absent` exist.
- SPDX on new first-party files: `# SPDX-License-Identifier: AGPL-3.0-or-later`, `# SPDX-FileCopyrightText: 2026 Brian Grant`.
- Every task ends green: `./tests/lint.sh` and `./tests/run.sh` (the default, hermetic run).
- Commit messages end with a blank line then `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Mutation-check every refusal.** Remove the check, confirm the test fails, restore. Verify each mutation actually applied, matched the intended occurrence, and still parses — on this project a wrong-indent mutation once produced 193 "failures" that were a `SyntaxError`, and another silently matched the wrong copy of a line. **Never use `git checkout` to restore during a mutation loop**; keep file copies.
- Do not push.

## Facts already verified against the code

- `docker/entrypoint.sh:213` — `UPDATE_ON_START` defaults to `true`; `false` logs `UPDATE_ON_START=false — skipping SteamCMD update.` and skips.
- `docker/entrypoint.sh:229-232` — if `PalServer.sh` is missing it exits 1 with `Set UPDATE_ON_START=true for the first run so SteamCMD can install it.`
- `docker/compose.yaml:76-77` — `palworld-server:/opt/palworld/server` and `palworld-saved:/opt/palworld/server/Pal/Saved` are the two named volumes the overlay replaces.
- `tests/run.sh:17-18` — the gate is `RUN_INTEGRATION=1` **or** `--integration`; `:46` prints `(integration tests skipped; pass --integration to run them)`. `--live` mirrors this shape.
- The container's `steam` is uid/gid **1000**.
- `PALWARDEN_MODE=embedded` is required: `config-webui` and `jobd` are embedded-only by design.

## File Structure

| File | Responsibility |
|---|---|
| `docker/compose.live.yaml` (create) | Overlay: bind mounts + `UPDATE_ON_START=false`. Nothing else. |
| `tests/live/lib/testbed.sh` (create) | The guard and the runner helpers: marker check, uid check, bring-up/tear-down, `--reset-world`. Sourced by every live suite so the safety rules have one implementation. |
| `tests/live/test_restore_roundtrip.sh` (create) | Task 2. |
| `tests/live/test_stop_consistency.sh` (create) | Task 3. |
| `tests/live/test_config_drift.sh` (create) | Task 4. |
| `tests/run.sh` (modify) | `--live` / `RUN_LIVE=1`, off by default, prints its skip. |
| `tests/unit/test_live_guard.sh` (create) | Hermetic tests for the guard itself — runs in CI, needs no game. |
| `docs/tools.md`, `docs/palworld-service-runbook.md`, `README.md` (modify) | How to create the testbed and run the tier. |

**Why the guard gets its own hermetic suite:** it is the one part of this tier that must be tested in CI. A destructive suite's safety check cannot be verified only by a tier that never runs automatically.

---

### Task 1: Testbed plumbing, guard, and the `--live` gate

**Files:**
- Create: `docker/compose.live.yaml`, `tests/live/lib/testbed.sh`, `tests/unit/test_live_guard.sh`
- Modify: `tests/run.sh`

**Interfaces produced** (later tasks depend on these exact names):
```bash
# tests/live/lib/testbed.sh
TESTBED           # $PALWARDEN_LIVE_TESTBED, default "$HOME/palworld-testbed"
MARKER            # "$TESTBED/.palwarden-live-testbed"
live_require_testbed   # refuses (exit 1) unless marker exists, uid matches, install present
live_up                # brings the stack up with the overlay; waits for REST readiness
live_down              # tears the stack down, leaving the bind mount intact
live_api               # curl helper: live_api <method> <path> [data] -> body on stdout
live_enqueue           # live_enqueue <action> <params-json> -> job id
live_wait_job          # live_wait_job <id> -> final state, bounded
live_reset_world       # deletes Pal/Saved so the server regenerates one
```

- [ ] **Step 1: Write the failing hermetic guard test**

Create `tests/unit/test_live_guard.sh`. This runs in CI and must need **no** game and **no** Docker:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# The live tier stops the server, replaces worlds and restarts it. Pointed at a real
# deployment it would be destructive, so its guard is the one part of that tier which
# must be verified by a suite that actually runs in CI — a destructive suite's safety
# check cannot be tested only by a tier nobody runs automatically.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
LIB="$DIR/../live/lib/testbed.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run the guard in a subshell with a chosen testbed, capturing output and status.
guard() {  # guard <testbed-dir>
  ( PALWARDEN_LIVE_TESTBED="$1" bash -c '
      source "$0" >/dev/null 2>&1 || exit 90
      live_require_testbed
    ' "$LIB" ) 2>&1
}
guard_rc() { guard "$1" >/dev/null 2>&1; echo $?; }

# --- refuses a directory with no marker -----------------------------------
mkdir -p "$WORK/nomarker"
assert_ne "$(guard_rc "$WORK/nomarker")" "0" "a testbed without the marker is refused"
assert_contains "$(guard "$WORK/nomarker")" ".palwarden-live-testbed" \
  "the refusal names the marker file, so the operator knows what to create"

# --- refuses a directory that does not exist at all -----------------------
assert_ne "$(guard_rc "$WORK/absent")" "0" "an absent testbed is refused"

# --- refuses when the marker exists but the game is not installed ---------
mkdir -p "$WORK/bare"; : > "$WORK/bare/.palwarden-live-testbed"
assert_ne "$(guard_rc "$WORK/bare")" "0" "a marked testbed with no install is refused"
assert_contains "$(guard "$WORK/bare")" "UPDATE_ON_START" \
  "the refusal points at the one-time install step"

# --- accepts a marked testbed with an install present ---------------------
mkdir -p "$WORK/ok/server"; : > "$WORK/ok/.palwarden-live-testbed"
printf '#!/bin/sh\n' > "$WORK/ok/server/PalServer.sh"; chmod +x "$WORK/ok/server/PalServer.sh"
assert_eq "$(guard_rc "$WORK/ok")" "0" "a marked, installed testbed is accepted"

# --- refuses a uid mismatch ------------------------------------------------
# The container's steam account is uid 1000. A bind mount owned by anyone else means
# the game cannot write its own save, and this repo has already broken CI once on a
# uid 1000-vs-1001 mismatch — so it is refused up front with the expected uid named,
# rather than surfacing later as a permission error inside the game.
out="$( PALWARDEN_LIVE_TESTBED="$WORK/ok" PALWARDEN_LIVE_EXPECT_UID=65534 \
        bash -c 'source "$0" >/dev/null 2>&1; live_require_testbed' "$LIB" 2>&1 )"
rc=$?
assert_ne "$rc" "0" "a uid mismatch is refused"
assert_contains "$out" "65534" "the refusal names the uid it expected"

assert_report
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
chmod +x tests/unit/test_live_guard.sh
bash tests/unit/test_live_guard.sh
```
Expected: FAIL — `tests/live/lib/testbed.sh` does not exist (the `exit 90` path).

- [ ] **Step 3: Write `docker/compose.live.yaml`**

An overlay, nothing more. It must:
- Replace `palworld-server:/opt/palworld/server` with a bind mount of `${PALWARDEN_LIVE_TESTBED}/server`.
- Replace `palworld-saved:/opt/palworld/server/Pal/Saved` with a bind mount of `${PALWARDEN_LIVE_TESTBED}/server/Pal/Saved`.
- Set `UPDATE_ON_START: "false"`.
- Leave every other service, volume and env var alone.

Use the long `type: bind` form so a missing host path is an error rather than Docker silently creating a root-owned directory — that silent-creation behaviour is exactly how a testbed ends up unwritable by the game. Add a header comment stating the file is an overlay, the exact `-f … -f …` invocation, and the one-time `UPDATE_ON_START=true` first run.

- [ ] **Step 4: Write `tests/live/lib/testbed.sh`**

Implement the interfaces listed above. Requirements:

- `live_require_testbed` checks, **in this order**, refusing with a distinct message each time: the testbed directory exists; the marker exists; the owning uid equals `PALWARDEN_LIVE_EXPECT_UID` (default `1000`); `server/PalServer.sh` exists and is executable. Order matters — a missing directory must not be reported as a uid problem.
- The marker refusal prints the exact `touch` command to create it.
- The not-installed refusal names `UPDATE_ON_START=true`, matching the entrypoint's own wording so the two do not diverge.
- `live_up` uses `PALWARDEN_MODE=embedded` (the web UI and job worker are embedded-only by design), brings up the overlay, and waits for REST readiness with a **bounded** poll — a failure must fail, not hang.
- `live_api` sends Basic auth plus `X-Palwarden-Token`, taking credentials from env with test defaults; mutations need the token or they 403.
- `live_wait_job` polls `GET /api/jobs/<id>` until the state leaves `queued`/`running`, bounded, and echoes the final state.
- `live_reset_world` deletes `server/Pal/Saved` **only** after `live_require_testbed` has passed, so it can never run against an unmarked directory.
- Every function that mutates anything calls or presumes `live_require_testbed`. State that rule in a comment.

- [ ] **Step 5: Add the `--live` gate to `tests/run.sh`**

Mirror the integration gate exactly: honour `RUN_LIVE=1` **or** `--live`, default off, and when skipping print `(live tests skipped; pass --live to run them — needs a real server, see docs/tools.md)`. A tier nobody knows exists is a tier nobody runs. The live block must not execute when the gate is off, and the default `./tests/run.sh` must stay hermetic.

- [ ] **Step 6: Run the guard test and the full hermetic suite**

```bash
bash tests/unit/test_live_guard.sh
./tests/run.sh
./tests/lint.sh
```
Expected: guard test passes, `ALL SUITES PASSED`, `LINT PASSED`, and the run prints the live-skip line.

- [ ] **Step 7: Mutation-check each refusal**

Remove, one at a time: the marker check, the uid check, the install check, and the ordering (make the uid check run before the existence check). Confirm each produces a FAIL, restore from a file copy, confirm green. Record the counts.

- [ ] **Step 8: Commit**

```bash
git add docker/compose.live.yaml tests/live/lib/testbed.sh tests/unit/test_live_guard.sh tests/run.sh
git commit -m "Add the live test tier's plumbing and its guard

The live tier stops the server, replaces worlds and restarts it, so its guard is
tested by a hermetic suite that actually runs in CI — a destructive suite's safety
check cannot be verified only by a tier nobody runs automatically. A marker file
makes it impossible to point at a real deployment by mistyping a path, and the uid
check refuses up front rather than letting a mismatch surface later as a permission
error inside the game.

The overlay leaves docker/compose.yaml untouched so the normal deployment cannot
drift into the test one."
```

---

### Task 2: The restore round-trip against a real game

**Files:**
- Create: `tests/live/test_restore_roundtrip.sh`

**Interfaces consumed:** everything from `tests/live/lib/testbed.sh` (Task 1).

Spec section: `## What the live tier tests`, item 1. **This is the highest-value test in the tier** — the one path where stop, extract, swap, chown, start and readiness confirmation have only ever met stubs.

- [ ] **Step 1: Write the test**

`tests/live/test_restore_roundtrip.sh`, self-contained per the global constraint:

1. `live_require_testbed`, `live_up`.
2. **Create the world content this test will assert on** — write a marker file into the live `Pal/Saved` (a file the game does not manage, so the game cannot rewrite it), so the assertion never depends on an assumed world state.
3. Enqueue `backup`; wait; assert `succeeded`. Capture the archive name from the job output.
4. **Modify the world** — change the marker's contents.
5. Enqueue `backup_restore` with that archive and `confirm: true`; wait; assert `succeeded`.
6. Assert the marker's **original** contents are back.
7. Assert the server came up: `/api/health` reports the service active and the REST API reachable.
8. Assert the pre-restore safety archive exists and is listed by `/api/backups`.
9. Assert the displaced tree was **deleted** (readiness was confirmed, so it should not linger) — and that its absence is not merely because it was never created, by checking the job output names it.
10. `live_down`.

Bound every poll. Every assertion must reference something this test created.

- [ ] **Step 2: Verify what you can without a game**

You cannot run this. You **can** and must:
- `bash -n tests/live/test_restore_roundtrip.sh` (syntax).
- `./tests/lint.sh` (shellcheck).
- Confirm it refuses immediately with no testbed: `PALWARDEN_LIVE_TESTBED=/nonexistent bash tests/live/test_restore_roundtrip.sh` must exit non-zero **without** starting Docker.
- Confirm `./tests/run.sh` (default) does not run it.

Report exactly this: which checks you ran, and that the live assertions are unverified pending the owner's testbed.

- [ ] **Step 3: Commit**

```bash
git add tests/live/test_restore_roundtrip.sh
git commit -m "Add the live restore round-trip

The feature's central promise — a world comes back — has only ever been tested
against stubs for the stop, the start and the readiness check. This asserts it
against a real game: back up a world, change it, restore, and confirm both the
content and that the server came up through the real REST readiness check.

Self-contained by construction: it asserts on a marker file it writes itself, so an
accumulating testbed world cannot make it pass or fail for the wrong reason."
```

---

### Task 3: Save-on-stop consistency and a real scheduled backup

**Files:**
- Create: `tests/live/test_stop_consistency.sh`

Spec sections: items 2 and 4.

- [ ] **Step 1: Write the test**

Two independent scenarios in one suite (they share an expensive bring-up):

**Save-on-stop:** bring up; write a marker into `Pal/Saved`; enqueue `graceful_stop` with `confirm: true`; wait; assert the world on disk is loadable — bring the server back up and assert `/api/health` reports it active and REST reachable, and that the marker survived. The point is that `SIGINT` produced a *consistent* world, which is asserted only by reading today.

**A real scheduled backup:** with a real `Pal/Saved` present, run `palworld-backups --if-due` inside the container and assert it creates an archive; then assert the archive **actually unpacks** and contains `SaveGames` — the hermetic suite's fixture cannot prove that. Then run `--if-due` again immediately and assert it creates nothing (not due).

- [ ] **Step 2: Verify what you can** — `bash -n`, `./tests/lint.sh`, the no-testbed refusal, and that the default run skips it. Report which live assertions are unverified.

- [ ] **Step 3: Commit** with a message explaining that an archive which unpacks is the thing the fake-server fixture cannot demonstrate.

---

### Task 4: Config and Engine.ini drift after a real boot, plus `update_check`

**Files:**
- Create: `tests/live/test_config_drift.sh`
- Modify: `docs/tools.md`, `docs/palworld-service-runbook.md`, `README.md`

Spec sections: items 3 and 5, plus the operator documentation.

- [ ] **Step 1: Write the test**

**Drift after a real rewrite** — this is the one piece of logic that cannot be tested any other way. The drift check compares *semantically* because the game reformats values (`True` == `1`, `60.000000` == `60`):

1. Bring up; set a known Engine.ini value through `engine_save` (e.g. `NET_SERVER_MAX_TICK_RATE`), then `engine_apply`.
2. Restart the server so the **game itself rewrites** the file.
3. Assert `/api/engine` reports **no drift** — the semantic comparison holding across the game's own reformatting is the assertion.
4. Do the same for `PalWorldSettings.ini` via `config_apply`, and assert `/api/config` shows the applied value with secrets redacted.

**`update_check`** — enqueue it and assert it reaches a terminal state and reports a buildid, against real Steam. Do **not** assert "no update available"; that depends on Valve and would be a flaky assertion by construction.

- [ ] **Step 2: Documentation**

`docs/tools.md` gets the tier and the exact commands: creating the testbed, the one-time `UPDATE_ON_START=true` install, and the `-f … -f …` overlay invocation. The runbook gets the recovery note (`--reset-world`, and that world drift is expected). `README.md` gets one line in its testing orientation so the tier is discoverable. Cross-reference rather than duplicating.

State plainly in the docs that the tier **does not run in CI** and why — otherwise someone will eventually try to add it.

- [ ] **Step 3: Verify what you can** — `bash -n`, `./tests/lint.sh`, `./tests/run.sh` still hermetic and still printing the live-skip line, the no-testbed refusal. Verify every command you documented exists (flags, unit names, paths) against the working tree.

- [ ] **Step 4: Commit.**

---

## Self-Review

**Spec coverage.** The testbed, marker guard, uid check and overlay → Task 1. Restore round-trip (item 1) → Task 2. Save-on-stop (2) and a real scheduled backup (4) → Task 3. Config/Engine drift (3) and `update_check` (5) → Task 4, with the docs. `--reset-world` and the `--live` gate → Task 1. The "guard needs a hermetic suite" requirement → Task 1's `tests/unit/test_live_guard.sh`.

**Placeholder scan.** No "TBD"/"add validation"/"handle errors" — each task names its specific assertions and its specific refusals.

**Type consistency.** `live_require_testbed`, `live_up`, `live_down`, `live_api`, `live_enqueue`, `live_wait_job`, `live_reset_world`, `TESTBED`, `MARKER`, `PALWARDEN_LIVE_TESTBED`, `PALWARDEN_LIVE_EXPECT_UID` are defined in Task 1 and used under those names in Tasks 2–4.

**The honest limit, stated once so no task pretends otherwise.** No implementer can execute a live suite; the game install is the owner's one-time step. Every task therefore verifies syntax, shellcheck, the no-testbed refusal and the default-run skip, and reports its live assertions as unverified. Task 1 is the exception — its guard is fully testable in CI, which is deliberate, because it is the safety mechanism.
