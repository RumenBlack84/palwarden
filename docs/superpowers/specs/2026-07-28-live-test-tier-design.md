# Live test tier — design

**Date:** 2026-07-28
**Status:** approved, not yet implemented
**Goal:** run the tooling against a **real, throwaway Palworld server** on a persistent
bind mount, so the paths that only a real game can exercise get tested — without
weakening the hermetic suites that gate CI.

## Why this exists

Three tiers of confidence exist today and the top one is missing.

The unit suites stub every tool. The integration suite runs real containers but
against `tests/fixtures/fake-server` — a shell script pretending to be the game. So
a whole class of behaviour has **never** been executed:

* `backup_restore` has never run against an actual server. Every test to date used
  a stub for the stop, the start and the readiness check.
* `SIGINT`-on-stop producing a *consistent* world is asserted only by reading.
* The drift check exists precisely because the game **rewrites** `PalWorldSettings.ini`
  and `Engine.ini` and normalises values (`True` == `1`, `60.000000` == `60`). Only a
  real boot proves the semantic comparison holds.
* `update_check` has never talked to Steam.

The disaster-recovery feature this tier tests was built entirely against stubs. That
was the right trade for CI, but it means the feature's central promise — a world
comes back — is unproven against the thing it exists to protect.

## What this tier is NOT

**It does not run in CI**, and it does not replace anything. The hermetic suites stay
the gate, for a reason this project learned the hard way: the integration suite once
wrote into a persistent bind-mounted fixture, so each run pre-seeded the next. A
fresh clone would have failed, and one assertion was passing over a *failed* backup.
Persistence hid a real defect for two tasks.

So the rule is: **CI stays hermetic, the live tier is a local fidelity check.** Run it
before trusting something on a real host, not as a merge gate.

## The testbed

| Path | What | Persistence |
|---|---|---|
| `~/palworld-testbed/server/` | The game install, bind-mounted to `/opt/palworld/server` | Persistent. Installed **once** with `UPDATE_ON_START=true`; every later run uses `false`. |
| `~/palworld-testbed/.palwarden-live-testbed` | Marker file | Required. See below. |

Roughly 8–10 GB. Deliberately **outside the repository tree**, so it cannot be
committed by accident and does not clutter `git status` — this repo has already had
one incident of a stray file reaching a public remote via `git add -A`.

The container's `steam` account is uid/gid **1000**, and so is the developer account
here, so the bind mount needs no ownership translation. That is luck, not design:
CI has already broken once on a uid 1000-vs-1001 mismatch, so the live tier
**verifies the uid match up front** and refuses with a clear message rather than
failing later as a permission error inside the game.

### World state drifts, and that is fine

There is **no** pristine-world snapshot and no reset between runs. We are testing the
*tooling*, not the game, and a save that accumulates play state costs nothing.

That has one binding consequence for how the tests are written: **every live test must
be self-contained.** It asserts against an artefact it created in the same run — "the
world I restored matches the backup I just took" — never against an assumed world
state, a fixed file list, or a specific save size. A test that needs particular world
content must create it first.

This is not merely a workaround for drift; it is the same property that makes the
hermetic suites honest, so the live tier does not get a weaker standard.

### Escape hatch

`--reset-world` deletes `Pal/Saved` so the server regenerates a fresh world on next
boot. For when a half-finished run leaves the testbed in a state not worth reasoning
about. It keeps the expensive install and throws away only the cheap part — which is
why no snapshot machinery is needed.

## Safety guard

The live tier **stops the server, replaces worlds and restarts it.** Pointed at a real
deployment it would be destructive.

So it refuses to run unless `$PALWARDEN_LIVE_TESTBED/.palwarden-live-testbed` exists,
and the failure message says how to create it. A mistyped path is the one accident
that would actually hurt, and a marker file makes it impossible: a real deployment
will not have one.

The guard is checked **before** anything is started or mounted, and it is
mutation-tested like every other refusal in this project.

## Wiring

`docker/compose.live.yaml`, used as an overlay:

```bash
docker compose -f docker/compose.yaml -f docker/compose.live.yaml up -d
```

It swaps the `palworld-server` and `palworld-saved` **named volumes** for bind mounts
into the testbed and sets `UPDATE_ON_START=false`. The default `compose.yaml` is
untouched, so nothing about the normal deployment changes — an overlay is the
idiomatic Docker mechanism for exactly this and keeps the two configurations from
drifting into one another.

First run only, to install the game:

```bash
UPDATE_ON_START=true docker compose -f docker/compose.yaml -f docker/compose.live.yaml up -d
```

## What the live tier tests

In priority order — highest first, because it is the promise nothing has ever verified:

1. **The restore round-trip against a real game.** Create a backup of a real world,
   modify the world, restore, and assert the world came back **and** the server came
   up through the real REST readiness check. This is the one path where every
   component — stop, extract, swap, chown, start, confirm — has only ever met stubs.
2. **Save-on-stop consistency.** A graceful stop's `SIGINT` produces a world the
   server will load again without complaint.
3. **Config and Engine.ini apply, then drift.** Apply, boot, let the game rewrite the
   files, and confirm the drift check reports clean — the semantic comparison
   (`True` == `1`, `60.000000` == `60`) is only meaningfully tested here.
4. **A real scheduled backup.** `--if-due` against a real `Pal/Saved`, producing an
   archive that actually unpacks.
5. **`update_check`** against real Steam.

## Tiers afterwards

| Tier | Gate | In CI | Server |
|---|---|---|---|
| Unit | default | yes | stubs |
| Integration | `RUN_INTEGRATION=1` | yes | `tests/fixtures/fake-server` |
| **Live** | `RUN_LIVE=1` **and** the marker | **no** | real, on the bind mount |

`tests/live/` holds the new suites, following the existing house pattern (bash,
sources `tests/lib/assert.sh`, ends with `assert_report`). `tests/run.sh` grows a
`--live` mode that is **off by default** and prints plainly that it is skipping,
rather than passing silently — a tier nobody knows exists is a tier nobody runs.

## Error handling

* Missing marker → refuse, with the command to create it.
* Testbed absent or uid mismatch → refuse, naming the expected uid, before any
  container starts.
* Game not installed and `UPDATE_ON_START=false` → the entrypoint already handles
  this and says to set `true` for the first run; the live runner surfaces that
  message rather than burying it.
* A live test that fails mid-flight leaves the world drifted. That is accepted;
  `--reset-world` is the recovery.

## Deliberately not in scope

* **Running the live tier in CI.** No game install there, and the whole point is that
  CI stays hermetic.
* **Replacing the fake-server fixture.** It stays as the CI gate.
* **Testing the game itself.** We assert the tooling's behaviour, not Palworld's.
* **A pristine-world snapshot or per-run reset.** Explicitly rejected: drift is
  acceptable, self-contained assertions make it harmless, and `--reset-world` covers
  the rest.
