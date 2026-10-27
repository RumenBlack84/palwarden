# Idle Shutdown & Knock-Wake — Design Spec

Date: 2026-10-18
Status: revised design; not implemented or runtime-verified
Scope: embedded Docker mode only for v1. Shared scripts retain host-portable
interfaces; systemd deployment and external-mode support are follow-ups.

This revision supersedes the initial draft's presence, wake, persistence, and
configuration contracts. The companion implementation plan is
`docs/superpowers/plans/2026-10-18-idle-shutdown-knock-wake.md`.

## 1. Background

Stop an unused Palworld server to save CPU/RAM, then start it when a player
attempts to connect or an authorized operator requests a wake. The first UDP
connection attempt is consumed; the player must retry after startup. The game
continues to enforce its own password. A datagram is not authentication.

## 2. Goals and non-goals

- Idle shutdown is disabled by default (`IDLE_TIMEOUT=0`). Knock-wake defaults
  on in embedded mode, preserving the initial draft's open-doorbell choice.
- Use Python 3 stdlib, existing bash/flock/s6 tools, the existing REST client,
  notification helper, sampler, and privilege-separated web/job control plane.
- Fail closed: unknown player presence, service state, uptime, or lifecycle
  ownership never authorizes an automatic stop or wake.
- All five operator settings are editable through an actual browser panel and
  take effect without restarting the container.
- Serialize supported lifecycle operations and explicitly hand off the UDP port.
- Persist browser settings across container recreation and image replacement.
- No protocol proxy, packet forwarding, Discord bot, external server control,
  custom internal game-port support, or bare-metal units in v1.
- No change to direct s6 supervision or SIGINT down-signal of the game binary.
- No promise of instantaneous connection or detection of every join between
  samples. Open-doorbell scans can wake the server; cooldown bounds frequency,
  not total unwanted uptime. Recommend token/API mode if that defeats savings.

## 3. Existing behavior and corrections to the initial draft

These are observations of the current repository, not guarantees of new code:

- Container graceful-stop accepts `--message`, but its notifications do not use
  it (`sbin/palworld-graceful-stop:21-28`). A dedicated reason post is required;
  do not claim the reason is emitted twice.
- Container graceful-restart always issues down then up, even if another caller
  just started the server (`sbin/palworld-graceful-restart:79-81`). It is not an
  idempotent wake primitive.
- Config applies require `--apply-config` / `--apply-engine`. Plain restart
  does not apply pending configuration. Wake must not silently apply it either.
- Container restart's REST timeout currently warns and may return zero
  (`sbin/palworld-graceful-restart:93-98`). New wake results must be truthful
  rather than inherit that success assumption.
- Presence failures are independent of `/info` and metrics success
  (`sbin/palworld-fps:287-308`). Identity history is not observation freshness.
- Presence grace stitches playtime sessions; it does not extend last-seen
  timestamps after disconnect (`sbin/palworld-fps:166-237`).
- `/etc/palworld` is not a persistent container volume. The backup schedule
  explicitly moved off it (`docker/entrypoint.sh:101-110`).
- Job parameters are stored and returned by job APIs
  (`lib/palwarden_jobs.py:180-195`, `sbin/palwarden-webui:1430-1443`). Config
  GET redaction alone cannot protect a newly queued token.
- `docker/palwarden-render-config` emits `PALWORLD_CFG_*` keys; it does not
  establish a universal `SERVER_PORT`. `PublicPort` and a published host port
  must not be assumed to identify the game's actual bound socket.

Line references will drift. Trace symbols again before editing; old line
numbers and this design are not proof of runtime behavior.

## 4. Safety model: lifecycle ownership and port handoff

### 4.1 One cooperative lock

Introduce a root-owned lifecycle lock, `/run/palworld-lifecycle.lock`
(test override `PALWARDEN_LIFECYCLE_LOCK`). Every supported server controller
acquires it before changing service state and holds it across its entire
transaction, including stopped maintenance windows and readiness checks:

- graceful stop/restart, including config apply between stop/start;
- update, including failure recovery;
- restore/import paths that stop or start the game;
- idle stop, knock/API/local wake, and mutating container-shim commands.

Use an inherited, validated lock descriptor for nested calls. Reopening and
locking the same file in a child can deadlock; a bare environment boolean is
not proof of ownership. Shell and Python users share the inode and flock
protocol. Distinguish owning from borrowed contexts: a borrowed nested context
must NEVER issue LOCK_UN on the shared open file description. It may close
its own duplicate; the outer owner alone ends ownership. Test that competitors
remain excluded after a nested call returns, until the outer transaction ends.

Existing per-job/update/backup locks remain. Acquire outer job/backup/update
locks before the lifecycle lock; never acquire them in reverse inside a
lifecycle transaction. Knock must not acquire a job queue lock. Read-only
service queries do not take the lifecycle lock. Propagate ownership through
subprocesses explicitly and close descriptors on unrelated subprocesses.

Raw `s6-svc`, external signals, container termination, and bare-metal root
commands bypass this cooperative protocol. Document that limit; do not claim
protection against arbitrary out-of-band root actions.

### 4.2 Bounded socket lease

The knock daemon uses nonblocking acquisition of the same lifecycle lock.
Under it, verify the service is actually down AND intended to remain down
(s6 actual state and wanted state). Crash/restart backoff, unknown supervisor
state, startup, shutdown, or maintenance must not arm the listener.

Only then bind UDP 8211. Each listening lease is at most one second. Close the
socket BEFORE releasing the lock, then wait at least 100 ms before reacquiring.
This reduces contention but is not FIFO fairness: explicit controllers use a
bounded acquisition deadline and fail visibly rather than wait forever. Test
controller acquisition within five seconds under sustained fixture traffic;
do not claim an OS scheduling guarantee. Recheck config/state at every lease.
Invalid packets cannot extend the lease or bypass its monotonic deadline.

A valid packet transitions to wake under the already-held lock: close socket,
recheck eligibility/config, record cooldown, issue start, and check readiness.
A supported manual start cannot reach the game while the daemon owns its
socket. Five-second state polling alone is not a handoff protocol.

### 4.3 Idempotent start, not restart

One `start_if_down` operation is shared by UDP, local CLI, and job API wake.
It acquires/reuses lifecycle ownership and rechecks state and cooldown. Only a
confirmed stopped service starts. Already up/starting is a no-op; unknown state
or busy maintenance is a refusal/defer, never a restart. It never sends down
and never implicitly applies pending config. Requests do not queue themselves
for a delayed wake after maintenance; callers can retry deliberately.

`palworld-knock wake` invokes this directly, rather than sending an unchecked
loopback packet. Add fixed-argv job action `server_wake`, with an optional
validated reason, rather than using `graceful_restart` for bots. Authorized
explicit wake is permitted when UDP knock is disabled; cooldown still applies.

### 4.4 Fence queued API requests against maintenance

Jobd is serial, so execution-time lock acquisition alone cannot detect that a
wake was submitted during an earlier queued update/restore. Publish root-owned,
atomically written `/var/lib/palwarden-ops/lifecycle/state.json` in a
root-owned 0755 directory, readable but not writable by the web account.
(Amended 2026-10-21 per F1 decision C: the lock stays on `/run` as specified
in §4.1 — mutual exclusion gains nothing from persistence — while the state
file moved from `/run/palwarden-lifecycle/` to the persistent `palwarden-ops`
volume, so an unsafe/active maintenance marker survives in-container
restarts; it is still wiped on volume recreation. The directory is
pre-created root-owned by `install.sh` and the image.) It contains a random
generation, active/idle status, and operation class; no secrets. Initialize it
before serving requests. Each outer lifecycle transaction rotates generation
and marks active BEFORE any service mutation; nested borrowers and socket
leases never rotate it. Normal completion records idle, including handled
failures only when service/data state is known safe. An interrupted/unsafe
maintenance marker inhibits automatic wake until explicit operator recovery;
do not clear it merely because flock became available.

Amended by the independently reviewed
[`2026-10-27-idle-final-review-repairs.md`](2026-10-27-idle-final-review-repairs.md):
transaction publication is mandatory, not best-effort. A failed atomic write
can preserve an old readable idle marker, so owners refuse mutation if begin
cannot publish active or successfully escalate abandoned active to unsafe.
Existing unsafe permits deliberate maintenance without clearing that marker.
Refused begin does not record completion; borrowers never begin/complete the
outer owner's transaction. Check-only updates do not constitute maintenance.

At API admission reject unknown/active status and queued/running disruptive
jobs with 409. Bind each accepted wake to the idle generation plus a 15-second
expiry, minted by the server rather than caller-supplied. Under ownership at
execution, compare generation/idle status and expiry BEFORE beginning its own
transaction. Changed generation, expiry, or active/unknown state rejects the
request without starting. A queued wake cannot survive an intervening lifecycle
transaction or a fresh runtime generation. Lock/status disagreement is unknown.
Test both serial jobd maintenance and direct maintenance between enqueue and
execution. This is a freshness fence, not an authorization credential.
Provide a root-only `acknowledge-maintenance --confirm` command in the lifecycle
module, never in the HTTP/job allowlist. After the operator inspects/reconciles
failed maintenance and world data, it acquires ownership, requires confirmed
stopped/wanted-down state, rotates generation, and clears the unsafe marker.
It does not start the game or assert that a world is valid. Container termination
remains outside this runtime fence; do not claim it is a durable restore journal.

(Amended 2026-10-26, Sol round 2 R5 — PROPOSED, pending independent review;
implementation already follows this reading.) The wake path
(`start_if_down`) is an explicit exception to the pre-mutation publish rule
above: it is not a maintenance transaction. It never marks `active`; under
ownership it refuses every non-idle status before touching the service, and
rotates the generation only AFTER a confirmed start, leaving the marker
`idle`. Rationale: marking active before the start would convert the §4.3
idempotent-start contract (already up/starting is a no-op observed under the
same idle marker) into a self-refusal, and an active-during-start marker
would fence sibling wakes only for the start's duration instead of
permanently. Safety properties preserved: no wake can start the game over
an active/unsafe marker (refused blind), and no wake admitted before an
outer lifecycle transaction or a confirmed wake survives it, because every
outer transaction AND every confirmed wake rotates the generation. Tests:
`test_idle_watch.sh` R5a (idle stop publishes active+rotate before the
mutation), `test_lifecycle_lock.sh` 12d (confirmed wake rotates).

## 5. Idle eligibility: positive evidence of an empty server

### 5.1 Sampler observation state

Extend the existing sampler with singleton `presence_state`, separate from
identity/playtime rows:

- `last_success_ms`: last successful schema-valid players observation;
- `valid`: whether the most recent attempted presence pass succeeded;
- `empty_since_ms`: beginning of the current observed-empty interval, or NULL
  when occupied/unknown.

A valid empty response updates last-success and preserves empty-since only if
the previous observation was valid and no more than 60 seconds old. Otherwise
start an empty interval now. A nonempty list clears empty-since, INCLUDING
loading entries with placeholder IDs. Identity filtering must not classify
loading players as an empty server.

Failure/malformed responses invalidate state and clear empty-since when the DB
is writable. Missing/wrong-shaped `players`, invalid list entries, or ambiguous
payloads are errors, not `[]`. A DB failure cannot refresh evidence; freshness
expires naturally. Successful observation and identity/session updates commit
coherently. Preserve metrics/presence failure independence.

Final watcher checks are observations too. Occupied/loading/error results must
clear/invalidate the stored empty interval, not merely abort this tick. Reuse
one observation writer from sampler and watcher. Before each players request,
reserve an increasing observation sequence in a short DB transaction; apply
the result only if its sequence is newer than the last applied observation.
Store allocation/applied counters alongside the singleton. This fences an
older in-flight sampler response from overwriting a newer final-check result.
Do not hold a DB transaction during an HTTP request. Superseded results cannot
authorize a stop or retroactively extend playtime. Failure to reserve/apply
evidence inhibits idle stop.

Maximum observation gap is a fixed 60 seconds in v1. Slower sampling cannot
obtain idle eligibility; document this instead of weakening safety. Existing
DBs migrate additively and begin unknown. Do not use MAX(identity.last_seen_ms)
or an empty identity table to authorize a stop.

### 5.2 Stop decision

`palworld-idle-watch` is a Python stdlib one-shot, with `--loop` for s6. Python
allows reuse of config, lock, and observation helpers without sourcing data as
root shell code. Read eligibility with `mode=ro` and a short bounded busy timeout;
`PALWORLD_METRICS_DB` overrides its normal path for tests.

A tick is eligible only if:

1. IDLE_TIMEOUT > 0; service is running; uptime is parseable and at least the
   timeout. Use portable service name `palworld.service`.
2. DB state is valid; last-success is not future-dated and at most 60 seconds
   old; empty-since is coherent and covers at least the full timeout.

Acquire lifecycle ownership nonblocking (busy -> skip). Under it re-read
config, service uptime/state, and DB eligibility. Then make a final schema-valid
`palworld-api players` request: only an empty list authorizes stop. Failure,
loading entries, or any player aborts. This deliberate final request is an
exception to the original no-new-polling goal; reuse the existing API client.
Reserve/apply this result through the observation writer using a separate,
short-lived write connection. After applying, recheck eligibility: a superseded
result, failed write, or reset empty interval cannot authorize stop. A final
check that sees activity/unknown must force a NEW full observed-empty interval
before any later tick can stop, even if the periodic sampler missed that player.

Record an `idle` event and one dedicated Discord warning, then call
`palworld-graceful-stop --wait 0 --message ...` under inherited ownership.
Event/notification errors are best-effort and cannot prevent a safe action.
Confirm service down before reporting success. The reason must not promise
connection wake when knock is disabled or token-only.

Missing DB/table, empty history, stale observations, sampler failure, or unknown
uptime is UNKNOWN, not idle. A fresh server needs a full period of healthy empty
observations AND sufficient uptime. Timestamp discontinuities/inconsistency
reset or inhibit eligibility. The uptime gate protects a new process from old
observations. There remains a narrow join-versus-stop race after the final REST
check; do not promise game-level atomicity. SIGINT delivery is not proof of a
durable save; real-game validation is required.

## 6. Knock, readiness, and notification behavior

### 6.1 Port and packet handling

V1 supports existing embedded internal listener UDP 8211. Host publishing may
use another `PALWORLD_GAME_PORT`, but the daemon binds the container port, not
PublicPort or the host mapping. Custom internal ports remain unsupported until
launch config, publishing, and discovery are managed together. Verify the
constraint against the real game; do not invent SERVER_PORT plumbing.

EADDRINUSE, unknown state, or lock contention causes bounded retry, not wake.
Use finite receive size, monotonic lease deadlines, and aggregated/rate-limited
logs. Do not log every invalid packet, token/payload, or publish source IPs to
Discord/event labels by default. Use aggregate wake reasons.
Token matching is exact UTF-8 byte comparison without decoding arbitrary
packets. Receive at least 513 bytes (maximum token length plus one), rejecting
oversized/truncated datagrams in token mode before comparison; token-plus-suffix
must never truncate into an accepted token. Invalid UTF-8 cannot match a
configured token. Open-doorbell mode accepts any nonempty datagram, even if its
payload exceeds the bounded buffer, because it does not compare payloads.

### 6.2 Cooldown and startup

Atomically store cooldown at `/var/lib/palwarden-ops/knock.cooldown`
(test override `PALWORLD_KNOCK_COOLDOWN_FILE`). Valid eligible wake writes it
BEFORE start. Missing means no previous wake; corrupt/future data fails closed
with an actionable bounded warning. Cooldown applies to UDP/local/API wake,
survives recreation, and does not replace service-state gating. An ordinary
administrative start is a deliberate override.

Use existing `palworld-api` and a 180-second readiness bound. Exit 2 means REST
unconfigured: report started but readiness NOT verified, only after confirming
service state. Other readiness/start failures return nonzero and warn/error;
never report REST healthy without a successful request. Keep lifecycle ownership
through completion and use bounded subprocess timeouts. Wakes execute
synchronously in the supervised daemon/job worker, not a detached restart.
A crash releases process-owned locks/socket; wanted-state gating and cooldown
protect startup after supervisor recovery.

### 6.3 Notification contract

- Idle: one reason warning plus the existing stop lifecycle posts.
- Wake: one UDP/API/local reason post, then truthful ready/unverified/failure.
- Already up, cooldown, or busy no-op: return status; no repeated Discord posts.
- Invalid traffic and config/state problems: bounded local logs.

Python calls the optional shell notify helper with fixed code and message/type
as arguments, never interpolated command text. Missing/failing helper is
nonfatal. Bash scripts retain tolerant source + no-op fallback. Test Python
behavior separately; the bash-only invariant does not prove it.

## 7. Configuration, persistence, and browser behavior

| Variable | Default | Validation |
|---|---|---|
| IDLE_TIMEOUT | 0 | integer minutes, 0..10080; zero disables idle stop |
| IDLE_CHECK_INTERVAL | 60 | integer seconds, 1..3600 |
| KNOCK_ENABLED | true | explicit boolean |
| KNOCK_COOLDOWN | 600 | integer seconds, 1..86400 |
| KNOCK_TOKEN | empty | UTF-8, <=512 bytes, no control characters |

Recommend IDLE_TIMEOUT >=30 minutes. The 60-second observation freshness bound
is independent of the idle-check interval. An empty UDP token is open-doorbell
mode. A token is not encryption or replay protection.

### 7.1 Shared resolver and persistent seed

Use one Python parser/validator/defaults/writer/redactor module. Resolution is
file -> environment -> built-in defaults. Missing or empty nonsecret environment
values select defaults; empty KNOCK_TOKEN is meaningful. Reject invalid present
files visibly and fail closed, never silently enable knock. The file is data:
fixed keys with JSON-quoted string values; no shell expansion/execution. Reject
unknown/duplicate keys and malformed values. Round-trip Unicode, quotes,
backslashes, and dollar signs. Do not source it as root.

Portable `PALWARDEN_OPS_FILE` default is `/etc/palworld/palwarden.env`.
Image and Compose override to `/var/lib/palwarden-ops/palwarden.env` on new
persistent volume `palwarden-ops`. Precreate `/var/lib/palwarden-ops` root-owned
0750 with service-account group access; config root-owned 0640 with that group,
cooldown root-only. Respect PALWORLD_USER/PALWORLD_GROUP where applicable.
No recursive runtime chown, and no trusted lock files in writable user trees.

At boot ALWAYS seed the complete validated file IF ABSENT, even with defaults
only. Existing files are never re-rendered. Changed Compose seeds do not
override saved values. Recreating with the same volume preserves browser edits.
Deleting the volume resets settings/cooldown and must be documented accordingly.

### 7.2 Live reload and UI

Always supervise both helpers in embedded mode. Each reloads valid config at
least once per second; enablement is not an entrypoint service gate. Disabled
knock closes by the next lease boundary; enabling re-arms when safe. Token and
cooldown edits affect the next request/lease. Idle timeout/check interval edits
reschedule relative to the last tick; an overdue tick runs promptly. Use
monotonic scheduling and revalidate before side effects. Config changes cannot
undo a start/stop whose side effect has already been issued.

Add an operations panel to `webui/palwarden.html`: all five settings, password
input with explicit replace/clear controls, help/defaults, retry/cooldown and
persistence explanation, errors, and asynchronous job completion.
GET `/api/palwarden-config` returns four nonsecret values plus
`token_configured`, never a token or magic redaction sentinel.
PUT queues `palwarden_config_save` using existing Basic/CSRF mutation checks
and returns a job handle. Merge only supplied keys with current effective
config AT EXECUTION TIME. Omitted token means keep; explicit empty means clear.
No literal `<redacted>` placeholder semantics. Revalidate in the root worker.

Expose `server_wake` through the existing job API using fixed argv and an
optional validated reason, never a command/path or graceful-restart.

### 7.3 Secrets across the job queue

Browser administrators already control privileged operations; redaction is
defense in depth, not a boundary against those users. A replacement token may
be stored in the existing private queued payload until processing because the
worker needs it. Enforce job files 0600 and queue directory 0700. Public
serialization must redact token fields in enqueue responses, job list/detail,
validation errors, and diagnostic output; internal worker reads stay intact.
Scrub tokens from completed/failed job parameters and orphan-reaping paths.
Never echo full config/token in errors/logs. Refuse symlink/nonregular targets
and keep atomic-write temporary files restrictive. Apply this narrowly without
changing the job API's other fields or starving existing worker operations.

## 8. Failure and recovery contracts

| Situation | Required outcome |
|---|---|
| Sampler stopped, info healthy | No idle stop; stale/unknown evidence logged |
| Players response fails/malformed | Empty continuity invalidated; no stop |
| Loading placeholder ID | Activity even without an identity row |
| Fresh DB/migration | Unknown until empty observations cover timeout |
| Update/restore/restart downtime | Lock prevents listener binding or wake |
| Crash, supervisor wants up | No bind; supervisor owns recovery |
| Supported manual start with socket bound | Start waits for bounded lease release |
| Concurrent wakes | At most one start, no down/restart |
| Invalid config/cooldown | Fail closed, bounded actionable logs |
| UDP flood | Lease deadline/log bounds hold; drops do not reset cooldown |
| Readiness failure | Nonzero, explicit warning, no false healthy report |
| Notify/event DB unavailable | Log; do not block safe lifecycle action |
| Container recreated | Settings/cooldown persist on dedicated volume |
| Raw root commands/container shutdown | Outside cooperative-lock guarantee |

## 9. Test and acceptance contract

New behavior requires RED/GREEN tests plus the existing suite. Missing tools or
skipped integration are not acceptance passes. Use real schema migrations and
isolated stubs, not invented API shapes.

- [x] Presence migration; empty/occupied/loading/malformed/failed observations;
  independent metrics failure; stale gaps and clock discontinuities.
  Evidence: tests/unit/test_player_presence.sh (unit suite green 2026-10-24).
- [x] Idle off, short/unknown uptime, missing/locked DB, stale sampler with info
  healthy, final-check player/error, and config edits while ownership is busy.
  Evidence: tests/unit/test_idle_watch.sh 63/0 (final unit run).
- [x] Real flock exclusion across shell/Python/nested calls, release on error,
  no deadlocks, outer exclusion after nested return, consistent ordering,
  protected maintenance windows, and interrupted-maintenance refusal.
  Evidence: tests/unit/test_lifecycle_lock.sh (real flock across shell/Python/nested).
- [x] Socket closes before concurrent manual start; crash wanted-state gating;
  repeated/concurrent UDP/API/local wakes never issue down/restart.
  Evidence: tests/unit/test_knock.sh 128/0 + integration test_idle_knock.sh scenarios 3-4.
- [x] Cooldown persistence/corruption; token mismatch, flood deadline/log bounds,
  disabled listener, and truthful readiness results.
  Evidence: tests/unit/test_knock.sh (cooldown corruption, token/flood bounds, readiness truth).
- [x] Defaults, seed-always-if-absent, validation, atomic permissions, merge-save,
  secret keep/replace/clear, and live reload of every setting.
  Evidence: tests/unit/test_palwarden_config.sh + integration test_idle_knock.sh scenario 5.
- [x] HTTP auth/CSRF; actual browser load/save/error/job completion; no token in
  enqueue/list/detail/error/output or completed/orphaned jobs.
  Evidence: tests/unit/test_webui_jobs.sh, test_webui_panel.sh, test_jobd.sh.
- [x] Final occupied/error observations reset continuity; out-of-order sampler
  responses cannot undo them. Queued wakes expire or reject changed lifecycle
  generations and never run after intervening maintenance. Oversized token
  suffixes cannot match, and traffic cannot starve controller progress in tests.
  Evidence: test_idle_watch/test_knock fencing cases + integration scenarios 4f-4g.
- [x] Separate Docker default boot and idle-enabled stop->UDP wake scenarios,
  with actual uptime AND healthy empty-observation eligibility.
  Evidence: tests/integration/test_idle_knock.sh scenarios 1-2 (default boot; idle stop -> UDP wake).
- [x] Docker maintenance/manual-start races and force-recreate preserving saved
  config/cooldown despite changed Compose seeds.
  Evidence: tests/integration/test_idle_knock.sh scenarios 4-5 + test_persistence.sh (force-recreate).
- [x] `./tests/run.sh` and `RUN_INTEGRATION=1 ./tests/run.sh` actually execute
  and pass required suites; optional-notify and licensing checks pass.
  Evidence: ./tests/run.sh ALL PASSED + RUN_INTEGRATION=1 ./tests/run.sh ALL PASSED + tests/lint.sh + SPDX audit, all 2026-10-24 (task12-*.log).
- [x] Disposable real-game verification of actual UDP binding/start, first
  knock/retry, and save-on-idle-stop. No production restarts without separate
  approval. Until exercised, label real-client behavior unverified.
  Evidence: tests/live/test_idle_knock.sh GREEN 25/0 on the marked disposable testbed (real UDP bind/handoff, first knock + cooldown-refused retry, save-on-idle-stop, restart onto the same saved world), 2026-10-24. Real-client join behavior beyond REST observation remains unverified.
- [x] Docs cover lifecycle boundaries, ports, persistence, browser/API operation,
  token caveats, remaining join race, troubleshooting, and rollback.
  Evidence: runbook §17, tools.md (knock/idle-watch entries, lifecycle-lock intro), architecture.md, docker/README.md — 2026-10-24.

## 10. Rollout and follow-ups

Keep idle disabled on upgrade. Establish observation freshness and browser
controls before enabling it. Preserve the ops volume on rollback; disable idle
and knock to restore the old automation policy without deleting saves. Lifecycle
changes need regression coverage even when the feature is off.

Follow-ups: systemd deployment, external mode, configurable internal ports,
protocol-aware/proxied wake, and a separate least-privilege Discord bot. A bot
using the current control plane has administrator-equivalent credentials.
Basic auth plus its CSRF token are not independent authentication factors.
