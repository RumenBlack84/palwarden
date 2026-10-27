# Idle Shutdown & Knock-Wake — Code Review Follow-ups

Date: 2026-10-24
Owner / next implementation session: Hermes `code64` profile
Status: REPAIRED — F1-F10 and Sol review rounds 1-2 implemented with
regression tests (see Repair completion record and Sol round-2 disposition
below). Docker, browser, live-game tiers and the root-only ack matrix remain
NOT verified; the R5 spec amendment is PROPOSED pending independent review.
Scope: current staged, unstaged, and untracked idle-shutdown/knock-wake changes

## Companion documents

- [Design spec](../specs/2026-10-18-idle-shutdown-knock-wake.md)
- [Original implementation plan and evidence](2026-10-18-idle-shutdown-knock-wake.md)

This is a repair backlog and handoff, not an independently reviewed implementation
plan or merge approval. The original documents' completion claims do not resolve
the findings below. Re-read current source: line references describe the reviewed
working tree and will drift.

## Instructions for the code64 session

1. Inspect `CLAUDE.md`, current git status/diff, the companion documents, and each
   affected definition/caller before editing. Preserve unrelated working changes.
2. Derive a focused repair plan from these findings and the spec; obtain an
   independent review for nontrivial lifecycle/design changes before execution.
3. Add reproducing regression tests first (RED), apply focused repairs (GREEN),
   and run adjacent tests plus `./tests/run.sh`. Use isolated fixture paths and
   synthetic secrets only. Do not weaken safety checks to make tests pass.
4. Re-review interacting fixes together, especially lifecycle ownership/state,
   unsafe-marker preservation, nested restore, and wake admission/execution.
5. Run Docker acceptance where available; distinguish unit, Docker, browser, and
   real-game results. Missing or skipped checks are not passes. No production
   restart, destructive recovery test, commit, or push without explicit approval.
6. Record findings' dispositions and actual commands/results here. Check off an
   item only when its observable safety properties have been verified.

This file requests work by code64; it does not modify that profile's configuration,
skills, memories, or scheduled jobs, and does not dispatch work automatically.

## Priority 1 — Safety and maintenance fencing

### F1 — Direct maintenance does not publish lifecycle state or rotate generation

- [ ] **P1 — OPEN**
- References: `lib/palwarden-lifecycle-bash:83–86`,
  `lib/palwarden_lifecycle.py:845–863`, `sbin/palworld-restore:1872–1874`.
- Defect: direct controllers acquire flock but do not publish `active` state or
  rotate the generation. A wake admitted before a direct stop can remain valid
  afterward. An interrupted direct update/restore can leave status `idle`, so
  automatic wake is permitted after the lock is released.
- Evidence: isolated reviewer ran real stop/update controllers against fixture
  services; generation remained unchanged and status idle, including after the
  update controller was killed. The old wake fence was still accepted.
- Repair direction: centralize outer lifecycle transaction state in the shared
  lifecycle layer for direct and job-driven controllers. Socket leases and nested
  borrowers must not independently rotate or clear state. Preserve interrupted
  state until explicit operator recovery, not merely flock availability.
- Acceptance: direct stop invalidates an already-admitted wake within its 15-second
  lifetime; direct update/restore interruption inhibits UDP/local/API wake; nested
  controllers preserve outer ownership/state; feature-off behavior remains usable.

### F2 — Successful unrelated jobs clear an existing unsafe-maintenance marker

- [ ] **P1 — OPEN**
- References: `sbin/palwarden-jobd:1611–1627`, `lib/palwarden_lifecycle.py:462–479`.
- Defect: jobd overwrites previous state with active, then idle on success. A
  successful `update_check` or `api_save` can erase `unsafe/restore` without
  reconciling world data or requiring acknowledgement. Marker writes also occur
  outside lifecycle ownership.
- Evidence: reviewer exercised real job execution with isolated successful
  commands. Parent independently reproduced unsafe -> idle through `run_job()`
  with execution stubbed successful.
- Repair direction: preserve pre-existing unsafe state until explicit recovery;
  serialize state transitions under lifecycle ownership. Do not equate success of
  a different operation with reconciliation of an interrupted restore/update.
- Acceptance: unrelated successful jobs cannot clear unsafe state; concurrent
  direct maintenance cannot be marked idle by job completion; recovery remains
  explicit; queued wakes remain fenced throughout. Test F1/F2 as one lifecycle
  protocol rather than adding contradictory wrappers.

### F3 — Wrong-shaped or ambiguous players JSON can authorize shutdown

- [ ] **P1 — OPEN**
- References: `sbin/palworld-idle-watch:71–90`, `sbin/palworld-fps:111–116`,
  `lib/palwarden_presence.py:106–123`.
- Defect: extracting first `{` through last `}` accepts a top-level array as an
  object. Standard JSON decoding also silently accepts duplicate keys.
- Reproductions: use the exact valid JSON fixture `[{"players":[]}]`. Also use
  `{"players":[{"playerId":"A"}],"players":[]}` to prove conflicting occupancy
  cannot be silently discarded. Both actual probe payloads authorized one
  stubbed stop with otherwise eligible history.
- Repair direction: strictly parse the complete expected response, reject
  duplicate keys, then validate schema. Inspect the real API client's output
  contract before replacing extraction; share strict presence parsing between
  sampler and final watcher checks without breaking unrelated consumers.
- Acceptance: arrays, duplicate keys, trailing garbage, wrong shapes, and malformed
  responses invalidate evidence and never stop; a legitimate empty response still
  works; an occupied response cannot become empty through parsing.

### F4 — Policy changes during the final players request are ignored

- [ ] **P1 — OPEN**
- Reference: `sbin/palworld-idle-watch:311–361`.
- Defect: configuration is reread after lock acquisition but not after the final
  players request. Config-save does not take that lock. A completed save disabling
  idle shutdown (or increasing its timeout) can precede an actual stop that still
  uses stale policy.
- Evidence: parent reran the real `tick()` probe whose final-fetch callback changed
  timeout from 1 to 0 before returning empty; one stubbed stop was still issued.
- Repair direction: revalidate current policy after the final request and before
  committing the stop. Define and test the side-effect boundary, including delays
  from notification/event work; edits cannot undo an already-issued stop.
- Acceptance: disabling idle or increasing timeout while final fetch is blocked
  prevents a not-yet-issued stop. Keep existing config-flip/uptime/state checks.

## Priority 2 — Ordering, recovery, and operator correctness

### F5 — Failed observations bypass the sequence fence

- [ ] **P2 — OPEN**
- References: `sbin/palworld-fps:239–245`,
  `sbin/palworld-idle-watch:335–339`, `lib/palwarden_presence.py:216–228`.
- Defect: successes apply their reserved sequence, failures call unsequenced
  `invalidate()`. An older success can overwrite a newer failure; an older failure
  can erase newer successful evidence.
- Evidence: parent reran real SQLite observation transactions and watcher failure
  probes. A failed final check left applied sequence 19 while its reserved sequence
  was 21; pending sequence 20 was subsequently accepted.
- Impact qualification: clearing emptiness prevents immediate resurrection of the
  old empty interval; nevertheless superseded evidence is accepted and continuity
  can be reset incorrectly. Do not exaggerate this as an immediate unsafe stop.
- Repair direction: apply failed results through the same reserved-sequence writer;
  retain fail-closed handling for failures before reservation or DB unavailability.
- Acceptance: newer failure fences older success; older failure cannot erase newer
  success; failed final checks reset continuity; no transaction spans HTTP.

### F6 — Restore reacquires rather than borrows an inherited lifecycle lock

- [ ] **P2 — OPEN**
- Reference: `sbin/palworld-restore:1870–1874`.
- Defect: restore unconditionally acquires a new open lock description even when
  called under legitimate inherited ownership, creating a self-conflict with a
  default 600-second wait before failure.
- Evidence: reviewer used real flock with a validated borrowed descriptor and
  isolated restore preflight/storage helpers; restore failed acquiring the lock.
- Repair direction: validate/reuse inherited ownership and distinguish borrowed
  from owned cleanup. Audit backup/lifecycle acquisition order before changing it.
- Acceptance: nested restore proceeds without reacquisition; competing processes
  remain excluded after nested return until the outer owner exits; borrowed cleanup
  never unlocks the outer transaction; failure paths release only their own state.

### F7 — Acknowledgement accepts crash-backoff instead of wanted-down state

- [ ] **P2 — OPEN**
- References: `lib/palwarden_lifecycle.py:947–964`,
  `docker/shims/systemctl:110–112`.
- Defect: acknowledgement only requires `is-active` to report inactive. The shim
  also reports inactive when the service is down but the supervisor wants it up.
- Evidence: reviewer exercised the real shim with fixture supervisor state:
  `service_state()` returned crash-backoff, yet acknowledgement cleared unsafe.
  Root authorization was simulated; this was not an actual root-only test pass.
- Repair direction: require confirmed stopped/wanted-down service state under
  ownership, preserving root-only authorization and explicit confirmation.
- Acceptance: crash-backoff, starting, stopping, and unknown state refuse without
  changing marker/generation; fully stopped/wanted-down recovery succeeds without
  starting the game. Exercise actual root-only checks in an isolated container.

### F8 — Browser idle timeout is labelled seconds but interpreted as minutes

- [ ] **P2 — OPEN**
- References: `webui/palwarden.html:191–194,552–562,597`,
  `sbin/palworld-idle-watch:124–126,288–299`.
- Defect: the form/help/error text presents seconds while posting the number
  unchanged as `IDLE_TIMEOUT`, whose specified/backend unit is minutes.
- Repair direction: retain the spec's minute contract and correct every affected
  label/help/validation message, unless an independently reviewed unit conversion
  is deliberately chosen. Do not silently reinterpret persisted configuration.
- Acceptance: displayed and saved units agree with the watcher and docs; test
  actual rendered labels, bounds, existing values, and save round-trip semantics.

### F9 — Python notification adapters execute a function-only helper

- [ ] **P2 — OPEN**
- References: `lib/palwarden_lifecycle.py:678–688`,
  `sbin/palworld-idle-watch:209–214`, `lib/palworld-notify:4`.
- Defect: executing the shipped helper merely defines `palworld_notify()` and
  exits; it does not call the function. Dedicated idle/wake/readiness posts are
  absent even when notification configuration exists. Existing shell lifecycle
  posts are separate and may still work.
- Evidence: parent tested a source-only helper; Python execution did nothing,
  sourcing and explicitly invoking its function worked. Executable notifier stubs
  in current tests mask the contract mismatch.
- Repair direction: use fixed shell code to source the optional helper and invoke
  its function with argv-passed kind/message; never interpolate message text into
  code. Preserve missing/failing helper as nonfatal and bounded.
- Acceptance: a function-only helper is actually invoked; absence/failure remains
  nonfatal; shell metacharacters in synthetic messages remain literal; idle and
  truthful wake/readiness outcomes have the intended notification counts.

### F10 — Listener arming and cooldown logs are not bounded

- [ ] **P2 — OPEN**
- References: `sbin/palworld-knock:323–325,365`,
  `sbin/palworld-knock:264–265`.
- Defect: every lease clears `armed`, so each new lease logs arming even without
  traffic. Accepted packets during cooldown produce unthrottled no-op messages.
- Evidence: parent reproduced repeated arming over empty consecutive leases and
  repeated cooldown logs through the real packet handler with start results
  isolated. Invalid-token flood tests do not cover these paths.
- Repair direction: separate socket ownership from log transition/rate-limit
  tracking; aggregate repeated accepted-but-ineligible traffic too. Preserve
  bounded leases, port handoff, and controller progress.
- Acceptance: extended quiet stopped operation has bounded logs; repeated valid
  cooldown knocks have bounded/aggregated logs and no starts; tokens, payloads,
  and source addresses remain absent; manual controllers are not starved.

## Review verification already performed

These are baseline review results, NOT proof that the above findings are fixed:

| Command | Observed result |
|---|---|
| `bash tests/unit/test_knock.sh` | 128 passed, 0 failed |
| `bash tests/unit/test_idle_watch.sh` | 63 passed, 0 failed |
| `bash tests/unit/test_lifecycle_lock.sh` | 49 passed, 0 failed; root-only acknowledgement happy path explicitly unavailable |
| `bash tests/unit/test_player_presence.sh` | 82 passed, 0 failed |

Parent additionally reran isolated parsing/config-change/sequence probes and the
unsafe-marker overwrite probe. The first jobd probe import needed the development
`PALWARDEN_PARSER_BIN` override; rerun with the repository parser succeeded.
No concrete token-disclosure path was confirmed in the normal reviewed
config-save/public-job serialization flow; this is not an exhaustive security
certification.

Docker, browser, and real-game suites were not rerun for this review. Previous
implementation evidence remains historical, not fresh repair verification.
No source edits, production operations, commits, or pushes were made by the review.

## Local evidence pointers (ephemeral, not repository dependencies)

Under `/home/hermes/.hermes/cache/scratch/`:

- `palwarden-review-knock.log`
- `palwarden-review-idle_watch.log`
- `palwarden-review-lifecycle_lock.log`
- `palwarden-review-player_presence.log`
- `presence-review-probe.py` — isolated DB/watcher reproductions; stop is stubbed.
- `palwarden-review-probes.py` — reviewer lifecycle probes. Inspect before reuse;
  do not blindly rerun controller probes against installed helpers or live state.

Independent review transcripts:
`/home/hermes/.hermes/cache/delegation/live/deleg_65fadf87/task-{0,1,2}.log`.
Scratch evidence may be pruned; permanent regression tests must be self-contained.

## Progress note (2026-10-24, repair session, code64)

Implemented and green-tested (RED-first; unit suites named are per-file):
- F3 FIXED: strict shared parser `palwarden_presence.parse_api_json` (whole-
  text JSON, duplicate keys at any depth refused, top-level arrays refused);
  `extract_json` in palworld-idle-watch/palworld-fps delegate to it.
  test_player_presence.sh 91/0.
- F4 FIXED: idle-watch tick revalidates config after the final fetch/apply
  and before any side effect (disable / raised timeout / uptime reset abort).
- F5 FIXED: failures apply through the reserved sequence in both watcher and
  sampler; unsequenced invalidate only pre-reservation / dead DB.
  test_idle_watch.sh 81/0.
- F8 FIXED: webui idle-timeout label/help/validation say minutes; check
  interval keeps seconds. test_webui_panel.sh static block green.
- F9 FIXED: Python adapters source the function-only helper and invoke
  `palworld_notify` with argv-passed kind/message; new test_notify_adapter.sh
  8/0; test stubs converted to the shipped function-only contract.
- F10 FIXED: arming logs the closed->armed transition; cooldown/already-
  running/refused no-ops aggregated. test_knock.sh 133/0.
- Pre-existing, environment/test-only (not caused by these repairs):
  test_restore_apply expects a non-group-writable TMPDIR (host umask 002);
  knock concurrent-wake race window widened 0.3s->1.0s (loser startup could
  outlive it under load).

Batch 1 (F1/F2/F6/F7): repair plan
`2026-10-24-idle-repair-plan.md` (1b REVISED to keep the re-exec bridge:
active+rotate+TXN before exec, EXIT-trap `complete <rc>` in the owner
script, sticky-unsafe write_state, jobd owner-only marking, restore borrow,
ack via service_state=='stopped'). RED tests in place and failing for the
right reasons: test_lifecycle_lock.sh section 11, test_jobd.sh F2 section,
test_restore_apply.sh F6 section. IMPLEMENTATION PENDING the independent
plan-review gate: the reviewer model route failed 5 consecutive dispatches
(connection errors, ~2h); no review has passed and none is claimed.

Full unit suite at this point: green (test_restore_apply needs umask 022 on
this host, see above). Docker/browser/live tiers NOT rerun — not a pass.

## Repair completion record

For each F-item record: regression test, RED result, repair summary, GREEN result,
independent review disposition, and remaining tier-specific checks. Final merge
readiness requires the findings resolved or explicitly accepted by Warden Brian,
plus fresh verification and an independent review of the combined repair diff.

Batch 1 (lifecycle protocol) — implemented 2026-10-24 after the same
RED-first discipline. REVIEW DISPOSITION: the independent plan-review gate
could not be satisfied — the reviewer model route (local Gemma server at
192.168.0.31:8080) was unreachable for ~2h and failed 5 dispatch attempts
(connection errors). Warden Brian explicitly directed a bypass ("bypass it and
you reviewing of files"); per CLAUDE.md this is recorded as a user-directed
bypass, NOT a passed independent review. The author's own review of the
touched files is included below; a fresh-session review of the final diff is
recommended before merge if the reviewer route recovers.

- F1 FIXED: the acquire bridge publishes `active` + rotated generation and
  exports `PALWARDEN_LIFECYCLE_TXN=1` before exec; the re-exec'd owner script
  (sourced `lib/palwarden-lifecycle-bash`) registers an EXIT trap calling the
  new `complete <rc>` subcommand (0 -> idle, else unsafe; sticky-unsafe-safe,
  never alters the controller's exit code); TXN is unset immediately so
  nested controllers stay plain borrowers. Interrupted owners (SIGKILL/unguarded
  TERM) leave `active` — fail closed until ack (documented in runbook +
  module docstrings). Exec-failure closes as idle (nothing ran; rotated
  generation still kills in-flight fences).
  Tests: test_lifecycle_lock.sh 11a-11d, 11g (RED verified: bridge wrote no
  state, no `complete` verb, STILL-ADMITTED fence -> GREEN 66/0).
- F2 FIXED: `write_state` refuses to leave `unsafe` without `force=True`
  (ack only); escalation allowed. jobd marks state only when it OWNS the
  lifecycle lock (nonblocking acquire before step 1; busy -> writes nothing,
  steps fail visibly on their own acquisition); ownership handed to steps via
  env+pass_fds; `backup_restore` excluded from the wrap to preserve the
  §4.1 lock order (restore publishes its own). Tests: test_jobd.sh F2
  section (RED: success cleared unsafe + concurrent holder erased ->
  GREEN 397/0); test_lifecycle_lock.sh 11c.
- F6 FIXED: `palworld-restore` borrows an inherited lock descriptor
  (`ownership_from_env`) instead of acquiring a new flock (self-conflict that
  waited the full timeout); `_lifecycle_owned` gates state publication and
  release so a borrowed restore neither marks nor unlocks the outer
  transaction. Test: test_restore_apply.sh F6 (RED: rc=1 busy -> GREEN
  252/0, outer lock verified held by a separate-process probe).
- F7 FIXED: `acknowledge-maintenance` requires `service_state() == "stopped"`
  (systemd: inactive+disabled; s6: down+wanted-down marker) instead of
  `is-active == inactive`; crash-backoff/starting/unknown refuse without
  touching marker or generation; the path never starts the game. Tests:
  test_lifecycle_lock.sh 11e (green basis pin) + 11f root-gated matrix
  (harness not root -> labelled UNAVAILABLE, NOT a pass); 6f root stubs
  updated to the inactive+disabled contract.
- F3/F4/F5/F8/F9/F10: see progress note above (all RED-first, GREEN).
- Full unit suite after Batch 1: ALL SUITES PASSED (host umask 022; the
  umask-002 test_restore_apply quirk is pre-existing and environment-only).
- NOT verified here (not a pass): Docker integration (`RUN_INTEGRATION=1
  ./tests/run.sh`), browser tier, live-game tier, and the root-only ack
  matrix. The s6 wanted-down paths in containers should get one embedded
  boot check (interrupt a restore, confirm wake stays fenced, ack refuses
  crash-backoff, ack succeeds after `s6-svc -d`) before merge.

Sol 6.1 review round (user-run, 2026-10-24) — dispositions:

- R1 FIXED (P1, confirmed): sticky protection covered `unsafe` but an
  ABANDONED `active` (holder died; kernel released the lock) could be
  silently replaced by the next transaction's success. New
  `escalate_abandoned()` — called by every publisher immediately after a
  fresh acquire (bridge, jobd owner path, restore owner path, idle-watch
  stop) — proves the previous holder died (all normal completers write
  before releasing) and escalates the marker to sticky `unsafe`, which
  survives the new transaction's completion writes until ack. Recovery
  stays deadlock-free: the new transaction still proceeds (lock
  serializes), only the marker is preserved. Test:
  test_lifecycle_lock.sh 12a (RED: later success cleared it -> GREEN).
- R3 FIXED (confirmed): jobd's busy-lock fallback ran the steps anyway;
  side effects precede each step's own acquisition (engine rollback
  truncates a file before any restart). Wrapped jobs are now REFUSED
  (failed, exit 1) while the lock is busy, running no steps. Test:
  test_jobd.sh R3 (RED: succeeded with 1 step logged -> GREEN: failed,
  argv.log empty).
- R4 FIXED (confirmed): the bash help-bypass triggered on --help ANYWHERE
  in argv, and the systemctl shim discards --help and mutates anyway.
  Bypass now requires a bare single-arg help invocation; mutating
  commands containing --help enroll normally. Test:
  test_lifecycle_lock.sh 12b (RED: bypassed -> GREEN: enrolled).
- R5 FIXED (confirmed): two ownership paths published nothing.
  (a) idle-watch's stop acquired the lock directly (no bridge/trap) and
  stopped the server with the marker still plain `idle` — a wake admitted
  mid-shutdown could start the game. It now escalates, publishes
  active+rotate before the stop, and completes idle/unsafe after.
  (b) start_if_down never rotated the generation after a confirmed start,
  so sibling wakes fenced to the old generation piled on. It now rotates
  (marker stays idle; the wake path is not a maintenance transaction).
  Tests: test_idle_watch.sh R5a (RED: during=idle -> GREEN),
  test_lifecycle_lock.sh 12d (RED: same-gen -> GREEN).
- R6 FIXED (confirmed): acknowledge read PALWARDEN_LIFECYCLE_SERVICE for
  its message but called service_state() without it, checking the default
  unit on systemd. Now service_state(service). Test: 12c static pin
  scoped to the function (RED -> GREEN).
- R7 FIXED (confirmed): the webui validation said "whole number of
  minutes" for IDLE_CHECK_INTERVAL and KNOCK_COOLDOWN, which are seconds.
  Messages are now per-field (minutes/seconds/seconds). Test:
  test_webui_panel.sh R7 (RED -> GREEN).
- Sol's F7/strict-parser/knock-log observations: no repo change needed
  (its own checks confirmed those behaviors).
- Full unit suite after this round: ALL SUITES PASSED (umask 022).
  Docker/browser/live tiers and the root-only ack matrix remain NOT run.

## Sol round-2 disposition (2026-10-26, code64; implementation authorized by Warden Brian)

Numbering note: this round uses Sol's ORIGINAL numbering. The round-1
section above labels its service-override and validation-units items R6/R7;
those are original R8/R10. Original R2/R6/R7/R9 were the open items.

- R2 FIXED (P1): `init_runtime()` now acquires the lifecycle lock (bounded;
  `PALWARDEN_INIT_ACQUIRE_TIMEOUT_S`, default 5s), calls
  `escalate_abandoned()`, rereads UNDER ownership, rotates only when idle
  there, and releases in a finally. A busy lock past the deadline SKIPS the
  rotation with a warning — a concurrent active/unsafe marker can never be
  overwritten. Tests: `test_lifecycle_lock.sh` 13a (competitor excluded
  during init's read-modify-write window; the old code held nothing there),
  13b (busy-lock boot skip; holder generation survives), 10d re-pinned to
  the stricter contract (abandoned active -> sticky unsafe, never idle).
- R6 FIXED (P1): idle-watch `tick()` revalidates the full policy gate
  (config/timeout/uptime/eligibility) TWICE — before the best-effort
  event/notify work and again IMMEDIATELY at dispatch after that blocking
  work. Disable or raised timeout landing during event or notify aborts
  with zero stops. Tests: `test_idle_watch.sh` module tier (disable during
  event, disable during notify, raised timeout during notify).
- R7 FIXED (P2): jobd `run_job()` initializes the failure status
  (`exit_code = None` -> records unsafe) and releases the lifecycle lock in
  a nested finally; a `_mark_state` bookkeeping failure can no longer
  strand the lock, and an unexpected `_execute_job` raise no longer dies
  with UnboundLocalError before `lc.release()`. Test: `test_jobd.sh` R7
  (injected OSError -> exception propagates, marker unsafe, a separate
  competitor acquires the lock again).
- R9 FIXED (P2): `start_if_down()` posts exactly ONE bounded (200-char)
  wake failure notification on starter failure and on start-never-running;
  quiet no-ops (already-running/cooldown/refused) stay silent per §6.3.
  Tests: `test_lifecycle_lock.sh` 13c/13d/13e.
- R5: spec §4.4 amendment drafted (wake-path exception with rationale;
  labeled PROPOSED). The independent review gate could NOT be satisfied —
  the reviewer model route was unreachable all session (connection errors,
  including one fresh dispatch attempt). Recorded as a PENDING gate, not a
  passed review.
- Fresh results (umask 022): `test_lifecycle_lock.sh` 78/0;
  `test_idle_watch.sh` 86/0; `test_jobd.sh` 401/0;
  `test_notify_adapter.sh` 8/0. Full `./tests/run.sh`: ALL SUITES PASSED
  (2026-10-26; integration/live tiers skipped by design — see NOT verified).
- NOT verified (not a pass): Docker integration (`RUN_INTEGRATION=1
  ./tests/run.sh`), browser tier, live-game tier, root-only ack matrix.
  No commits, pushes, production operations, or real notifications were
  performed by this round.

## Docker integration first run (2026-10-26, authorized by Brian)

- `RUN_INTEGRATION=1 ./tests/run.sh`: unit tier ALL PASSED; integration
  tier FAILED (rc=1): `test_docker.sh` 133/1 ("C: expected ok telemetry
  rows from stub, got 0"); `test_idle_knock.sh` 41/4 (presence sampling
  never valid — REST stub connection-refused/empty responses inside the
  container -> no stop -> no wake; scenario 3 then reports
  "skip presence (invalid)" instead of "stale"). All other integration
  suites passed.
- Triage: failures sit in fixture/stub availability (rest-stub.py /
  fake-server), upstream of the four round-2 fixes; the stub diff is
  additive. Sticky-unsafe escalation warnings observed mid-run behaved
  per design. Reproducibility rerun of both suites: PENDING (result to be
  appended). Docker tier therefore NOT green.

## Docker root cause + fix (2026-10-26, second run)

- Rerun reproduced the SAME 5 failures: deterministic, not a flake.
- Live repro (scratch/stub-dbg.sh) disproved the stub-death hypothesis: the
  stub survived 80s of 2s sampling and answered curl, yet presence_state
  stayed (0, None). Real root cause: sbin/palworld-api printed the success
  status line "HTTP 200 OK" to STDOUT before the JSON body, while the F3
  strict whole-stdout parser (spec §5.1) demands the raw body only — every
  in-container sample died with "API output is not one JSON object", so
  presence never armed, no stop, no wake, and telemetry wrote 0 ok rows.
  A round-1 (F3) regression invisible to unit tests (fetch boundary is
  stubbed there); Docker tier had never been rerun — the ledger warned so.
- FIX: palworld-api success status line moved to stderr (stdout = raw body,
  the contract parse_api_json documents). All consumers verified: readiness
  uses exit codes only; no consumer greps stdout for the status line.
- RED->GREEN test: test_api_exit_codes.sh stdout-purity section (stdout
  equals the raw JSON body; json.load passes). Suite 20/0.
- Post-fix unit tier: full ./tests/run.sh ALL SUITES PASSED (umask 022,
  scratch/full-unit-after-apifix.log). Docker integration rerun: RUNNING
  in background (scratch/integration-rerun-apifix.log); result to be
  appended. Docker tier NOT green until that run passes.
- RESULT (2026-10-26): Docker integration GREEN — test_docker.sh 134/0
  (was 133/1), test_idle_knock.sh 45/0 (was 41/4). The mid-run
  escalate-to-unsafe warnings are the suite's deliberate killed-transaction
  scenario behaving per design. Docker tier VERIFIED for the idle/knock
  feature. Still NOT verified: browser tier (no automated suite; webui
  coverage lives in unit tier), live-game tier (needs real testbed),
  root-only ack matrix (needs root; sudo attempt was not approved).

## Independent review gate — partial (2026-10-26)

- Gemma scout review of the six round-2 hunks returned overall "approve",
  zero concerns — BUT the run hit its iteration cap and item 3 (jobd
  run_job) was explicitly NOT read by the reviewer (inferred from other
  patterns). Gate recorded as: items 1,2,4,5,6 reviewed-approve (truncated
  run caveat); item 3 re-dispatched as a narrow focused review, PENDING.
  A "done" review claim would be false until the jobd item returns.
- Live-game tier: RUNNING against the marked throwaway testbed
  (/home/hermes/palworld-testbed, marker + 4.7G install verified); log
  scratch/live-tier-20261026.log, result to be appended.

## Review gate CLOSED with one fix (2026-10-26)

- Focused gemma review of item 3 (jobd run_job): verdict CONFORMS with one
  minor concern — a BaseException (e.g. KeyboardInterrupt) from
  _mark_state's completion call escaped `except Exception` and skipped
  lc.release. Valid.
- FIX: completion bookkeeping now wrapped in an outer try/finally so the
  release is unconditional; additionally the START bookkeeping call
  (_mark_state active+rotate, between acquire and the try) got the same
  guard — a raise there previously leaked the descriptor while the daemon
  kept running (same leak class as R7).
- Regressions: test_jobd.sh R7 driver now runs three scenarios
  (execution OSError; start-bookkeeping RuntimeError; completion
  KeyboardInterrupt), each asserting a separate competitor can re-acquire
  the lock. Suite 402/0; full ./tests/run.sh ALL SUITES PASSED after the
  hardening (scratch/full-unit-after-r7hard.log).
- Gate status: all six round-2 hunks independently reviewed (items 1,2,4,
  5,6 approve in the first scout; item 3 approve-with-minor in the focused
  scout; concern fixed and regression-tested). Caveat recorded: reviewers
  were gemma scouts, not a fresh human session.

## Live tier first run + regression caught in the api fix (2026-10-26)

- `./tests/run.sh --live` against the marked testbed FAILED at readiness:
  "the live server did not become REST-ready" — while the container log
  showed the game REST-ready and sampling healthy (serverfps=59,
  /v1/api/info OK).
- Root cause: a REGRESSION IN MY OWN api fix. Four harness probes grepped
  'HTTP 200' from palworld-api STDOUT with stderr discarded — the status
  line now lives on stderr. My consumer scan covered sbin/lib/webui/
  tests/unit/docker but MISSED tests/live and one integration probe. The
  live tier caught exactly what it exists to catch.
- Fixed probes (grep the JSON body 'servername' instead):
  tests/live/lib/testbed.sh:217, tests/live/test_idle_knock.sh:281,
  tests/integration/test_update_apply.sh:57+77.
- Scope correction: the earlier "Docker green" covered only the two
  rerun suites (test_docker, test_idle_knock); test_update_apply passed
  pre-fix and would have broken post-fix. Full RUN_INTEGRATION=1 rerun
  RUNNING (scratch/integration-full-v2.log); live rerun to follow. Both
  tiers NOT green until complete.

## Root-only ack matrix VERIFIED (2026-10-26, sudo authorized by Brian)

- `sudo bash tests/unit/test_lifecycle_lock.sh` as root: 87 passed,
  0 failed, and the two "UNAVAILABLE: ... requires root" labels are GONE —
  the previously unobservable scenarios executed and passed:
  - ack REFUSES crash-backoff (s6 down without wanted-down marker): rc!=0,
    unsafe marker intact, generation NOT rotated;
  - ack SUCCEEDS on confirmed stopped+wanted-down: clears unsafe -> idle
    via the sanctioned force write, without ever invoking a systemctl
    binary (stub PATH has none);
  - the root-only acknowledge happy path (section 8).
- Non-root harness result unchanged: 78/0. Root tier for the ack matrix:
  VERIFIED.

## Full integration tier GREEN (2026-10-26)

- `RUN_INTEGRATION=1 ./tests/run.sh` after the four probe fixes: ALL
  SUITES PASSED, rc=0 (scratch/integration-full-v2.log) — unit + every
  Docker integration suite, including test_update_apply with the
  body-grep probe. Docker tier VERIFIED at full scope.
- Live-tier rerun with fixed probes: RUNNING
  (scratch/live-tier-v2.log); result to be appended.

## Live tier v2: readiness fixed; wake-vs-job lock contention found

- Readiness now passes (3 suites brought the stack up). rc=1 remains:
  - test_config_drift.sh 23/1: graceful_restart job FAILED.
  - test_idle_knock.sh 22/3: graceful_stop job FAILED; the two following
    scenario-5 failures are cascades of that refused stop.
- Job records (recovered from the palwarden-live_palwarden-state volume)
  show both refused identically: "the lifecycle lock is busy (lock held
  by pid=... comm=palworld-knock); gave up after 0s".
- Diagnosis: a wake transaction holds the lifecycle lock through the REAL
  REST-readiness wait (PALWARDEN_WAKE_READY_TIMEOUT_S default 180s; the
  real game needs ~1 min to load a world), while jobd refuses wrapped
  jobs when the lock is busy (timeout=0) — the reviewed R3 design. The
  live tests were written against the Docker fake server, which is
  REST-ready instantly, so the window never appeared before. NOT a
  round-2 regression; first surfacing in the live tier.
- Options (decision needed, Brian/Sol): (a) live tests wait for the wake
  transaction to complete (REST-ready => lock released) before enqueueing
  jobs — aligns tests with the reviewed refuse-when-busy design; (b) a
  spec-reviewed change so wrapped jobs wait a bounded time instead of
  refusing — changes reviewed behavior; (c) shorten the readiness wait
  inside the lock and report unverified — weakens §6.3 truthfulness.
  Recommendation: (a), plus document the post-wake busy window in the
  runbook.
- DECISION (Brian): option (a) approved. Implemented:
  - tests/live/test_idle_knock.sh scenario 5: bounded wait for the wake
    transaction to complete (REST-ready => lock released) before
    enqueueing the administrative stop, with a new assertion
    "5: the wake transaction completed (REST-ready) before the stop".
  - tests/live/test_config_drift.sh: bounded operator-style retry (6x,
    15s apart) of the graceful_restart enqueue, ONLY on a
    "lifecycle lock is busy" refusal; any other failure falls through
    to the assertion unchanged.
  - docs/palworld-service-runbook.md §17: documented the post-wake busy
    window (wake holds the lock through world load, bounded by
    PALWARDEN_WAKE_READY_TIMEOUT_S; refuse-when-busy is by design;
    wait for REST or retry).
  - Live-tier rerun with these fixes: PENDING (next turn).

## Live tier v3: option-(a) fixes validated; two NEW live findings

- Option (a) WORKED: config_drift's graceful_restart busy-retry passed
  (the old failing assertion is gone from the failure list; suite moved
  from 23/1 to 21/3 with deeper assertions now reachable).
  stop_consistency 22/0, restore_roundtrip 17/0.
- NEW FINDING A (config_drift, real product gap): after the game rewrote
  Engine.ini on restart, the drift check reports "Engine.ini check
  FAILED: no managed values" — the game writes ONLY non-default values,
  so managed values equal to game defaults are absent and the checker
  treats absence as failure instead of no-drift. Needs a design decision
  (treat absent-equals-default as no drift, or re-apply). NOT round-2
  scope; report to Brian/Sol.
- NEW FINDING B (idle_knock scenario 2, flaky?): config PUT hung —
  "curl: (28) ... 30002 ms with 0 bytes received"; suite aborted 3/1.
  Scenario 2 PASSED in v2; v3's only delta was the config_drift retry
  storm preceding it. Static review: webui is ThreadingHTTPServer; PUT
  handler path (validate_params -> create_job atomic write) takes no
  lock; jobd module import documented inert. Suspect host CPU contention
  (game world-load overlapping image rebuild), not a code path. Solo
  rerun of the suite RUNNING (scratch/live-idle-knock-solo.log) to test
  flaky-vs-real.

## Solo rerun: Finding B = flake; scenario-5 no-op assertion fixed

- Solo idle_knock run: 25 passed, 1 failed. Scenario 2 (config PUT)
  PASSED solo -> Finding B downgraded to host-contention flake, not a
  code path.
- The one remaining failure "5: no cooldown no-op line" was a TEST bug:
  scenario 5 sent a SINGLE udp_knock then slept 20s, but the lease gap
  (~0.15s/s) can drop a single datagram by design — scenario 4's own
  comment says ring like a real client. A dropped datagram means no
  no-op log line AND a vacuous "stayed down" pass. The cooldown refusal
  itself worked.
- Fixed: scenario 5 now rings knock (30x, 1s apart) until the daemon
  logs "wake was a no-op (cooldown)", THEN asserts stayed-down — so the
  down assertion is no longer vacuous. bash -n clean.
- Solo rerun #2 with the fix: RUNNING (scratch/live-idle-knock-solo2.log).

## Solo3 diagnostics: knock daemon crash-loop root cause

- Solo2 (ring fix) still 25/1 -> not a dropped datagram. Solo3 added a
  self-diagnostic dump: lifecycle state IDLE, cooldown stamp 18:43:39
  (ring ran well inside the 120s cooldown), stayed-down passed — but
  s6-svstat showed the KNOCK DAEMON RESTARTED at 18:43:55, seconds after
  the wake completed. Nothing in the stop path restarts knock; the
  daemon CRASHED and s6 restarted it silently. During the dead/restart
  window knocks were never handled -> no cooldown no-op line, server
  correctly stayed down.
- Root-cause class: _daemon_main's loop called _lease() with NO guard;
  any unexpected exception (escaping after _lease's finally released
  the lock) killed the listener invisibly — same class as R7. The exact
  raising line is still unidentified (container log dump hit binary
  content; grep needed -a).
- Fixes applied: (1) daemon loop now catches Exception around _lease,
  prints the traceback to stderr (s6 -> container log) and continues —
  no silent dead window; (2) test dump uses grep -a and greps Traceback.
  py_compile + bash -n clean. NOT yet re-validated live: solo4 rerun
  PENDING; the traceback in the next run will name the exact crash line.

## Solo4: ACTUAL root cause — test grep-pattern bug (crash theory DEAD)

- Solo4 still 25/1, but the improved dump showed the no-op line IS in
  the container log: "wake was a no-op (cooldown; repeats aggregated)".
  The test greps "wake was a no-op (cooldown)" — closing paren directly
  after "cooldown", which is NOT a substring since the F10 review added
  "; repeats aggregated" before the paren. The pattern NEVER matched,
  in any run (v2/v3 "cascades" and solo2/3/4 all same cause).
- The daemon never crashed: the dump shows it logging wake started and
  the cooldown no-op normally; the 138s s6 uptime was a benign restart
  (config-save path), not a crash. My crash diagnosis was WRONG and is
  retracted.
- Fixes: (1) test pattern relaxed to "wake was a no-op (cooldown"
  (prefix, no closing paren); (2) the daemon-loop Exception guard from
  the false lead is KEPT as hardening (real R7-class hazard: escaping
  exception invisible behind s6 auto-restart) with the comment
  corrected to drop the false observation; knock unit suite 133/0 with
  it. py_compile + bash -n clean.
- Solo5 verification: RUNNING (scratch/live-idle-knock-solo5.log).

## Solo5: idle_knock LIVE-GREEN (26 passed, 0 failed)

- Pattern fix confirmed against the real game: scenario 5 passes via
  the ring + corrected grep; all six scenarios green.
- Live tier scoreboard after this: idle_knock 26/0, stop_consistency
  22/0, restore_roundtrip 17/0; config_drift 21/3 — the 3 failures are
  Finding A ONLY (Engine.ini absent-equals-default drift semantics),
  awaiting Brian's ruling. Recommended disposition: treat a managed
  value ABSENT from Engine.ini as no-drift when the desired value
  equals the game default (the game writes only non-default values;
  absence IS the default), using the existing engine-config table's
  defaults; do NOT re-apply blindly (restart-churn risk). Full-tierrerun deliberately deferred until Finding A is ruled, since
  config_drift otherwise fails deterministically.

## Finding A ruling received — but live evidence contradicts its premise

- Brian ruled: absent keeps defaults => no drift (original intent).
  Implementation NOT started, because grounding first found the ruling
  was based on my framing of Finding A, which the deeper evidence
  partially contradicts:
  - The live test DELIBERATELY applied NON-DEFAULT values
    (NetServerMaxTickRate=50 vs default 30; ConnectionTimeout=90 vs
    default 60) — its header comments say so explicitly, precisely to
    avoid measuring default-truncation.
  - After the game's rewrite (v3 log line 616 + check output), the file
    held ZERO managed keys; the persisted testbed Engine.ini (post
    defaults-restore) contains only the [Core.System] template.
  - So the real game stripped NON-DEFAULT managed keys too. "absent ==
    default => no drift" cannot explain the v3 failure and would not
    make the live test pass (50 != 30 => still drift under that rule).
- Decision space handed to Brian:
  (a) Game-strips-everything model: engine values do not survive a real
      restart; graceful_restart should RE-APPLY engine.env after the
      game returns, drift check stays strict, live test asserts
      re-apply restores the file.
  (b) Keep Brian's rule as the checker semantic (absent==default -> no
      drift; absent!=default -> drift) AND change the live test to
      apply default-valued settings for the no-drift-after-rewrite
      assertion, with a separate assertion that non-default values
      either survive or are reported as drift (documenting the strip).
  (c) Investigate game behavior first with a targeted experiment
      (apply tick=50, start, poll Engine.ini WHILE RUNNING vs after
      shutdown) to learn whether the strip happens at startup or
      shutdown and whether the session even honored 50.
  Recommendation: (c) first (cheap, one testbed cycle), then (a) or
  (b) based on the answer. No code changed for Finding A yet.

## Finding A: mechanism fully measured; Brian's rule implemented (RED->GREEN)

- Four testbed experiments established: the game reads Engine.ini at startup,
  rewrites it at SHUTDOWN from its in-memory config, writing ONLY non-default
  values. Values applied while a session runs are clobbered by that session's
  next shutdown before ever being read — exactly what jobd's
  engine_save_apply_restart comment (jobd:1009-1014) documents; the LIVE TEST
  used the wrong sequence (engine_save -> engine_apply -> graceful_restart),
  which is what v3 measured as "no managed values". The product was right;
  the live test was wrong.
- Exp4: ConnectionTimeout=120 round-trips when the session reads it; 90 is
  stripped => the game's real ConnectionTimeout default is 90 (the live
  test's "default 60" comment was wrong). NetServerMaxTickRate default 30.
- Implemented Brian's rule in sbin/palworld-engine-config: Setting gains a
  `default` field, populated ONLY with verified defaults (tick=30,
  ConnectionTimeout=90, provenance comments); check_expected_values treats
  absence as no-drift iff want == verified default; unknown defaults stay
  drift (conservative). RED (4 failures) -> implemented; GREEN run recorded
  below.
- STILL PENDING: (1) format_check's "no managed values" empty-branch can
  still mask the per-key report when the file has zero managed keys — RED
  showed it naming nothing; needs the empty-branch to fall through to the
  detailed report; (2) live test_config_drift sequence fix (use
  engine_save_apply_restart / settings_save_apply_restart composites, fix
  default-60 comment); (3) full unit + live tier reruns.

## Live test_config_drift restructure: IN FLIGHT (1 of ~4 patches applied)

- Verified jobd wraps ONLY disruptive actions in the lifecycle transaction
  (jobd:1599-1604), so engine_apply/config_apply (non-disruptive) can run
  while the game is down without knock-lease contention.
- Patch 1 APPLIED: header comment now records the measured
  ConnectionTimeout default 90 and that applying 90 deliberately exercises
  Brian's absent-equals-default rule end-to-end (95 fallback round-trips).
- Remaining patches (exact plan):
  2. Insert gstop() helper (bounded 6x retry ONLY on 'lifecycle lock is
     busy', 15s apart, STOP_TIMEOUT=300) near ini_value/pick_alt.
  3. Before engine_apply: first gstop() (old session's shutdown rewrite
     happens while we hold the file still); engine_apply + config_apply
     then run while DOWN so nothing clobbers them; keep their file
     assertions and the baseline no-drift check.
  4. Replace the graceful_restart retry block + live_up with:
     live_exec s6-svc -u + bounded REST-ready poll (session B READS the
     applied files), then gstop() again (session B rewrites both files
     from memory: tick=50 survives, ConnectionTimeout=90 stripped as
     default, description survives), then ENGINE_SHA_AFTER reporting.
     Drift assertions stay as-is; they now run against a genuine
     game-rewrite from a session that honored the values. Game left
     down at the end (trap tears stack down; /api/engine + /api/config
     are webui endpoints and work with the game down).
- Then: full unit suite, then full live tier as the final gate.

## Live test_config_drift restructure COMPLETE; full unit suite GREEN

- All four patches applied: measured-default header comment; gstop()
  helper (6x retry only on lifecycle-busy); stop-before-apply (game down
  for engine_apply AND config_apply, so no running session can clobber);
  restart block replaced with s6 up + bounded REST-ready poll (session B
  READS the applied files) + gstop (session B's SIGINT-save rewrite is
  what the unchanged drift assertions then face; game left down, webui
  endpoints work regardless). bash -n clean.
- Full unit suite (umask 022): ALL SUITES PASSED
  (scratch/unit-full-v4.log).
- REMAINING: full live tier rerun (the final gate; config_drift now
  exercises Brian's absent-equals-default rule end-to-end: tick=50 must
  round-trip, ConnectionTimeout=90 must be stripped-as-default and still
  report no drift). Then commit authorization.

## LIVE TIER v4: ALL SUITES PASSED (final gate)

- `./tests/run.sh --live` (umask 022, scratch/live-tier-v4.log): rc=0,
  ALL SUITES PASSED. Live scoreboard: config_drift 26/0 (restructured
  sequence), idle_knock 26/0, restore_roundtrip 17/0,
  stop_consistency 22/0; full unit tier green in the same run.
- IMPORTANT MODEL CORRECTION (v4 log line 525): the game KEPT
  ConnectionTimeout=90 after session B (which had READ it). Accurate model:
  the shutdown rewrite round-trips keys the session read and drops keys it
  never read; a defaults-only session writes no managed keys. Exp3's "strip
  of 90" was never-read clobbering, NOT proof 90 is the default. My earlier
  "measured default 90" claim is retracted; comments in
  sbin/palworld-engine-config, tests/live/test_config_drift.sh and
  tests/unit/test_engine_drift.sh corrected. OPEN for Brian: confirm
  ConnectionTimeout default 90 from product knowledge or set it to None
  (absence stays drift for that key). tick=30 stays as Unreal's documented
  default.
- Verification ledger FINAL: unit ALL green (incl. new Finding A tests);
  Docker integration ALL green; root-ack matrix 87/0 as root; LIVE tier
  ALL green. Only remaining decision: commit authorization (+ the
  ConnectionTimeout-default confirmation above).

## Brian's final decisions (2026-10-27)

- ConnectionTimeout default: KEEP 90 in the engine-config table.
- Independent review of post-gate hunks: SOL takes it (fresh session).
- Commit: still pending, gated on Sol's review outcome.

## Review handoff for Sol (post-gate hunks, cumulative since gate closure)

Scope to review (all uncommitted; master @ b49b3cb; 67 paths):
1. sbin/palworld-api — stdout purity: status line moved to stderr.
   Evidence: Docker v1 failures + tests/unit/test_api_exit_codes.sh
   stdout-purity test; consumers re-scanned (4 probes fixed, see 2).
2. Harness probe fixes — grep JSON body 'servername' instead of
   'HTTP 200' from stdout: tests/live/lib/testbed.sh:217,
   tests/live/test_idle_knock.sh, tests/integration/
   test_update_apply.sh (2 sites).
3. sbin/palworld-knock — daemon loop Exception guard around _lease
   (traceback to stderr, continue); comment records it as R7-class
   hardening from a false lead. Knock unit suite 133/0.
4. sbin/palworld-engine-config — Finding A: Setting.default field
   (tick=30 documented, ConnectionTimeout=90 ASSUMED per Brian),
   absent==default -> no drift, unknown -> drift; format_check empty
   branch now falls through to per-key report. Provenance comments
   corrected after v4 (game round-trips read keys, drops unread ones).
5. tests/unit/test_engine_drift.sh — new Finding A section (RED->GREEN,
   suite 150/0).
6. tests/live/test_config_drift.sh — sequence restructure
   (stop-before-apply; session-that-reads rewrite; gstop retry helper;
   measured-default comment corrections). Live 26/0.
7. tests/live/test_idle_knock.sh — scenario-5 ring-until-logged +
   corrected grep prefix "wake was a no-op (cooldown"; diagnostic dump
   kept. Live 26/0.
8. docs/palworld-service-runbook.md §17 — post-wake busy window.
Verification already on record: unit ALL green; Docker integration ALL
green; root-ack 87/0; live tier ALL suites green (v4 logs in profile
scratch dir). Open for Sol: any objection to the assumed-90 default
(Brian keep), or to the daemon-loop guard's continue-on-exception
policy.

## Sol final-review repairs (2026-10-27) — implementation and verification

Brian authorized Sol to implement the five remaining findings and retain code64
as the independent final-review gate. No commit/push or production operation is
authorized. Companion correction spec and implementation plan:

- `../specs/2026-10-27-idle-final-review-repairs.md`
- `2026-10-27-idle-final-review-repairs.md`

Both received independent isolated review against actual source, with no required
amendments; these approvals are NOT the final code64 implementation review.

### Findings and repairs

- S1 / P1: atomic publication failure can preserve an old readable idle marker.
  Added shared mandatory `begin_transaction` used by bridge, jobd, restore and
  watcher. Failed initialization/publication/escalation refuses mutation; an
  existing unsafe marker permits recovery without clearance. Refused begin
  never records completion. Jobd and restore release ownership through begin,
  handoff, cleanup and completion exceptions, including BaseException.
- S2 / P1: last idle policy gate now follows transaction publication, including
  running-state/uptime/evidence checks. Disable/raised timeout during publication
  cancels before stop and closes only the current transaction safely.
- S3 / P2: direct `--check` parses before enrollment (original argv preserved);
  queued `update_check` is not wrapped as maintenance. Informational exit 10
  and failed checks leave lifecycle state/generation unchanged.
- S4 / P2: shim game wanted-down helpers run only for the mapped game service;
  unrelated start/stop/restart preserve the game marker.
- S5 / P2: unconfigured readiness requires a fresh running-service confirmation
  before unverified success; exited/unknown service returns one truthful failure.

### Fresh evidence (repair session)

- New `test_final_review_repairs.sh` / `fixtures/idle-review-repairs.py`:
  initial RED: 10 tests, 21 failing assertions/subtests spanning all five issues;
  GREEN: expanded 14 tests, zero failures. Real flock/state/SQLite retained;
  service/notify/archive-preflight boundaries explicitly synthetic. Additional
  guards cover missing-state initialization, sticky unsafe cancellation and
  KeyboardInterrupt during jobd handoff / restore cleanup / completion.
- Focused lifecycle_lock, jobd, enrollment, graceful_restart, memory_watch,
  notify_optional, systemctl_shim and update_check suites: rc=0 after fixing
  their private state-directory isolation and moving R7 start injection to the
  new mandatory begin helper. Removed idle-watch test's unused `/tmp/unused`
  open so tests honor the approved scratch boundary.
- Initial full host unit run: FAILED. In addition to the now-fixed fixture
  assumptions, restore suites reject the EXISTING mode-0775 ancestor
  `/home/hermes/.hermes/cache`; changing umask does not fix an existing ancestor.
  No host chmod or weakened restore guard was used. Running both restore suites
  as the same numeric uid/gid in an isolated container, repository mounted
  read-only and scratch mapped to `/scratch`, passed: restore_apply 245/0,
  restore_enrollment 14/0 (environment-specific assertion counts).
- Lint run: Python syntax PASS; ShellCheck FAILED on existing feature-test
  SC2015/SC2016 idioms and unused live-test RESTART_TIMEOUT. These are not
  counted as a lint pass. No unrelated lint edits made.
- Final full isolated unit run: PASS, all 38 suite files executed, zero suite
  failures, `./tests/run.sh` rc=0. Clean Debian trixie runner with Python 3.13,
  `ss`, Node/jsdom, same numeric uid/gid plus the adm secondary group; repository
  read-only, approved scratch bind at `/scratch`, network disabled except the
  container's own loopback. Restore_apply 252/0, restore_enrollment 14/0,
  lifecycle_lock 78/0, jobd 402/0, idle_watch 86/0, knock 133/0. Served-page
  jsdom tier executed (not a real-browser-engine pass). Root-only assertions
  and foreign-group chown are explicitly unavailable in this non-root run.
- Runner setup attempts are NOT passes: a product-image full-unit attempt had
  installed `/command` helpers overriding fixture stubs and existing-image
  filesystem assumptions; an initial clean bookworm runner lacked supported
  tar-filtering Python and `ss`. The final clean trixie runner resolved these
  environment requirements without weakening production checks. Host-wide
  `./tests/run.sh` still needs a safe scratch ancestry; it is not claimed green.
- Full Docker integration: PASS, all four `tests/integration/test_*.sh` files
  executed sequentially directly (not via the host-unit-blocked combined runner):
  test_docker 134/0, test_idle_knock 45/0, test_persistence 32/0,
  test_update_apply 12/0; aggregate rc=0. Read-back with `docker ps -a` confirmed
  no containers remain. Unused Compose networks exist; no broad prune was run.
- Fresh root-only acknowledgement/lifecycle suite: PASS 87/0, rc=0 in a separate
  disposable test container as actual uid 0. No UNAVAILABLE root labels. This
  does not require root service operations on the host.
- Focused ShellCheck for update/shim and repair-related shell harnesses: PASS.
  Python compile checks and `git diff --check HEAD`: PASS. Full repository lint
  remains FAILED on the existing unrelated feature-test findings noted above.
- Actual code64 profile independent source review: APPROVE, no concrete defect
  requiring changes in the repair delta. Session
  `local-d18853860c341751d81cb1fc1aa759007d4918484040c0bb29b42b6229003490`.
  It inspected the six production repair deltas against saved pre-repair copies,
  shared helper/callers, new 14-test regression fixture, R7 injection change and
  scratch-only idle test adjustment. It did NOT execute tests, audit all other
  feature paths, or independently verify test logs; execution evidence above is
  Sol's. Nonblocking notes: the pre-existing untracked `FAILED` artifact remains
  untouched; old Bash versions before 4.4 are not validated; deeper per-controller
  failed-escalation cases could supplement the shared-helper/bridge coverage;
  unrelated shim operations retain game-lifecycle serialization by design.
- Real-browser and additional live-game cycles have NOT been run by this repair
  session. Historical results above remain historical. ConnectionTimeout default
  90 remains Brian-approved. All five findings are repaired and independently
  reviewed; commit/push remain unauthorized, and full lint is not green.

Ephemeral logs: `/home/hermes/.hermes/cache/scratch/idle-final-*`; pre-repair
source copies: `idle-final-repair-baseline/` under that scratch directory.

## Lint follow-up COMPLETE (2026-10-27, user directed “continue”)

Supersedes the remaining full-lint caveat in the preceding repair record:

- Reproduced the repository-wide lint failure before editing.
- Test-only cleanup in test_idle_watch, test_webui_panel, test_knock:
  explicit if/else assertions replace `condition && pass || fail`; all original
  checks/messages/bounds retained. test_notify_adapter's literal shell-injection
  fixture gets a documented, statement-scoped SC2016 exception. The unused
  RESTART_TIMEOUT and obsolete comment are removed from test_config_drift;
  active stop/start/update timeout bounds are unchanged.
- Fresh `./tests/lint.sh`: PASS (ShellCheck + Python syntax), rc=0.
- Fresh full unit run in the clean trixie runner: all 38 suites PASS, rc=0;
  jsdom tier executed, non-root-only assertion limits remain explicit.
- `git diff --check HEAD` and `bash -n tests/live/test_config_drift.sh`: PASS.
- No production code changed after code64's approval. Docker integration,
  actual-root acknowledgement and live-game tests were not rerun for this
  assertion/comment/dead-variable cleanup; previous evidence retains its scope.
- Logs: scratch `idle-lint-cleanup-lint.log`, `idle-lint-cleanup-unit.log`.
  No staging, commits, pushes or production restarts performed.

## Branch/PR preparation authorized (2026-10-27)

Brian explicitly authorized branching, committing and submitting a PR. The feature
is committed on `feature/idle-shutdown-knock-wake` as `d8fa81f`; the unrelated
pre-existing `FAILED` artifact is excluded and left untouched. The staged
whitespace check caught one trailing space in the formerly untracked integration
script; it was removed before the feature commit.

Fetching revealed `origin/master` had advanced by the player-stats-board PR.
That upstream history is integrated without rewriting either history; the sole
content conflict was docs/tools.md's read-endpoint list, resolved with both
features retained and the config GET token-redaction wording clarified.

Fresh combined-tree evidence:
- Repository-wide lint PASS; full isolated trixie unit run PASS, all 39 suites
  including upstream player-stats coverage and the jsdom tier.
- Actual-root lifecycle/acknowledgement suite PASS 87/0 in a disposable container.
- Initial combined Docker integration: general 134/0, persistence 32/0,
  update/apply 12/0; idle/knock 44/1 because the assertion required the queued-job
  diagnostic even when maintenance had already started and correctly returned
  HTTP 409 for active lifecycle state. No wake was admitted.
- Corrected only that assertion/comment to accept the two specific maintenance
  blockers (queued disruptive work OR active lifecycle), never an arbitrary 409.
  Fresh unit/lint runs passed afterward; idle/knock rerun PASS 45/0. Thus all four
  Docker suites have passing combined-tree evidence; not a claim that the initial
  combined integration invocation passed.
- No additional real-game/real-browser run or production operation. Code64's
  prior approval covers the production repairs, not a new full audit of upstream
  player-stats changes or this subsequent test-assertion/merge-doc adjustment.

Scratch logs: `palwarden-pr-final-lint.log`, `palwarden-pr-final-unit.log`,
`palwarden-pr-merged-root-ack.log`, `palwarden-pr-merged-integration.log`,
`palwarden-pr-final-idle-knock.log`. PR publication/CI status belongs to the PR;
this entry records the verified local preparation, not a remote-success claim.
