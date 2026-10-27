# Idle/Knock Final Review Repairs — Safety Contract

Date: 2026-10-27
Status: APPROVED for plan derivation — independent isolated review
Scope: five findings from the fresh Sol review of the uncommitted feature.
Companions: `2026-10-18-idle-shutdown-knock-wake.md` and
`../plans/2026-10-24-idle-shutdown-knock-wake-review-follow-ups.md`.

## Required outcomes

### S1 — Publication is a prerequisite, not best-effort admission

Every owning maintenance controller (acquire/re-exec bridge, jobd, restore,
idle watcher) must establish a persistent wake-inhibiting marker under lifecycle
ownership BEFORE mutating the service or world. A shared begin-transaction
operation initializes missing state under ownership, escalates abandoned active
state to sticky unsafe, and publishes active with a fresh generation from idle.
An existing readable unsafe marker permits deliberate maintenance/recovery without
clearing that marker. An abandoned active marker must be successfully escalated
before proceeding; failed escalation must not be overwritten by a new transaction.
Unreadable/invalid state or failure to initialize, escalate, or publish refuses
mutation and releases only owned resources. Old readable idle state is NOT proof
that a failed write is safe. This intentionally supersedes the earlier repair
plan's warning-only behavior, even with idle shutdown disabled.

Completion is best-effort only AFTER successful begin: active/unsafe then remains
wake-inhibiting if completion cannot be recorded. A refusal before begin must not
run generic failure completion and invent unsafe maintenance where nothing ran.
Borrowers keep outer ownership/state and do not independently begin or complete.
No new backup/lifecycle acquisition order is introduced. No rollback/reset of
world data, no automatic acknowledgement, and no production restart is authorized.

### S2 — Last idle policy gate follows persistent transaction publication

After successful begin, the watcher revalidates config, timeout, running state,
uptime and presence eligibility immediately before dispatch. Disable/increased
timeout landing during publication must prevent a not-yet-dispatched stop.
Cancellation closes the newly begun transaction safely without clearing an older
unsafe marker. The remaining non-atomic join/config-versus-dispatch race is not
claimed solved. No new blocking notification/event work follows this last gate.

### S3 — Check-only update outcomes do not represent maintenance

Direct `palworld-update --check` and queued `update_check` do not begin/complete
maintenance, rotate its generation, or change safe/unsafe state. Documented exit
10 remains the informational update-available outcome; check failure likewise
must not claim interrupted maintenance. Parse options before enrolling mutating
updates; preserve borrowed descriptor behavior for actual nested updates. Keep
HTTP/job confirmation policy and job exit-code semantics unchanged unless needed
by an existing contract. A check may fetch Steam metadata but never stop/start or
modify game/world files.

### S4 — Shim markers belong to the requested game service

Only start/stop/restart targeting `palworld-server` (including existing aliases)
may change that game's wanted-down marker. Unrelated-service operations retain
their existing s6 mapping and must not alter game marker/state. Existing cooperative
locking remains; avoid broad shim redesign.

### S5 — Unverified wake success requires a still-running service

When readiness returns unverified, reconfirm running state before returning
started or posting success. If the game has exited or state is unknown, return
error and one truthful failure notification, not a successful unverified result.
Retain cooldown, generation fencing and bounded optional notification behavior.

## Acceptance and verification

- Regression tests fail first for all five findings; fixtures use real flock,
  state/SQLite where relevant, synthetic final service/notification boundaries.
- S1 covers direct bridge, jobd, restore and watcher with a pre-existing idle
  marker and publication failure: no mutation, no leaked lock; abandoned active
  escalation failure is refused; existing unsafe remains sticky and usable for
  deliberate maintenance; interrupted successful begin remains wake-inhibiting.
- S2 covers disable and increased timeout during publication, zero stops, safe
  cancellation completion, and existing unsafe preservation.
- S3 tests direct and queued exit 10 and failing checks with idle/unsafe markers;
  neither state nor generation changes and no service calls occur.
- S4 tests unrelated start/stop/restart against running and stopped game markers.
- S5 tests service death/unknown during unconfigured readiness plus live success.
- Focused suites, full `./tests/run.sh`, lint and full Docker integration where
  available. Root/browser/live tiers are separate; skipped is never a pass.
- Preserve all unrelated dirty-tree work; do not stage, commit or push.
- Independent spec review precedes plan derivation; independent plan review
  precedes implementation. Combined repairs require independent final review.
  The requested code64 final handoff is not satisfied by an author self-review.

## Review record

Independent isolated reviewer approved against the actual repository, with no
required amendments. Plan cautions: preserve update's original argv across
parse/re-exec; distinguish successful begin from ownership; do not mistake the
best-effort `escalate_abandoned()` return for proof of successful escalation.
This is spec approval, not implementation approval or the code64 final gate.
