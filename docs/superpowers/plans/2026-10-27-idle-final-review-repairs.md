# Idle/Knock Final Review Repairs — Implementation Plan

Date: 2026-10-27
Spec: `../specs/2026-10-27-idle-final-review-repairs.md` (independently approved)
Status: IMPLEMENTED — regression/unit/Docker verification and code64 review complete;
full repository lint now passes after test-only cleanup, real-browser/live not rerun
Scope: S1–S5 only, preserving the existing dirty feature tree; no staging/commit.

## 1. RED — regression coverage before implementation

Add `tests/unit/test_final_review_repairs.sh` invoking a new Python fixture
runner in `tests/fixtures/idle-review-repairs.py` (stdlib, SPDX). It imports real
modules, uses TemporaryDirectory under TMPDIR, real flock and state files, real
SQLite presence evidence, and synthetic service/notify/backup boundaries. Catch
individual assertion failures so all five defects are exercised before failing.
Tests must pass current source for their fixture setup, not depend on a not-yet-
existing helper to reach the failing assertion.

- S1: real acquire/re-exec bridge fails state publication with existing idle
  state (state write injection in child interpreter; harmless controller log),
  refuses before controller invocation and releases lock. Repeat with active
  state/escalation failure; never overwrite active. Missing state initializes on
  successful begin; unsafe permits maintenance without generation/status changes.
- S1 jobd: import actual run_job with private jobs/parser paths, inject state
  publication failure and count execution calls; failed job, zero steps, idle
  unchanged, lock free. Inject interruption at begin for unconditional release.
- S1 restore: import actual restore_archive with isolated valid backup archive,
  saved tree/scratch and user ownership; stub safety backup/final service helpers;
  fail state publication; zero stops/swaps/starts, live tree unchanged, lock free,
  no spurious completion. Retain existing nested-restore tests.
- S1/S2 watcher: actual tick + real evidence/flock; active publication failure
  yields zero stops; disable/raise timeout DURING publication yields zero stops,
  idle completion; pre-existing unsafe survives canceled tick.
- S3: real update --check with fake SteamCMD, original arguments including
  --wait/--message, matching/mismatching/failing metadata and idle/unsafe state;
  state/generation unchanged; queued update_check with stub exit 10 and failure
  likewise unchanged. No real updater or service helper.
- S4: real shim with fake s6 binaries/service dirs; unrelated start/stop/restart
  leave game marker unchanged both absent and present; existing game operations
  still maintain marker. Fixture paths override lock/state/helper paths.
- S5: actual start_if_down with service/start/readiness/notify boundaries stubbed;
  readiness returns unverified after game dies/unknown -> error, one failure
  notice, no unverified success; still-running -> started/unverified.

## 2. GREEN — shared mandatory transaction begin

`lib/palwarden_lifecycle.py`: add exported `begin_transaction(operation=None)`.
PRECONDITION: fresh owned lifecycle lock. Call ensure_state under ownership;
if active, call write_state(unsafe) directly (not exception-swallowing
escalate_abandoned); unsafe returns without rewriting; only idle may publish
active+rotate; unknown/invalid refuses. Propagate all publication errors. Existing
completion writes stay sticky-safe and best-effort. `_cmd_acquire` calls helper,
closes owned fd and returns EX_DATAERR on begin failure BEFORE exec. Do not change
bare acquire (no command), socket leases, borrowers or wake transaction semantics.

`jobd`: remove update_check from DISRUPTIVE_OPERATIONS only (keep confirmation
and exit-code/job-result policy). Wrapped owners call begin_transaction instead
of best-effort active `_mark_state`. Begin refusal records failed job, executes
no steps, and releases in finally. A successful begin flag/structured lifetime
must ensure no completion on refused begin, and release on BaseException during
begin, ownership env preparation, execution or completion. Existing R7 tests move
start-injection from _mark_state to begin_transaction and completion injection
becomes completion-only. Completion _mark_state remains best-effort.

`restore`: local transaction-begun flag (separate from _lifecycle_owned), set only
after begin returns. Translate begin failure to ArchiveError before stop. Finally
completes only if begun, always releases owned fd; borrowers neither begin nor
complete/release. Preserve backup ordering, scratch cleanup and recovery reporting.

`idle-watch`: begin via same helper; publication failure returns named abort,
zero stop. Last _policy_gate moves after begin (and includes running-state check),
inside a transaction-completion finally. Track safe cancellation as idle; default
unsafe if stop raises/fails. Existing unsafe remains sticky. No event/notify work
after last gate. Remove unused /tmp/unused DB open from test_idle_watch fixture so
all verification honors scratch policy. Do not change production evidence schema.

## 3. GREEN — bounded remaining fixes

`palworld-update`: save original argv in array; parse/validate first, then enroll
ONLY if CHECK_ONLY==0 using original argv. No shell-token scan for --check (could
be a message argument). Move enrollment call, not helper loading. Thus re-exec
still receives all original flags. Check-only retains optional notify behavior.

`docker/shims/systemctl`: guard game wanted-down helper calls with is_server_svc;
keep s6 command and exit status authoritative, and existing lock behavior.

`start_if_down`: after _readiness returns unverified, require service_state ==
running before success; otherwise use existing _fail (one bounded notification)
and return error. Preserve healthy/readiness-failure/cooldown behavior.

## 4. Compatibility, documentation and verification

- Existing shell tests that mutate without specifying a lifecycle state directory
  must supply private writable state paths now that publication is mandatory.
  Fix fixture isolation rather than weaken production guards. Detect all paths
  by full suite; add no blanket production bypass.
- Update older authoritative spec §4.4 with mandatory publication and link new
  amendment. Runbook: failed publication aborts before mutation even feature-off;
  repair storage/permissions, do not erase markers; checks do not inhibit wake.
- Record actual RED/GREEN evidence and findings dispositions in follow-up ledger.
- Run new regression, relevant lifecycle/jobd/restore/enrollment/idle/knock/update/
  shim suites, then full `umask 022; ./tests/run.sh`, `./tests/lint.sh`, diff check.
- Inspect integration harness boundaries; run full Docker acceptance if Docker
  available, using existing disposable test containers only. No production or
  live-game operations; ask before any additional real-game cycle.
- Independently review combined repair delta and verify high-risk findings. Save
  code64 final-review handoff (do not modify another Hermes profile or pretend
  an isolated default-profile reviewer is code64). Commit remains unauthorized.

## Review record and execution evidence

Independent isolated reviewer approved against the approved spec and actual
repository with no required amendments. Explicit implementation check: restore
must release ownership even if scratch cleanup or completion raises. Spec and
plan approval are not final implementation approval or the code64 handoff gate.

Execution completed: initial RED reproduced all five findings; expanded regression
14/0; all 38 unit suites passed in the clean trixie test runner; all four Docker
integration suites passed; separate actual-root container lifecycle suite 87/0.
Actual code64-profile source review APPROVED the repair delta (did not execute
tests). Full repository lint remains red on pre-existing test warnings, while
focused repair ShellCheck, Python syntax and diff checks passed. Host restore
testing remains blocked by an existing writable scratch ancestor; no host chmod
or weakened guard was used. Detailed commands, environmental failed attempts,
tier limits and review session ID are recorded in the companion follow-up ledger.
No commits, pushes or production restarts were performed.

## Test-only lint follow-up (user directed “continue”)

The remaining lint warnings were reproduced, then addressed without production
changes: replace ambiguous assertion `&& pass || fail` chains with explicit
if/else branches; document/scope SC2016 only to the deliberately literal
metacharacter fixture; remove the unused live drift-test RESTART_TIMEOUT and its
obsolete comment. No assertions, thresholds or active timeout bounds were removed.

Fresh `./tests/lint.sh`: rc=0, ShellCheck and Python syntax PASS. Fresh complete
`./tests/run.sh` in the same clean trixie test runner: rc=0, all 38 suites PASS,
including the jsdom tier. `git diff --check HEAD` and the live harness's `bash -n`
also pass. Real-game cycles and Docker integration were not rerun for these
test-only edits; their preceding results remain recorded at their actual scope.
The code64 approval applies to the unchanged production repair delta, not this
subsequent test-only cleanup. No staging, commit, push or production action.
