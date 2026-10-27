# Idle Shutdown & Knock-Wake — Implementation Plan

Date: 2026-10-18
Status: Tasks 1, 2, 4, 5, 6 and 7 complete (7 on 2026-10-21); Task 3
implemented in the working tree (uncommitted, tests green); Tasks 8-12 not
started

**Goal:** Safely idle-stop an unused embedded server and start it on UDP or
explicit authorized wake, with persistent, live-editable browser settings.

**Architecture:** Fresh successful empty-player observations authorize idle
shutdown. All supported controllers share lifecycle ownership; the UDP listener
holds bounded socket leases under that ownership. Wake is start-if-down, never
restart. One shared config module serves workers, helpers, and HTTP handlers.

**Tech stack:** Python 3 stdlib, existing bash/flock/s6, SQLite, existing REST
client and optional notify helper, existing HTML/JS control plane.

Source of truth:
`docs/superpowers/specs/2026-10-18-idle-shutdown-knock-wake.md`.
If plan and spec disagree, resolve the discrepancy before implementation.
Do not interpret proposed files/APIs below as already existing.

## 1. Constraints and implementation discipline

- Embedded Docker feature only; no new systemd units or external-mode control.
  Existing lifecycle scripts must remain usable on bare metal. Shared libraries
  must ship in installed and development layouts; `install.sh` currently copies
  `lib/*`, but verify this and exercise its dry-run rather than assuming it.
- No production restarts, live migrations, commits, or pushes without explicit
  authorization. Do not change another Hermes profile or its checkpoints.
- Existing repo instructions, SPDX headers, service account overrides, secret
  handling, optional notifications, and test conventions remain binding.
- Every code task uses RED -> minimal implementation -> GREEN -> relevant
  regression tests -> `./tests/run.sh`. Record real commands/results; never
  check off a skipped or unexecuted acceptance item.
- Inspect definitions and callers before editing, including existing tests.
  Use the repo's actual APIs, not the old draft's stale line references.
- Do not use stale identity history as idle evidence, detached graceful-restart
  as wake, entrypoint-only config gates, or source the new ops file as shell.
- Defaults: idle 0, check interval 60 s, UDP knock true, cooldown 600 s, token
  empty. Seed complete config on every first boot IF ABSENT, including defaults.
- No automatic pending-config apply during wake. Explicit config-apply restart
  retains stop -> apply -> start ordering under the lifecycle lock.

## 2. File map

### New implementation files

| Path | Responsibility |
|---|---|
| `lib/palwarden_ops.py` | Five-key config schema, resolver, atomic writer, redaction, optional notification adapter |
| `lib/palwarden_lifecycle.py` | Shared flock/inheritance, service-state adapter, start-if-down/readiness and CLI bridge for shell callers |
| `lib/palwarden_presence.py` | Shared players validation and ordered observation transactions for sampler/final checks |
| `sbin/palworld-idle-watch` | Python one-shot tick and live-reloading `--loop` |
| `sbin/palworld-knock` | Python bounded UDP leases and direct local/API wake |
| `docker/s6-rc.d/idle-watch/{run,type,timeout-kill}` | Root supervised live-reloading idle loop |
| `docker/s6-rc.d/palworld-knock/{run,type,timeout-kill}` | Root supervised UDP helper |
| `tests/unit/test_palwarden_config.sh` | Config schema, merge, permissions, HTTP/queue secrets |
| `tests/unit/test_lifecycle_lock.sh` | Real shell/Python lock inheritance and controller races |
| `tests/unit/test_idle_watch.sh` | Safe idle decisions, final check, live scheduling |
| `tests/unit/test_knock.sh` | Socket leases, wake, cooldown, live reload, floods/readiness |

### Existing files to inspect and modify where required

- `sbin/palworld-fps`: observation schema, strict players validation, sampling.
- `sbin/palworld-graceful-stop`, `sbin/palworld-graceful-restart`,
  `sbin/palworld-update`, `sbin/palworld-restore`: lifecycle transaction scope.
- `docker/shims/systemctl`: coordinated mutating commands, not read-only queries.
- `sbin/palwarden-jobd`: two new fixed actions, execution-time config merge,
  final/orphan token scrubbing, any necessary descriptor propagation.
- `sbin/palwarden-webui`: GET/PUT config, auth/CSRF and public job serialization.
- `lib/palwarden_jobs.py`: private payload permissions and shared public
  redaction/scrubbing only where needed; preserve internal worker semantics.
- `webui/palwarden.html`: actual operations form, not just HTTP endpoints;
  reuse `webui/palwarden-ui.js` conventions without unrelated UI changes.
- `docker/Dockerfile`, `docker/entrypoint.sh`, `docker/compose.yaml`,
  `docker/.env.example`: installs, persistent ops volume, default seeding, s6.
- `tests/unit/test_player_presence.sh`: observation/migration regressions.
- Existing lifecycle, restore, update, webui/job and installer tests discovered
  during inspection: preserve existing behavior with new locking installed.
- `tests/integration/test_docker.sh`: isolated container acceptance scenarios.
- `docs/architecture.md`, `docs/tools.md`,
  `docs/palworld-service-runbook.md`, `docker/README.md`: operator guidance.
  There is no `docs/runbook.md`; do not create a parallel runbook by mistake.

## 3. Tasks in dependency order

### Task 1 — Shared configuration contract (spec §7.1)

**Files:** new `lib/palwarden_ops.py`, `tests/unit/test_palwarden_config.sh`.

1. Write failing tests for all defaults and file -> env -> built-in resolution.
   Missing/empty nonsecret env selects default; token empty is meaningful.
2. Pin integer ranges, strict booleans, token UTF-8 byte limit/control-character
   rejection, unknown/duplicate keys, invalid files, and literal shell syntax.
   Treat `$()` and backticks as data, never code.
3. Implement canonical fixed-key data format: `KEY=<JSON-quoted string>`.
   Use JSON escaping/decoding, not shell source/eval. Normalize API booleans and
   integers to canonical strings internally; emit typed public fields.
4. Test atomic writes, parent/target validation, restrictive temp files,
   symlink/FIFO refusal, file mode 0640, account-group handling, and unchanged
   original file on failure. Use isolated paths and conditional permission tests
   that clearly report unavailable root-only assertions.
5. Implement partial merge at execution time, including token omitted -> keep,
   empty -> clear, other valid text -> replace. GET exposes four nonsecret
   fields plus `token_configured`, not a placeholder token.

**Verify:** `bash tests/unit/test_palwarden_config.sh`; `./tests/run.sh`.
Expected: new cases pass; existing tests remain green. No actual credentials
are read or printed. Use unmistakably synthetic token fixtures only.

### Task 2 — Prove the cross-language lifecycle lock (spec §4.1)

**Files:** new `lib/palwarden_lifecycle.py`,
`tests/unit/test_lifecycle_lock.sh`.

1. Write real-process exclusion tests using isolated lock paths. A Python owner
   must exclude shell flock and vice versa. Tests use barriers/pipes/files with
   deadlines, not guessed sleeps or mocked lock success.
2. Implement safe open of the root-owned lock under a trusted parent; refuse
   symlink/nonregular files, support nonblocking acquisition and bounded waits.
   Test overrides may use a fixture-owned trusted directory; production trust
   checks must not be disabled merely because an environment variable is set.
3. Implement an inherited descriptor protocol with the fd number carried in an
   internal environment variable. Validate descriptor type, device/inode against
   the configured lock file, ownership, and establish/verify exclusive flock.
   Invalid/missing descriptors acquire normally or fail; never skip on a bool.
4. Provide a CLI bridge in the module for shell re-exec under ownership, plus
   Python context/child-spawn helpers. Preserve argv/exit codes/signals. Use
   `pass_fds`/inheritable descriptors explicitly; shell children must retain the
   same open file description. Do not expose a generic exec action through jobd.
5. Test nested Python -> shell -> shim and shell -> Python -> shell calls do
   not deadlock, cannot fake ownership with a flag, and release after failures
   and killed owners. Borrowed contexts NEVER call LOCK_UN on the parent's
   shared open file description. Test a nested call returns while a competing
   process remains excluded until the outer owner finishes. Unrelated
   subprocesses must not retain the descriptor.
6. Implement the root-owned runtime lifecycle status/generation described in
   spec §4.4, initialized before HTTP admission. Outer transactions rotate the
   generation and publish active before mutations; borrowers/leases do not.
   Safely handled completion publishes idle; interrupted/unsafe maintenance
   remains inhibited until explicit operator recovery. Never clear a stale
   active marker just because the kernel lock was released. Test these states
   independently of process/lock release and document recovery acknowledgement.
   Add the root-only `acknowledge-maintenance --confirm` module command from
   spec §4.4, requiring ownership and confirmed stopped/wanted-down state;
   it rotates/clears status only, never starts or validates a world. Do not
   expose it through jobd/HTTP or call it automatically after a process dies.

**Verify:** `bash tests/unit/test_lifecycle_lock.sh`; `./tests/run.sh`.
Gate: do not wire the listener until real inheritance/exclusion tests pass.

**Task 2 status (2026-10-19): implemented and verified.**
- New `lib/palwarden_lifecycle.py` (steps 2, 3, 4, 6): trusted-parent +
  `O_NOFOLLOW` open of the lock, exclusive flock with bounded waits,
  inherited-descriptor protocol via `PALWARDEN_LIFECYCLE_LOCK_FD` (dev/ino
  validation, ownership record in the lock file, identity-checked release),
  CLI bridge `acquire [-- CMD]` that re-execs under ownership, and the
  status/generation state file with `ensure_state`/`write_state`/
  `acknowledge-maintenance`. Stdlib only.
- New `tests/unit/test_lifecycle_lock.sh`: 40 assertions, all real processes,
  barrier-synchronised (no guessed sleeps), isolated lock/state paths via the
  spec §4.1/§4.4 env overrides. `bash tests/unit/test_lifecycle_lock.sh`
  passes 40/0.
- Findings and dispositions:
  - The inherited-descriptor report must never be a boolean shortcut:
    `acquire()` always performs a fresh open+flock (a process that already
    holds the lock on another descriptor is excluded by ordinary flock
    semantics anyway); only `ownership_from_env()` reports a validated
    borrowed fd. Test 5a pins "comp-held" while a nested holder exists.
  - The 4a re-exec assertion originally probed the wrong positional
    parameters under dash `sh -c`; fixed to check the re-exec'd script's own
    `$0:$1`. Test corrected, design unchanged.
  - Pre-existing, unrelated: `tests/unit/test_restore_apply.sh` has 1 failing
    assertion in this environment (session umask 002 makes `mktemp` fixtures
    0775, so `palworld-restore`'s scratch-parent trust check fires before the
    "inside the backups directory" branch the test asserts). Not caused by
    Task 2; `sbin/palworld-restore` untouched. Pending: decide whether the
    fixture should be chmod'd 0755 in-test.
- Pending checks (not blocking Task 2): root-only 6f acknowledge happy path
  (skipped when harness is not root); integration tier (`--integration`) not
  run for Task 2; real-server verification deferred per plan §9 (Task 12).
- Review pass (2026-10-19, fresh context; gate convention: findings,
  dispositions, pending checks):
  - Re-ran fresh: `bash tests/unit/test_lifecycle_lock.sh` 40/0 (root-only
    6f happy path reported UNAVAILABLE); full unit suite green except the
    pre-existing umask-002 `test_restore_apply.sh` failure noted above.
  - Spec §4.1/§4.4 re-verified line by line against tests 1a–6h: all plan
    steps 1–6 satisfied; sysexits codes 64/65/66/73/75 consistent;
    webui/jobd exposure confirmed absent (0 matches); install.sh installs
    the module via `lib/*` (line 72); `tests/run.sh` auto-discovers the
    suite.
  - Finding F1 (RESOLVED — owner chose option C, 2026-10-21): default paths
    were `/var/lib/palwarden/lifecycle.lock` + `/var/lib/palwarden/lifecycle/`
    (lib/palwarden_lifecycle.py:60-61), not the spec's
    `/run/palworld-lifecycle.lock` / `/run/palwarden-lifecycle/`.
    Resolution: LOCK moved to the spec's `/run/palworld-lifecycle.lock`
    (mutual exclusion gains nothing from persistence); STATE moved to
    `/var/lib/palwarden-ops/lifecycle/` on the persistent `palwarden-ops`
    volume (unsafe/active marker survives in-container restarts; wiped only
    on volume recreation). `install.sh` and the image now pre-create
    `/var/lib/palwarden-ops` root-owned 0755 (replacing the never-created
    `/var/lib/palwarden`); spec §4.4 amended with the decision; defaults
    pinned by test_lifecycle_lock.sh case 8 so they cannot silently drift.
  - Finding F2 (minor): `acknowledge_maintenance` returns EX_BUSY
    (line 559) without closing the fd acquired at line 537 — the only
    post-acquire path that skips close/release; unobservable today because
    the CLI exits, but the exported API would leak the held lock if a
    caller continues. Fix: close before the return.
  - Finding F3 (minor): `write_state`/`ensure_state` rotate generations
    read-then-write; safe only under the lifecycle lock (spec invariant,
    enforced by Tasks 3/10). State the precondition in the module
    docstring.
  - Constraint for Task 3: all enrolled controllers are root (jobd/run:8
    and backup-auto/run:8 document it; CLAUDE.md concurs), so the 0600
    first-writer-owns lock is openable by every acquirer; service-user
    processes must stay read-only (spec §4.1).
  - Constraint for Task 10: root-first state initialization is mandatory —
    the bare-metal web server runs as $SVC_USER and cannot mkdir under
    root-owned /var/lib.

### Task 3 — Enroll existing lifecycle controllers (spec §4.1)

**Files:** graceful-stop/restart, update, restore, container systemctl shim;
existing regression tests plus `test_lifecycle_lock.sh`.

1. Trace all service mutations and existing outer locks, including jobd,
   memory-watch, update timers, restore safety backup, failure recovery, and
   config composites. Write the actual acquisition order in the lock module.
   Outer job/backup/update locks precede lifecycle; no reverse acquisition.
2. Add failing interleaving tests before changing controller behavior.
3. Hold ownership from the state/uptime decision through complete stop/start,
   apply windows, maintenance, and recovery, not just each individual s6 call.
   Restore must cover at least the pre-stop state decision through replacement,
   start/readiness, and failure handling. Preserve its validated-copy/safety-
   backup ordering. Any backup lock needed by nested safety backup must already
   be held or inherited before lifecycle ownership, never reacquired inversely.
4. Shim start/stop/restart acquire/reuse ownership; read-only commands do not.
   Script calls already inside a transaction inherit rather than reopen it.
   Restore Python `_run` must explicitly propagate the descriptor where needed.
5. Preserve bare-metal defaults and optional notifications. Do not change
   graceful-restart timeout semantics unrelated to new wake reporting.
6. Test maintenance failure and update of an already-stopped server cannot arm
   wake mid-transaction. Test feature-off operation has no regressions.

**Verify:** lifecycle tests, discovered stop/restart/update/restore suites,
`./tests/run.sh`, and `./install.sh --dry-run` (no installation).

### Task 4 — Add positive presence observations (spec §5.1)

**Task 4 status (implemented 2026-10-21, TDD):**
- RED: extended `tests/unit/test_player_presence.sh` with ~22 assertions
  (fresh/migrated singleton begins unknown; historical identities never
  initialize trusted emptiness; 60 s freshness window incl. stale and future
  `last_success_ms`; occupied and loading-placeholder lists clear
  `empty_since_ms`; strict `fetch_players` — fetch failure, malformed JSON,
  missing/non-list `players`, non-object/null entries all invalidate and the
  next empty success starts a NEW interval; sampler survives the failure
  gauntlet; metrics/presence independence; module-level sequence-fence test).
  Pre-implementation run: 60 passed / 23 failed (all failures on the missing
  table/module).
- GREEN: new `lib/palwarden_presence.py` (AGPL SPDX, stdlib only): owns the
  presence schema (`create_schema`: identity, sessions, singleton
  `presence_state` with `last_success_ms`/`valid`/`empty_since_ms` +
  `allocated_seq`/`applied_seq`), strict `validate_players_payload`
  (errors never coerce to `[]`), `reserve_observation`/`apply_observation`
  (short `BEGIN IMMEDIATE` transactions, sequence fence — superseded results
  apply nothing, no playtime movement; no transaction held over HTTP),
  best-effort `invalidate`, and the playtime writer moved verbatim from
  `palworld-fps` (`_record_identities`).
- `sbin/palworld-fps`: imports the module via the jobd/webui sys.path
  pattern; `connect()` delegates the presence schema to it; `fetch_players`
  is strict; `sample()` reserves before the request, applies under the fence
  (`presence=superseded` surfaces in the tick line), invalidates best-effort
  on failure. Playtime/ip-ping-location semantics unchanged.
- Verification (umask 022): `bash tests/unit/test_player_presence.sh` =
  82 passed, 0 failed
  (`~/.hermes/profiles/code64/cache/scratch/palwarden-task4-presence.log`);
  full `./tests/run.sh` = ALL SUITES PASSED
  (`.../palwarden-task4-unit.log`). Baseline before Task 4 (Task 3 tree,
  umask 022) was also fully green
  (`.../palwarden-task4-baseline.log`).
- Findings and dispositions:
  - Three intermediate test failures were test bugs, not implementation
    weaknesses: (a) migration case reused a DB already sampled by the new
    code — replaced with a simulated pre-Task-4 DB (drop singleton, seed
    history); (b) a shell variable scoped inside a heredoc; (c) an
    impossible freshness-window assertion (`date +%s` second-truncation put
    the restart ~688 ms outside a 120 s bound) — window widened to 125 s
    with a comment; the property asserted (restart at now, not the stale
    value, not the future) is unchanged.
  - `create_schema` now owns player_identity/player_sessions too (moved out
    of `connect()`), so the module is the single schema owner the watcher
    (Task 7) can rely on; `connect()` keeps fps_samples/fps_events.
  - Reservation happens even when the fetch then fails: the sequence is
    allocated but never applied — harmless (counters only fence ordering).
- Pending checks: independent review of the Task 4 diff (self-review only
  so far); integration tier not run for Task 4 (no container-visible change
  beyond the sampler); real-DB migration on an existing production
  metrics.sqlite3 untested outside fixtures.
- Constraint for Task 7: the watcher's final check must use
  `reserve_observation`/`apply_observation`/`invalidate` from this module
  (separate short write connection), never a looser parser, and must treat
  `applied=False` or a reserve/apply exception as "no stop".

### Task 5 — Truthful idempotent start operation (spec §4.3, §6.2)

**Files:** lifecycle module, new `sbin/palworld-knock`, `test_knock.sh`.

1. Write state adapter tests: running, starting, fully stopped/wanted-down,
   down/wanted-up (crash backoff), stopping, missing supervisor, query failure.
   For s6 inspect its installed/documented machine-readable actual/wanted-state
   fields. Do not infer wanted state from `systemctl is-active` or process
   absence alone. Use root s6 access; retain a distinct portable systemd branch.
2. Implement `start_if_down` and `palworld-knock wake`: nonblocking lifecycle
   acquisition, recheck state/config/cooldown, start only eligible down service.
   Busy request exits 75 with retry guidance, not a queued delayed start.
   Already-up/cooldown no-op exits 0 with explicit status and no notification.
   Actual validation/start/readiness failure is nonzero; invalid CLI usage 64.
3. Atomically write cooldown before start at the spec path. Test missing,
   recent, expired, corrupt, and future values; corruption/future fails closed.
   Apply to all wake sources. Do not reset it for invalid traffic/no-ops.
4. Start via existing service machinery under ownership, never restart/down.
   Exercise real exclusion with two concurrent wakes; assert exactly one start
   and zero down commands. Explicit wake can operate with UDP disabled.
5. Confirm running state, then poll existing API client for at most 180 s with
   bounded per-call timeouts. REST exit 2 -> started/readiness-unverified;
   success -> healthy; other timeout/failure -> nonzero. Use injectable clients,
   clock, and short deadlines in unit fixtures, not a 180-second unit sleep.
6. Add optional notify adapter with fixed shell code and argument passing.
   Marker/notify failure must not break lifecycle safety or leak fixture tokens.

**Verify:** `bash tests/unit/test_knock.sh`; lifecycle tests; `./tests/run.sh`.

### Task 5 status (implemented 2026-10-21, TDD)

- RED: new `tests/unit/test_knock.sh` (63 assertions): six-state s6 adapter
  (running/starting/stopping/stopped-wanted-down/crash-backoff/no-supervisor
  + unknown-on-query-failure, wanted state read from s6's `down` marker,
  never inferred from process absence); portable systemd branch
  (is-active + is-enabled); cooldown semantics (missing/active/expired/
  corrupt/future/negative fail closed, atomic 0640 write); `wake` happy path
  (cooldown written BEFORE start — proven by the starter stub observing the
  file; ownership FD handed to the starter via `PALWARDEN_LIFECYCLE_LOCK_FD`;
  exactly one start, zero stop/restart; one notification; token never
  echoed); already-up/cooldown no-ops (exit 0, explicit status, no start,
  no notification, marker not reset); crash-backoff/stopping/unknown/
  no-supervisor refusals; busy lock -> 75 + retry guidance with nothing
  queued; concurrent-wake race (file barrier + 0.3 s starter) -> exactly one
  0 and one 75, exactly one start, zero downs; readiness outcomes (exit 2 =
  started-but-unverified never called healthy; persistent failure nonzero;
  polling recovers within the window); notify-helper failure nonfatal;
  explicit wake works with UDP disabled; usage errors exit 64.
  Pre-implementation run: 19 passed / 44 failed.
- GREEN: `lib/palwarden_lifecycle.py` gained `service_state()` (+ s6/systemd
  branches), `read_cooldown`/`write_cooldown`/`cooldown_status`/
  `cooldown_path` (override `PALWORLD_KNOCK_COOLDOWN_FILE`, default
  `/var/lib/palwarden-ops/knock.cooldown`), `_start_service` (start only,
  never restart/down; CLOEXEC cleared on the lock descriptor only around the
  spawn so the starter inherits ownership and later subprocesses never do),
  `_notify` (fixed argv, missing/failing helper nonfatal), `_readiness`
  (polls `palworld-api metrics`, default 180 s bound, exit 2 = unverified),
  and `start_if_down(fd, reason, config)` — the one transaction shared by
  CLI now and UDP/job wake later. New `sbin/palworld-knock wake
  [--reason TEXT]`: nonblocking acquisition (busy -> 75 + retry guidance,
  nothing queued), rechecks state/config/cooldown under ownership, maps
  statuses to 0/64/65/75/1.
- Verification (umask 022): `bash tests/unit/test_knock.sh` = 63/0
  (`~/.hermes/profiles/code64/cache/scratch/palwarden-task5-knock.log`);
  full `./tests/run.sh` = ALL SUITES PASSED
  (`.../palwarden-task5-unit.log`).
- Findings and dispositions: ~10 intermediate failures were all test-harness
  bugs (GNU `env` prints the environment when given assignments but no
  command; ops fixture must be schema-complete; grep -c prints nothing for
  a missing file; stub worlds leaking state between sections; stub `start`
  must clear the s6 `down` marker like `s6-svc -u`; readiness-stub counter
  gating). None were answered by weakening the implementation.
- Design notes: s6 "starting" is detected as `up (no pid)`; a future
  cooldown timestamp beyond 60 s skew fails closed; `start_if_down` treats
  crash-backoff as the supervisor's job (refuse), and unknown/no-supervisor
  as refuse-never-blind.
- Pending checks: independent review of the Task 5 diff (self-review only);
  install.sh packaging deliberately deferred to Task 11 (the new CLI is not
  installed yet); real s6/systemd environments unexercised (unit tier uses
  stubs by design); the `wake` CLI is not yet wired to jobd `server_wake`
  (Task 9) or the UDP daemon (Task 6) — both must call `start_if_down`.

### Task 6 — UDP listener with bounded leases (spec §4.2, §6.1)

**Files:** `sbin/palworld-knock`, `test_knock.sh`, lifecycle tests.

1. Use test port 18211 through a constructor/CLI test fixture override, not
   fictional SERVER_PORT settings. Production internal listener remains 8211.
2. Test acquisition -> confirmed wanted-down -> bind -> close -> unlock order.
   Every lease is <=1 s by monotonic deadline; wait >=100 ms between leases.
   Explicit controllers have a bounded acquisition deadline and fail visibly
   rather than hang; flock is not promised FIFO. Test controller acquisition
   within five seconds under sustained fixture traffic. Test a
   concurrent supported manual start can bind its reference game socket before
   proceeding and is not starved by repeated lease reacquisition.
3. Valid UDP closes socket first, revalidates config/state/token/cooldown under
   ownership, then invokes the shared synchronous start operation. No detached
   process or extra down command. If config/token changed, drop or defer safely.
4. Cover wrong/exact token, empty token, finite payload bounds, EADDRINUSE,
   service up/starting/crash-backoff, lock busy, and daemon termination.
   Compare configured token's UTF-8 bytes exactly. Receive maximum-token-plus-
   one bytes or detect truncation; reject oversized/truncated packets in token
   mode. Test a 512-byte token plus suffix and invalid UTF-8 cannot match.
   Open-doorbell mode accepts any nonempty datagram regardless of bounded-buffer
   truncation, without retaining or parsing its payload.
5. Flood wrong-token packets across a lease boundary: state/config checks and
   competing maintenance must still progress, logs must be bounded, and token
   payload/source addresses must not be published to events/Discord.
6. Reload config every lease/idle second. Disable closes socket within the
   next boundary; enable re-arms when safe; changing token takes effect without
   restart. Config changes do not interrupt an already-issued lifecycle action.

**Verify:** `bash tests/unit/test_knock.sh` and lock tests repeatedly with bounded
race-test deadlines; `./tests/run.sh`. Kill only fixture-owned child PIDs.

### Task 6 status (implemented 2026-10-21, TDD)

- RED: `tests/unit/test_knock.sh` section 7 (~37 assertions): arm only on
  stopped+wanted-down (running/stopping/crash-backoff never arm; re-arm on
  return to stopped); lease order proven from the controller side (once a
  bounded acquisition wins the lock the port is already closed — socket
  closes BEFORE release, so a manual start can bind the game socket under
  its own ownership); controller acquisition <5 s under sustained knock
  traffic (measured ms asserted); exact-token wake with cooldown marker,
  zero stop/restart, one log line, token and source addresses never logged;
  cooldown gates the next packet (world re-stopped, marker kept); wrong /
  empty / 513-byte / token+suffix / invalid-UTF-8 rejections with aggregated
  invalid-count; 512-byte-token+suffix anti-truncation; open-doorbell accepts
  an oversized datagram without parsing and ignores empty; live reload
  (disable closes by next boundary, enable re-arms, token edit applies
  without restart); EADDRINUSE survives with bounded logs and rebinds;
  wrong-token flood across lease boundaries (alive, no start, aggregated
  logs, no payload/address leaks, controller still acquires); SIGTERM exits
  0 and frees port+lock. Pre-implementation run: 81 passed / 17 failed, all
  in section 7.
- GREEN: `sbin/palworld-knock daemon [--port N]` — per-lease cycle: bounded
  `acquire` (default 1 s, contention -> rate-limited retry, never a wake),
  config re-resolved EVERY lease (live reload), `service_state()=="stopped"`
  gate, bind (EADDRINUSE -> bounded warning), listen under a monotonic
  <=1 s deadline (invalid packets cannot extend it), socket closed BEFORE
  release and BEFORE wake, wake via the shared `start_if_down` with
  config/token revalidation under ownership (drop if disabled/token changed;
  cooldown rechecked inside the transaction). Receive bound 513 =
  token-max+1: >=513 rejected in token mode (oversized/truncated), exact
  UTF-8 byte compare otherwise (invalid UTF-8 cannot match); doorbell mode
  accepts any nonempty datagram without retaining payloads. Env-tunable
  lease/idle/acquire timings are CLAMPED to spec bounds (lease <=1 s, idle
  >=100 ms). `--port` is a fixture override only; production default stays
  8211. SIGTERM/SIGINT exit 0 within one poll.
- `tests/unit/test_lifecycle_lock.sh` case 9: real daemon against the
  shared fixture lock — three controller acquisitions each <5 s, and the
  port is never held while a controller owns the lock.
- Verification (umask 022): `bash tests/unit/test_knock.sh` = 100/0 three
  consecutive runs (`.../palwarden-task6-knock-r{1,2,3}.log`);
  `bash tests/unit/test_lifecycle_lock.sh` = 43/0 twice
  (`.../palwarden-task6-lock-r{1,2}.log`); full `./tests/run.sh` = ALL
  SUITES PASSED (`.../palwarden-task6-unit.log`).
- Coverage addendum (same day): explicit `starting`-never-arms and
  lock-busy-stays-closed/re-arms assertions added (checklist item 4);
  one flake found by a full-suite run — the single-shot "the daemon logs
  the wake" grep raced the daemon (the line is written only after
  start_if_down completes, readiness included) — replaced with a
  deadline-poll oracle. Re-verified: knock 103/0 x3
  (`.../palwarden-task6-knock-f{1,2,3}.log`) and full `./tests/run.sh` =
  ALL SUITES PASSED (`.../palwarden-task6-unit-final.log`).
- Untestable-at-unit-tier note: the "token/disabled changed between packet
  accept and revalidation -> drop" path is implemented in _handle_packet
  but its window is sub-millisecond; no deterministic unit fixture exists
  (the container tier could exercise it later).
- Findings and dispositions (all harness bugs; none answered by weakening
  the implementation): (1) the first `port_bound` oracle sent a live probe
  datagram — a bound listener consumes it as a token-invalid knock and the
  probe's recv never answers; replaced with the kernel UDP table (`ss -lun`).
  (2) `make_ops` wrote the ops file non-atomically while the daemon
  re-reads it every lease — replaced with tmp+`mv`. (3) The doorbell case
  sent its packet immediately after a config edit, but config reloads at
  lease START: the in-flight lease still held the old token and consumed
  the packet as invalid. Fixed by waiting one lease boundary after the edit
  (same wait the token-edit case already had). Mutation check: a daemon
  variant that rejects oversized datagrams in doorbell mode fails exactly
  that assertion (82/1); the real daemon passes.
- Design notes: the daemon never queues a deferred wake — a packet arriving
  during maintenance is simply not served (bounded retry re-arms later);
  payloads are dropped immediately after the accept decision; all repeated
  warning categories share a 30 s per-key rate limit plus an aggregated
  invalid-packet counter.
- Pending checks: independent review of the Task 4/5/6 diffs (self-review
  only so far); s6 wiring + install packaging are Task 10/11 scope (the
  daemon is not yet supervised or installed); real-container lease behavior
  unexercised (unit tier uses stubs by design).


### Task 7 — Idle tick and live scheduler (spec §5.2, §7.2)

**Files:** new `sbin/palworld-idle-watch`, `test_idle_watch.sh`.

1. Build DB fixtures through real migration/sampler code. Supply clients,
   service/uptime, paths, clocks, notifier, and marker as isolated test doubles.
2. RED cases: off, occupied/loading, short/unknown uptime, stale presence while
   info healthy, invalid/empty/missing schema, locked DB, failed continuity,
   and coherent fresh empty interval >=timeout. Short uptime always inhibits.
3. Implement one-shot eligibility using presence_state, not identity MAX. Use
   portable `palworld.service`, parse actual timestamp format, and bounded
   read-only SQLite access. Unknown state logs without stopping.
4. Nonblocking lifecycle ownership; re-read config/uptime/evidence, then final
   schema-valid players call. Test a new player, loading entry, API failure,
   disabled config, or restarted service at this boundary aborts safely.
   Reserve/apply final-check observations through the shared writer (separate
   short write connection, not the read-only eligibility connection). Occupied
   or unknown results clear empty continuity, forcing a NEW full empty period.
   An older in-flight sampler cannot undo that reset. After an empty result is
   applied, re-read eligibility; superseded results or failed writes cannot stop.
5. Eligible path: best-effort marker and one reason warning, graceful-stop
   `--wait 0 --message ...` with inherited fd, then service-down confirmation.
   Tailor reason to open/token/disabled UDP policy; no false wake promise.
6. Implement `--loop` with monotonic scheduling and config refresh at least once
   per second. Interval edits recompute due time relative to last tick; overdue
   runs promptly. Test each idle setting live with fake clocks. No change to
   `docker/palwarden-run-periodic` is required.

**Verify:** `bash tests/unit/test_idle_watch.sh`; presence/lock tests;
`./tests/run.sh`.

### Task 7 status (implemented 2026-10-21, TDD)

- RED: new `tests/unit/test_idle_watch.sh` (61 assertions): every skip
  condition (disabled, occupied, loading-placeholder-as-occupancy,
  uptime-short, uptime-unknown garbage/empty, empty interval shorter than
  timeout, stale last-success, invalid, missing DB, missing table, locked
  DB, empty_since-after-last_success and future-dated discontinuities,
  lock-busy) — none may stop; the eligible path (stop issued with
  `--wait 0`, graceful-stop genuinely running under the INHERITED lock
  descriptor proven via the `borrowed` probe, idle event row, exactly one
  warning, service-down confirmed); reason wording per wake policy
  (disabled: no knock promise; token: explains token, never leaks it;
  doorbell: offers knock); boundary aborts (joining player aborts AND
  clears the stored empty interval; API error and malformed payload abort
  and invalidate; failing stop and unconfirmed stop exit 1); in-process
  module tier for interleavings a subprocess cannot time (superseded final
  result, config flip to disabled, uptime reset, state flip, apply write
  failure — all abort with zero stop calls); fake-clock --loop scheduling
  (first tick immediate; interval edit reschedules relative to the LAST
  tick); real-wired --loop live IDLE_TIMEOUT edit without restart; usage
  64. Pre-implementation run: 17 passed / 39 failed, all substantive
  assertions failing on empty output.
- GREEN: new `sbin/palworld-idle-watch` (Python stdlib, importable).
  One-shot tick + `--loop`. Eligibility via `mode=ro` connection with a
  bounded 2 s busy timeout: valid, not-future, <=60 s fresh last-success,
  coherent not-future empty_since covering the full timeout; anything
  else (missing DB/table, locked, discontinuity) is UNKNOWN. Uptime from
  `systemctl show -p ExecMainStartTimestamp --value palworld.service`
  parsed in the real systemd/s6-shim format; unparseable/empty = UNKNOWN.
  Nonblocking acquire (busy -> skip); under ownership everything re-reads
  (config/state/uptime/evidence), then the final schema-valid players call
  is reserved/applied through the SHARED presence writer on a short-lived
  write connection; occupied/error/superseded/write-failure abort and
  clear or invalidate the stored evidence; post-apply eligibility recheck.
  Stop path: best-effort idle event, one warning, `palworld-graceful-stop
  --wait 0 --message <policy-aware reason>` spawned with the lock fd
  inherited (ownership_env + pass_fds), then bounded service-down
  confirmation (PALWARDEN_IDLE_STOP_CONFIRM_S/POLL_S). Invalid config
  file = skip, never a crash loop. --loop: monotonic, config re-read every
  second, interval edits recompute from the last tick, overdue runs
  promptly. Env levers: PALWORLD_METRICS_DB, PALWORLD_API_BIN,
  PALWARDEN_GRACEFUL_STOP_BIN, PALWARDEN_SYSTEMCTL_BIN, notify helper.
- Verification (umask 022): `bash tests/unit/test_idle_watch.sh` = 61/0
  twice (`.../palwarden-task7-i{1,2}.log`); full `./tests/run.sh` = ALL
  SUITES PASSED (`.../palwarden-task7-unit.log`, third idle run).
- Findings and dispositions (all harness bugs; implementation unchanged
  by any of them): (1) ops fixtures must be rendered through the real
  `ops.render` writer (JSON-string values), raw KEY=value fails closed;
  (2) bash `VAR=x func` prefix assignments PERSIST after the function —
  the UPTAGE leak made every later case uptime-unknown; moved inside
  `$(VAR=x func)`; (3) fixture reset must clear stop-stub behavior markers
  (`stop.nodeown` leaked into the --loop case and stalled its tick in the
  confirmation poll); (4) `spec_from_file_location` cannot load an
  extension-less script — use `SourceFileLoader`; (5) the module-tier
  harness now requires all 6 checks to report so a silent zero-output run
  can never pass; (6) the empty-old seed must chain observations within
  the 60 s trust window (a 175 s gap restarts the interval — caught by the
  real presence semantics, seed fixed, not the module).
- Design notes: the watcher never holds a DB transaction across HTTP; the
  final-check connection is separate from the read-only eligibility
  connection; event/notification failures cannot block a safe stop; a
  config change can never undo an already-issued stop (the stop call is
  synchronous under ownership). The narrow join-versus-stop race after the
  final REST check remains by design (spec §5.2); real-game validation is
  Task 12 scope.
- Pending checks: s6 wiring for the watcher is Task 10 scope (not yet
  supervised/installed); independent review gate still pending for Tasks
  4-7 diffs.


### Task 8 — Config and wake job API, including secret lifecycle (spec §7)

**Files:** jobd, webui, jobs library, `test_palwarden_config.sh`, existing web/job
tests; inspect existing validation, enqueue and finalization before modifying.

1. Test `palwarden_config_save` with settings-only payload, no arbitrary
   path/command, root revalidation, execution-time partial merge, and atomic
   write. Omitted token keeps, explicit empty clears, valid text replaces.
   Do not reset omitted nonsecret settings to defaults.
2. Add GET/PUT `/api/palwarden-config` using shared schema and existing mutation
   authentication, origin/CSRF, body-size and job error conventions. Reject
   unauthenticated/cross-site PUT and malformed input. No GET token value.
3. Add nondisruptive `server_wake` fixed argv -> `palworld-knock wake` with a
   bounded validated reason. It cannot accept arbitrary binaries/options, down
   requests, config applies, or silently turn into graceful_restart. Test
   already-running, busy, cooldown, success, and failure jobs.
   At admission reject active/unknown lifecycle status and queued/running
   disruptive jobs with 409. Mint internal idle-generation and 15-second expiry
   fields server-side; reject caller attempts to supply those fields. Validate
   them in jobd and again under lifecycle ownership BEFORE the wake transaction
   changes generation. A changed generation or expired request fails without
   starting. Internal fields may be carried through fixed validated argv; no
   public arbitrary-option slot. Test a request submitted during serial jobd
   maintenance cannot execute as a delayed wake after it, and direct maintenance
   between enqueue/execution invalidates an admitted wake too. Old-runtime
   generations must not survive runtime restart.
4. Add one explicit public-job serializer used by ALL enqueue/list/detail
   responses. Redact KNOCK_TOKEN narrowly, preserving internal pending payload
   and existing nonsecret fields. Do not call redacted reads in the worker.
5. Verify private queue 0700/file 0600, and root processing still works.
   Scrub raw token fields on success, failure, validation refusal, and orphan
   reaping. Test pending APIs do not expose it and final raw job files no longer
   contain it. Cover existing synchronous response paths and error formatting.
6. Ensure neither errors nor worker output/logs echo tokens, full settings,
   packet payloads, or source-IP event labels. Use synthetic unique markers
   to detect leakage without printing credentials.

**Verify:** config and existing web/job tests; `./tests/run.sh`.

### Task 8 design decisions (recorded 2026-10-22, before implementation)

- `palwarden_config_save` (jobd): non-disruptive, params `settings` = partial
  map over the five ops keys, values canonicalised through `palwarden_ops`
  (errors never echo token values). File-only action: at EXECUTION time
  `resolve()` current -> `merge()` supplied -> `write_config()`. No argv.
- `server_wake` (jobd): non-disruptive; params `reason` (optional, printable
  <=200) plus server-minted `wake_generation` (32-hex) and `wake_expires_at`
  (canonical int). `WAKE_INTERNAL_FIELDS` exported; webui admission rejects any
  caller-supplied copy with 400, then mints generation (from `read_state()`)
  and `now+15s` expiry itself. Fixed argv
  `palworld-knock wake --reason R --fence-generation G --fence-expires-at T`.
- Fence enforcement, twice: jobd pre-checks expiry + `read_state()` (status
  must be `idle`, generation must match) BEFORE spawning anything; `wake`
  re-checks both AFTER acquiring lifecycle ownership and BEFORE
  `start_if_down` (the flags are all-or-nothing; refusal exits 65 without
  starting). Fence is freshness, not authorization (spec §4.4).
- Generation rotation for queued maintenance: jobd wraps service-mutating
  disruptive actions (all disruptive except `backup_delete`, which mutates no
  service) — `write_state("active", <class>, rotate=True)` before the steps,
  `write_state("idle")` after success, `write_state("unsafe", <class>)` after
  failure (fail closed; `acknowledge-maintenance` clears). `reap_orphans`
  marks `unsafe` when it reaps a wrapped action's job. Writes are best-effort
  with a visible warning: if the state dir is unavailable wake admission
  already fails closed (missing state reads `unknown` -> 409), so a broken
  install cannot produce a silently unfenced wake. Direct maintenance by the
  enrolled controllers still does not mark state (task 3 enrolled the lock
  only) — recorded gap; the wake's own nonblocking acquire plus the 15-second
  expiry bound that window, and tests cover both the lock-held and
  generation-rotated variants of direct maintenance.
- `init_runtime()` in the lifecycle module: `ensure_state()`, then rotate the
  generation iff status is `idle` (active/unsafe markers survive; old-runtime
  generations do not). Called by jobd's daemon mode at startup (not `--once`/
  `--reap`, which are test/cron one-shots); entrypoint/systemd wiring is
  task 10.
- Public serializer `public_job(job)` in `palwarden_jobs.py`: replaces
  `params.settings.KNOCK_TOKEN` with `<redacted>` for
  `palwarden_config_save` jobs only; used by webui enqueue/list/detail. The
  worker never calls it. Raw-file scrub (jobd): on success, failure,
  validation refusal, and orphan reaping of a config-save job, the token
  value in the job file is replaced with the same marker.
- `GET /api/palwarden-config` = `resolve()` + `public_view()` (four values +
  `token_configured`, never the token). `PUT` reuses the POST /api/jobs
  mutation checks (Basic + token header + origin + body cap), validates
  through `jobd.validate_params("palwarden_config_save", ...)`, enqueues,
  returns 202 + job id.

### Task 8 status (implemented 2026-10-22, TDD)

- RED first: ~60 new assertions in `tests/unit/test_jobd.sh` (346/26),
  11 in `test_knock.sh`, 10 in `test_lifecycle_lock.sh`, 3 in
  `test_jobs_store.sh`, ~40 in `test_webui_jobs.sh` — all failing for the
  right reasons before implementation.
- GREEN: full `./tests/run.sh` **ALL SUITES PASSED** — jobd 371/0,
  webui-jobs 175/0, knock 121/0, lifecycle-lock 49/0, jobs-store 28/0,
  idle-watch 61/0, plus every pre-existing suite unchanged.
- Plan-item audit follow-up: wake's own outcomes are now tested AT THE JOB
  LEVEL too (already-running/cooldown -> succeeded jobs carrying wake's
  line; busy(75)/failure -> failed jobs), and `server_wake` refuses
  smuggled down/config/restart shapes (`down`, `confirm`, `wait`,
  `settings`, `message` all unknown params).
- Delivered: `palwarden_config_save` (partial merge at execution,
  keep-by-omission, explicit-empty clear, malformed-file fail closed);
  `server_wake` (admission 409 on unknown/active/unsafe/blocking-disruptive,
  400 on caller-supplied fence fields, server-minted generation + 15 s
  expiry; jobd pre-check + wake's under-ownership re-check; refusal 65
  without starting); token lifecycle (public_job on every browser-facing
  job response; raw-file scrub on success/failure/refusal/reap, scrubbed
  BEFORE the terminal update so a crash cannot strand it — review-driven
  hardening; no error path echoes token values); disruptive wrap
  (active+rotate → idle/unsafe, reap→unsafe, backup_delete exempt);
  `init_runtime()` + CLI verb, called by jobd daemon start-up.
- Independent review (isolated scout vs spec §4.4/§7.2/§7.3): no fence
  bypass or leak path found; one valid hardening adopted (scrub ordering);
  one finding was a misread (already-up is exit 0, tested);
  acknowledge-maintenance panel wiring deferred to Task 9/10 as planned;
  best-effort `_mark_state` accepted (admission fail-closes on missing
  state).
- Known deferred gap (recorded, not hidden): enrolled controllers still
  mark no lifecycle state themselves (Task 3 enrolled the lock only), so
  direct maintenance outside jobd invalidates wakes only via the wake's
  nonblocking acquire + the 15 s expiry, not via generation rotation.
  Queued (jobd-wrapped) maintenance fully invalidates wakes (tested).
  Closing this means state writes inside `palwarden-lifecycle-bash`
  acquire — a Task 3 follow-up, flagged for the Task 10 integration pass.
- Test-harness fixes found along the way: the suite leaked its second
  webui server (port squatter made later runs test a stale process —
  PID2 now captured and reaped); `wake_*` helpers must target the fresh
  server's queue.

### Task 9 — Implement the actual browser panel (spec §7.2)

**Files:** `webui/palwarden.html`; config/webui tests and browser checks.

1. Follow existing control-plane fetch/auth/job UI conventions. Add controls
   for timeout, interval, knock enablement, cooldown, and password-style token
   replacement; show configured/unset state without preloading a secret.
2. Track changed fields. Omitted token keeps; explicit clear is a separate
   operator action. Never submit a displayed placeholder as a replacement.
3. GET loads settings; PUT queues a save; poll/show returned job completion and
   reload effective settings. Failed writes must not show a success toast.
   Add explicit authorized Wake control using `server_wake`.
4. Explain first-attempt retry, open-doorbell scanning, token limitations,
   partial-save behavior, immediate configuration effects, and persisted seeds.
   Render reasons/errors safely as text rather than executable HTML.
5. Exercise real served page: load, edit all five values, save, clear/replace/
   retain token, job failure, busy wake, unauthorized request. Inspect actual
   requests and rendered success/error states; static endpoint tests alone do
   not satisfy UI acceptance. If browser tooling is unavailable, report blocked
   browser verification rather than marking it complete.

**Verify:** webui/config tests; actual isolated browser session; `./tests/run.sh`.

#### Task 9 design decisions (2026-10-22, recorded before implementing)

Verified contract facts (source-inspected, working tree):
- GET `/api/palwarden-config` → `{ok:true, data:{IDLE_TIMEOUT:int,
  IDLE_CHECK_INTERVAL:int, KNOCK_ENABLED:bool, KNOCK_COOLDOWN:int,
  token_configured:bool}}` (ops.public_view, lib/palwarden_ops.py:266);
  malformed file → 500 fail-closed (sbin/palwarden-webui ep_palwarden_config).
- PUT body = partial config object of the five keys; same mutation checks as
  POST /api/jobs (X-Palwarden-Token, origin, body cap); 202 `{ok:true,id}`;
  validate via jobd.validate_params('palwarden_config_save') →
  ops.canonical accepts TYPED JSON (int numbers, true/false bools;
  KNOCK_TOKEN "" passes canonical = the clear, verified by direct call).
  Ranges (ops.SCHEMA): IDLE_TIMEOUT 0..10080, IDLE_CHECK_INTERVAL 1..3600,
  KNOCK_COOLDOWN 1..86400, token ≤512 bytes no control chars.
- POST /api/jobs server_wake: caller supplies at most `reason` (1-200
  printable, not `--`-prefixed); fence fields supplied by caller → 400;
  admission failure (unknown/active/unsafe/blocking job) → 409 with error
  text; success 202 + id (sbin/palwarden-webui:1359-1377).
- Page conventions: dashboard is currently read-only (palwarden.html:164-168
  comment must be updated); mutation conventions live in backups.html
  (token()/postJob/pollJob/runJob, lines 489-695); structural guard in
  test_webui_jobs.sh runs over palwarden.html: NO HTML sinks (innerHTML only
  as `= ""` clear), no raw colours outside :root/shared sheet, no inline
  style attributes. Node-extraction tier pattern: awk-extract pure functions,
  run under node with stubs (test_webui_jobs.sh collectSettings/token tiers).

Decisions:
- D1 Card: one new `<details class="pw-card pw-card--full pw-section
  pw-section--indigo" open>` ("Idle shutdown & knock wake") appended inside
  `.pw-grid` after Snapshots. Reuses existing components only.
- D2 Mutations follow backups.html conventions scoped to the card: same
  TOKEN_KEY sessionStorage key, token() with /api/token + prompt fallback,
  pollJob (2 s interval, bounded attempts, tolerates 10 consecutive status
  failures). No global toast markup on this page; outcomes render into an
  inline status line (`ops-status`, textContent) plus a card job log
  (`ops-log`, `<pre class="pw-log">` like the other cards).
- D3 Form: number inputs with min/max from SPEC; KNOCK_ENABLED checkbox;
  token = `type=password` input, placeholder "leave blank to keep",
  autocomplete="new-password", NEVER prefilled; token state shown as a
  pw-pill CONFIGURED/UNSET from token_configured; "Clear token" is a separate
  button that PUTs `{"KNOCK_TOKEN":""}`.
- D4 Change tracking: baseline = last successful public_view. Pure
  `collectOpsSettings(form, baseline)` returns ONLY changed keys;
  KNOCK_TOKEN included only when the password field holds a typed non-empty
  value (the placeholder is never a value — it is an attribute). No changes →
  save button disabled. Wire types typed (numbers, true/false).
- D5 Save flow: PUT → 202 id → pollJob → succeeded: OK status + re-GET
  effective config + blank the token field + refresh pill; failed/400/403/
  409/500: ERROR status with the server's message, never a success render.
  403 drops the cached token (self-heal on retry).
- D6 Wake: optional reason input (maxlength 200) + "Wake now" button →
  postJob('server_wake', {reason?}); 409 error text rendered as-is. The page
  never sends wake_* fields (server 400s them anyway).
- D7 Help block (`<details>` "How this works", static prose): first UDP
  attempt consumed → players retry after startup; empty token = open-doorbell
  (any nonempty datagram wakes; cooldown bounds frequency; the game's own
  password still applies; a datagram is not authentication); token is exact
  byte comparison, not encryption, not replay protection; save merges only
  the changed keys at execution time (partial save); edits take effect at the
  next lease boundary/tick without restart but cannot undo an already-issued
  start/stop; env seeds apply only when the config file is absent — browser
  edits persist on the ops volume across container recreation.
- D8 All server-supplied strings reach the DOM via textContent only
  (page's text()/put() helpers); new markup passes the existing structural
  guard (no sinks/colours/inline styles).
- D9 Tests: (a) test_webui_jobs.sh node tier — extract collectOpsSettings()
  and the wake-body builder, gauntlet keep/clear/replace/placeholder/
  unchanged/only-changed-keys/no-fence-fields. (b) NEW
  tests/unit/test_webui_panel.sh — jsdom tier (jsdom installed in scratch;
  no chromium/playwright exists on this host): boot the real webui server
  with the existing stub harness, fetch the ACTUALLY SERVED /palwarden.html,
  run it in jsdom with fetch bridged to node fetch (Basic creds + token
  header), then exercise: load fills form; edit all five → save → assert the
  PUT body carries only changed keys; token blank→omitted, typed→included,
  clear→{"KNOCK_TOKEN":""}; job success → success status + reloaded values;
  job failure → error status and NO success text; wake busy (409) → error
  text; unauthorized (no token header) → error surfaced. Skips (not fails)
  when jsdom is absent; CI does not install jsdom, so the node tier (a)
  remains the CI-enforced page-behaviour gate. (c) Real-browser tier:
  BLOCKED on this host (no chromium/playwright) — reported as blocked, not
  complete, per the plan's own instruction.

#### Task 9 plan-review gate (isolated reviewer, 2026-10-22) — disposition
- "empty-token ambiguity in canonical/resolve" — MISREAD: the cited
  `"" if raw is None else raw` is the env-SEED branch of resolve() when no
  file exists (palwarden_ops.py:231-233), not the PUT path; empty-clears is
  pinned end-to-end by test_jobd.sh:1142-1144 and canonical('KNOCK_TOKEN','')
  == '' was verified by direct call. No change.
- "canonical expects post-parsed types, not raw JSON" — CLARIFICATION ONLY:
  the design already routes PUT bodies through json.loads BEFORE
  validate_params/canonical (sbin/palwarden-webui _save_palwarden_config);
  typed acceptance verified by direct call (True→'true', 300→'300'). No change.
- "palwarden_config_save not registered in webui" — MISREAD: registered at
  jobd:1124 and created by _save_palwarden_config (verified by grep). No change.
- "concurrent edits unspecified" — VALID (documentation): help text will state
  explicitly that saves merge per-key at execution time and the LAST save of a
  key wins (no version check / ETag). Adopted into D7.
- "help/defaults lacks a Reset-to-Defaults control" — INTERPRETATION: spec
  §7.2's "help/defaults" is satisfied by help prose that STATES each default
  (0 = disabled, 60 s, enabled, 600 s, empty = open doorbell); a reset button
  is not in the spec and is out of scope. Adopted into D7 (defaults listed).
- Reviewer raised no blockers; verdict "needs fixes" addressed by the two
  adopted documentation items. Interaction hazards re-verified directly:
  refresh()/pollJobs() write only pre-existing ids (server-*, vital-*, fps,
  events, engine, backups, snapshots, jobs) — no overlap with ops-* ids; the
  'exactly 2 runJob call sites' guard targets ONLY PalWorldSettingsEditor.html
  (sys.argv[1]), not the dashboard; ops form is filled only on initial load
  and after a successful save, never on a timer, so refresh cannot clobber
  in-progress edits.

#### Task 9 status (2026-10-22, TDD) — implementation complete
- RED first: node tier added to test_webui_jobs.sh (extracts
  collectOpsSettings()/wakeParams() from the dashboard; 14 behavioural checks
  — only-changed-keys, typed ints/bools, blank-token-omitted, typed-token-
  alone, no-empty-clear-side-effect, reason trimming, no fence fields) plus
  three structural greps (password input, no value attribute, page never
  names wake fence fields). Confirmed RED pre-implementation.
- Panel implemented in webui/palwarden.html per D1-D8: full-width indigo
  card after Jobs; pw-btn/input CSS copied from backups.html conventions
  (tokens only, no raw colours); pure collectOpsSettings/wakeParams;
  opsToken/postJob/pollJob conventions from backups.html with the SAME
  sessionStorage key; scoped setOpsBusy (#ops-form + #ops-actions only);
  status pill + inline status line + card job log, all textContent; help
  <details> covers defaults, first-attempt retry, open doorbell, token
  limits, partial save + last-write-wins, immediate effect, persistence.
- NEW tests/unit/test_webui_panel.sh — jsdom tier: fetches the ACTUALLY
  SERVED /palwarden.html from a real palwarden-webui (stub-sbin harness like
  test_webui_jobs.sh), runs it with runScripts=dangerously, bridges fetch
  (adds Basic session + volunteers Origin/Sec-Fetch-Site like a real
  same-origin browser fetch; records every request; can drop the CSRF header
  to exercise 403), fake worker completes jobs by rewriting queue files and
  APPLIES palwarden_config_save exactly like jobd (ops.resolve/merge/
  write_config at execution time). Eight phases / ~35 behavioural checks:
  load (never preloads the secret), edit-all-five save → PUT carries exactly
  the changed typed keys + CSRF header → job success → form reloads effective
  values + file updated + GET never echoes the token; keep-by-omission;
  failed job → ERROR + exit code + worker output, no success text, typed
  value kept; explicit clear → exactly {"KNOCK_TOKEN":""} → file loses token;
  busy wake → 409 refusal rendered, nothing queued; admitted wake (idle
  lifecycle) → server-minted fence in queued params → OK; dropped CSRF
  header → 403 → error + cached token dropped; out-of-range → server 400
  rendered verbatim, nothing queued.
- Test-harness lessons recorded the hard way: ops file format is
  JSON-QUOTED values (ops.parse_file); the OK pill is set BEFORE the
  post-save reload, so waits must key on the final status line + reloaded
  field + re-enabled controls or fillOpsForm clobbers the next phase;
  assert_report does NOT exit (skip is a branch, never an early report);
  the jsdom availability gate must resolve from the same directory the run
  resolves from (node's upward node_modules walk made gate and run disagree
  when $WORK sat under a directory containing node_modules).
- Verification: test_webui_jobs.sh 179/0; test_webui_server.sh 79/0;
  test_webui_backups.sh 242/0; test_webui_panel.sh 3/0 with jsdom, 2/0 +
  honest skip message without (TMPDIR=/tmp proof); ./tests/run.sh — see
  below. shellcheck unavailable on this host (tests/lint.sh SKIPs it; CI's
  pinned image runs it).
- Browser tier honesty: jsdom is not a real browser engine; chromium/
  playwright unavailable on this host → REAL-BROWSER VERIFICATION IS
  BLOCKED, not complete (plan step 5's own instruction). The jsdom tier is
  the strongest tier that executes the actually-served page here.
  UPDATE (same day, later session): the served page WAS subsequently driven
  in real Chromium via the Orca agentic browser (headless runtime): load,
  real fill/click edits of all five settings, save round-trip with job
  polling and effective-value reload, keep/replace token, busy-wake 409
  refusal rendered verbatim, token absent from the DOM, zero console
  errors, correct accessibility roles/labels. Remaining blocked slice:
  pixel screenshots (the headless runtime has no display server and returns
  blank captures) — visual layout remains unverified; see checkpoint
  "TASK 9 ADDENDUM". Lint debt from Tasks 1-8 was also cleared this session
  (shellcheck v0.10.0 host install; ./tests/lint.sh PASSED; affected suites
  re-run green: jobd 390/0, lifecycle_lock 49/0, palwarden_config 92/0,
  enrollment 22/0, knock 121/0).
  FINAL UPDATE: the pixel slice is CLOSED too — Debian chromium 155
  (--headless=new, driven by puppeteer-core from scratch) captured and
  asserted the panel's default/OK/ERROR/dark states with layout checks
  (no overflow, real control geometry, zero uncaught JS errors):
  VISUAL-OK; evidence at scratch/chromium-panel-*.png. Task 9 verification
  is complete on every tier the plan demanded; nothing left blocked.

### Task 10 — Image, persistent state, and s6 wiring (spec §7.1-7.2)

**Files:** Dockerfile, entrypoint, compose, env example, two new s6 trios.

1. Install Python modules using existing lib layout and scripts 0755; include
   SPDX headers. Verify imports in dev, image, and installer dry-run layouts.
2. Precreate root-owned ops directory 0750 with steam group and declare new
   `palwarden-ops` volume mounted there. Set image/Compose PALWARDEN_OPS_FILE
   to its config path; default cooldown is beside it. No recursive volume chown.
3. Add five environment seeds with explicit defaults. An absent config always
   gets all five validated values; existing config is untouched. Call the shared
   renderer, not a second bash serializer. Handle absent/invalid group/file
   shapes with actionable failures rather than chmod/chown through symlinks.
4. Always enable both helper services in embedded mode; neither in external.
   `idle-watch/run` execs `/usr/local/sbin/palworld-idle-watch --loop`;
   `palworld-knock/run` execs `/usr/local/sbin/palworld-knock`.
   Use existing longrun/type/timeout conventions and explain root s6 control.
5. Document seeds as seeds, default idle off/knock on, dedicated volume,
   supported internal 8211 vs host mapping, and no baked tokens.

**Verify:** `./tests/run.sh`; `./install.sh --dry-run`; Docker acceptance below.

### Task 10 status (implemented 2026-10-23, TDD)

- Design decisions recorded before implementing: D1 seed through the module
  (`python3 -m palwarden_ops seed` — the entrypoint never re-serializes the
  five keys in bash, spec §7.1); D2 ops dir root:steam 0750 (webui-as-steam
  reads the 0640 file through the group); D3 root-first boot steps in the
  entrypoint (seed + `python3 -m palwarden_lifecycle init-runtime`, plan
  Task-2 finding F3); D4 two root longruns mirroring memory-watch/jobd
  conventions, embedded-only, enablement deliberately NOT a service gate;
  D5 invalid seeds/invalid existing file fail the boot visibly (fail closed).
- RED: test_palwarden_config.sh section I (15 assertions on the seed CLI:
  complete canonical default file, seeds as inert JSON data, existing file
  never re-rendered, invalid seed -> no file + named key, invalid existing
  file byte-identical, symlink refusal, usage 64). Pre-impl 9 failures.
  GREEN 107/0.
- New: docker/s6-rc.d/palworld-knock + idle-watch trios (longrun,
  timeout-kill 3000, root, documented). entrypoint.sh: ops-dir shape guard
  (no chmod/chown through unvalidated paths), seed-if-absent, init-runtime,
  enable both services embedded-only. Dockerfile: PYTHONPATH=/usr/local/lib
  (Debian python3 does not search it; the -m invocations need it),
  PALWARDEN_OPS_FILE on the volume, ops dir root:steam 0750, chmod list.
  compose.yaml: five seeds + PALWARDEN_OPS_FILE + palwarden-ops volume
  (embedded only). .env.example + README: seeds-as-seeds, idle off/knock on,
  volume reset semantics, internal 8211 vs host mapping, no baked tokens.
- Integration smoke assertions added to test_docker.sh scenarios A and C
  (services supervised embedded / absent external; ops file/dir ownership
  and mode; lifecycle state present). Full scenarios remain Task 11.
- Checks (umask 022, executed): full ./tests/run.sh ALL SUITES PASSED
  (36 suites; scratch task10-unit-r2.log — one test_knock.sh EADDRINUSE
  flake under load passed 121/0 standalone and on the clean re-run);
  ./tests/lint.sh PASSED (one SC2086 in the new run_cli pinned with a
  documented disable; lesson: comments must not sit inside a backslash
  continuation — they swallow the joined command); ./install.sh --dry-run
  exit 0; install.sh already ships lib/* to /usr/local/lib (line 72) so all
  three import layouts work.
- Docker tier (docker 26.1.5 + compose 2.26.1 installed on this host
  2026-10-23; previously absent — earlier sessions could not run it):
  RUN_INTEGRATION=1 ./tests/run.sh — test_docker.sh 134/0 (incl. the new
  Task 10 assertions: helpers supervised embedded / absent external, ops
  file root:steam 0640, ops dir root:steam 0750, lifecycle state present),
  test_persistence.sh 32/0 (compose plugin installed after the first run
  skipped it), test_update_apply.sh 12/0. Scratch task10-integration-r2.log.
- test_knock.sh EADDRINUSE flake ROOT-CAUSED and FIXED (harness, not
  implementation): the token-edit wake runs INLINE in _lease; its stub
  `start` sets the fake service `up`, and under load it landed AFTER the
  EADDRINUSE section's reset_world — a permanent `stopping` the listener
  correctly refuses to arm through (no deadline could rescue it). Fix:
  baseline api.log before the token-edit knock and wait for the readiness
  poll's api.log line (which lands after the stub's start) before
  reset_world; EADDRINUSE waits also widened 6s->15s for headroom. New
  completion assertion included; 122/0 x3 standalone.

### Task 11 — Separate isolated Docker acceptance scenarios (spec §9)

**Files:** `tests/integration/test_docker.sh`; reuse inspected fake game and REST
fixtures. Use disposable project/container/volume names; never production names.

1. **Defaults:** fresh image + fresh volumes -> complete default ops file exists,
   idle off, knock on, correct ownership/permissions. No contradictory no-file
   expectation. Confirm external mode starts neither helper.
2. **Idle/wake:** seed timeout=1 minute; boot fake game whose actual UDP bind
   conflicts with the helper, and a schema-correct REST stub. Keep successful
   empty sampling running. First assert no premature stop. Wait with a bounded
   deadline until BOTH real service uptime and observed-empty duration cover
   the minute; run/wait for the tick, assert s6 down and idle marker. Send UDP
   to the published host port; assert one start, REST ready, wake marker, and
   game owns the socket. Merely aging identity rows is not sufficient.
3. **Stale occupied evidence:** halt/fail presence sampling while info remains
   healthy; even with old identity rows and sufficient uptime, assert no stop.
4. **Maintenance/races:** barrier the update/restore/restart stopped window under
   ownership; UDP must not bind or wake. Concurrent supported manual start must
   wait for socket release. Crash wanted-up state must not arm knock.
   Submit API wakes during a long serial jobd maintenance job (409), and queue a
   wake before direct maintenance (execution rejects its changed generation).
   Test expiry and interrupted-maintenance refusal as separate cases.
5. **Persistence:** save browser/API edits including a synthetic token; record
   config and cooldown. Run `docker compose -p "$fixture_project" -f
   "$fixture_compose" up -d --force-recreate` against the isolated fixture,
   with the SAME ops volume and changed env seeds; compare preserved bytes/
   permissions and effective settings. A simple
   restart is not this test. Fresh-volume reset is a separate explicit case.
6. **Live configuration:** exercise enable/disable/token/cooldown and idle
   interval/timeout edits in the running container without service/container
   restart. Verify private job payload handling and all public redactions.

**Verify:** `RUN_INTEGRATION=1 ./tests/run.sh`. Confirm Docker scenarios actually
ran: the runner may print a skip and still exit zero if Docker is unavailable.
Record any unavailable required test as blocked, not accepted.

### Task 11 status (implemented 2026-10-23, TDD across 10 runs)

- New `tests/integration/test_idle_knock.sh` (isolated `pw-it11-*` names,
  per-run ops volume + compose fixture, cleanup trap). Scenario 1 (defaults)
  stays covered by test_docker.sh's Task-10 assertions; scenarios 2-6 here.
  Fixtures upgraded: fake game REALLY binds UDP 8211 (SO_REUSEADDR, like the
  real binary) so port handoff is observable; rest-stub serves schema-correct
  /v1/api/players with PALWORLD_STUB_PLAYERS=0 = positive empty evidence.
  Suite fails fast if the fixture dir carries SteamCMD debris (run 2 installed
  the REAL game into the bind mount by omitting UPDATE_ON_START=false and
  destroyed the fixture; restored from git).
- Scenario coverage as planned: (2) real-eligibility idle stop (no premature
  stop at 20s; bounded wait on genuinely elapsed uptime+empty; s6 down +
  idle marker; host-port UDP wake; game re-owns socket; wake logged);
  (3) sampler frozen + info healthy -> one-shot tick refuses on stale
  evidence (loop frozen via FULL /run/service path; one-shot tick reads a
  temp ops file; real ops file then raised to 999 so the loop can't re-stop
  mid-suite); (4a-g) 409 wake behind queued disruptive job (idle re-
  established first so the blocker is the only cause; body names it),
  crash-backoff refusal, maintenance-window UDP inert, manual start blocks
  on the lock (measured >=3s), unsafe-marker refusal + acknowledge,
  crafted expired and changed-generation job files refused by the worker
  fence (crafted files must be chowned to the queue owner — root-owned 600
  is unreadable = "not a job"); (5) compose --force-recreate with SAME ops
  volume + CHANGED seeds -> byte-identical config, mode preserved, saved
  values beat seeds; fresh-volume reset separate; (6) live enable/disable/
  token/idle-interval edits with service pids unchanged, token scrubbed
  from completed job files, absent from GET /api/palwarden-config
  (token_configured:true only) and container logs.
- **FOUR PRODUCTION BUGS FOUND (the point of the task), all fixed with unit
  regressions:** (1) `<svcdir>/down` wanted-down marker is NOT created by
  s6-svc -d (measured s6-overlay v3) -> every stopped service read as
  crash-backoff, knock could never arm, idle-watch hung 120s holding the
  lifecycle lock; stop paths now maintain the marker, start paths clear it,
  entrypoint clears at boot (test_systemctl_shim pins it). (2)
  `_start_service` cleared CLOEXEC but omitted pass_fds=(fd,) — subprocess
  close_fds=True closes the lock fd in the child anyway; every real wake
  died at the shim's borrow check. Unit assertion upgraded from "env var
  visible" to "descriptor LIVE in the starter" (/proc/self/fd). (3) Unfenced
  wakes (UDP knock, manual wake) skipped the lifecycle-status check ->
  start_if_down now requires confirmed idle (spec §4.4 unsafe inhibition
  covers automatic wake). (4) start_if_down sampled service_state() once
  right after the starter returned; s6-svc -u returns before supervise
  spawns -> false "start issued but the service is not running"; now polls
  up to PALWARDEN_WAKE_START_TIMEOUT_S (10s default), unit stub models the
  delayed flip.
- Harness lessons: s6-svc needs full service-dir paths (bare names =
  relative paths); ss reports the knock daemon's comm as "python3" -> holder
  checks match the s6-svcstat PID, not names; the lease gap (~0.15s port
  closed by design) drops single datagrams -> tests ring like real clients;
  job terminal states are succeeded/failed; disruptive jobs need
  params.confirm:true; docker exec is root -> queue files need chown;
  pretty-printed JSON broke head -1 assertions; cooldown file must be
  cleared to isolate verdicts from scenario-2's 600s cooldown.
- Evidence (umask 022): standalone suite 45 passed / 0 failed
  (task11-run10.log); knock unit 127/0 x2 stress; full ./tests/run.sh
  ALL SUITES PASSED (task11-unit-r10.log); lint PASSED (pinned container).
  **FINAL VERIFY: RUN_INTEGRATION=1 ./tests/run.sh — ALL SUITES PASSED,
  40/40 suites with NO skips: 36 unit + test_docker 134/0,
  test_idle_knock 45/0, test_persistence 32/0, test_update_apply 12/0
  (task11-full-integration.log). Task 11 COMPLETE.**

### Task 12 — Documentation, disposable real-game gate, and handoff

**Files:** architecture/tools/service runbook/docker README/env example;
existing disposable live test infrastructure after inspecting its safety guards.

1. Document both scripts, config format/resolution, actual panel/API contracts,
   lifecycle protocol/order/bypass boundaries, 60-second freshness requirement,
   token replay limitations, ports, volume reset, error recovery, and remaining
   join race. Use the existing service runbook, not a new docs/runbook.md.
2. Explain manual administrative start overrides cooldown, but ordinary
   `palworld-knock wake` and API wake respect it. Never advise root raw s6
   commands as a safe concurrent maintenance procedure.
3. Run unit and Docker suites and optional-notify checks. Test Python notify
   absence/failure independently of the bash grep-based invariant. Review
   licensing and verify no unrelated files changed.
4. On an explicitly authorized disposable real-game testbed, verify real UDP
   ownership, consumed initial attempt/retry, world save after idle stop, and
   restart from that save. Follow existing live-tier guards; do not target the
   production server. If a real client/save test cannot run, explicitly record
   it unverified and do not call real-client acceptance complete.
5. Keep idle off on upgrade; enable only after checking healthy observation
   state. Rollback: disable idle/knock, preserve ops volume and saves, revert
   image if necessary. Do not remove a named volume as routine rollback.
6. Cross-check every spec §9 checkbox against recorded evidence. Report changed
   files, real RED/GREEN and regression commands, Docker/browser/live results,
   remaining blockers, and known operational limitations. No automatic commits.

Task 12 status — COMPLETE 2026-10-24 (all six items; evidence below).

- Docs (items 1, 2, 5): runbook §17 "Idle shutdown and knock wake" (config
 table + file->env->default resolution, positive-evidence model with the
 fixed 60s freshness bound, cooldown semantics — UDP/CLI/API wakes respect
 it, an administrative start is the deliberate override, raw `s6-svc` never
 recommended — lifecycle lock protocol and bypass boundaries, ports, token
 replay caveats, error recovery, upgrade (idle off) / rollback (never remove
 the ops volume), the remaining join race, container-only supervision note);
 `tools.md` (lifecycle-lock intro, `palworld-knock` + `palworld-idle-watch`
 entries, `/api/palwarden-config`, `palwarden_config_save`/`server_wake`
 actions, live-suite row); `architecture.md` (lock + state.json fence,
 idle/knock services, concurrency bullet); `docker/README.md` (cooldown +
 freshness paragraph, "Upgrading and rolling back").
- Suites (item 3): `./tests/run.sh` ALL PASSED; `RUN_INTEGRATION=1
 ./tests/run.sh` ALL PASSED (task12-full-integration-final.log);
 `./tests/lint.sh` PASSED. Python notify-ABSENCE cases added to
 `test_knock.sh`/`test_idle_watch.sh` (spec §6.3 wanted Python behavior
 tested separately from the bash grep invariant — failure was covered,
 absence now is too). SPDX audit of all 48 changed code paths: one gap
 (`test_lifecycle_lock.sh`), header added; s6 metadata/fixture files
 conventionally carry none. All 57 changed paths are feature-scoped.
- Live gate (item 4): testbed `$HOME/palworld-testbed` (marked, uid 1000),
 real game installed via the documented one-time command — which FAILED
 first: `compose.live.yaml` pinned `UPDATE_ON_START` as a literal `"false"`,
 beating the documented command's interpolation (a later `-f` file's literal
 env value wins). Fixed to `${UPDATE_ON_START:-false}`. New
 `tests/live/test_idle_knock.sh` GREEN 25/0 (r3): UDP 8211 held by the
 running game, released to the listener on the real idle stop, reclaimed by
 the woken game; idle enabled through the panel API (token never
 serialized); real eligibility fired; cooldown stamped before start; first
 knock woke; retry inside the cooldown refused and logged as a no-op;
 post-cooldown knock woke onto the SAME world (directory comparison + nonce
 marker + REST ready). Harness lessons: the config endpoint returns native
 JSON types; `docker compose port` rejects `/udp`; the daemon logs "wake
 started" only after its readiness poll, so assert after readiness.
- §9 cross-check (item 6): every checkbox now carries evidence in the spec
 file; the two live-only lines are covered by the r3 run above. No
 production restarts; the testbed is disposable and its config was restored
 to defaults by the suite.

## 4. Completion gate and scope warning

Documentation-revision baseline: `./tests/run.sh` was exercised without source
changes. The restore-apply suite failed because its scratch-ancestry guard
rejects `/home/hermes/.hermes/cache` at mode 0775 in this execution environment;
the other suites passed. Before implementation, establish a trustworthy test
scratch ancestry within the permitted workspace and rerun the baseline. Do not
weaken the restore guard or silently change shared directory permissions to
obtain a green result. This baseline is not a failure of the proposed feature,
which is not implemented, and is not an acceptance pass.

Baseline verified 2026-10-18, before Task 1: (a) this environment's
`/home/hermes/.hermes/profiles/code64/cache` was tightened 0775 -> 0700, a
deliberate and reported hardening inside the permitted profile workspace
(matching its 0700 `code64`/`scratch` siblings); the restore guard itself is
unchanged. (b) With `umask 022`, `./tests/run.sh` is fully green
("ALL SUITES PASSED"; log
`~/.hermes/profiles/code64/cache/scratch/palwarden-baseline-unit-umask022.log`).
Known environment sensitivity (pre-existing, not Task 1):
`test_restore_apply.sh` is umask-dependent — under umask 002 the harness
`mkdir`s a 0775 `backups/` dir and the ancestry guard (correctly) refuses it
before the intended "scratch inside the backups directory" guard, failing one
message assertion. Follow-up candidate, not Task 1: pin `umask 022` in
`tests/run.sh` or the harness so the suite does not depend on ambient umask.

Task 1 status (implemented 2026-10-18, TDD):
- RED: `tests/unit/test_palwarden_config.sh` written first; failed cleanly
  with `ModuleNotFoundError: No module named 'palwarden_ops'` (51 trivial
  pass / 41 fail on the expect_err cases, as expected pre-module).
- GREEN: `lib/palwarden_ops.py` implemented (AGPL header, schema
  IDLE_TIMEOUT/IDLE_CHECK_INTERVAL/KNOCK_ENABLED/KNOCK_COOLDOWN/KNOCK_TOKEN,
  canonical JSON-quoted data file, atomic 0640 writer with symlink/FIFO
  refusal, file->env->built-in resolution, fail-closed invalid-file handling,
  partial merge with token omitted=keep / empty=clear, public_view with
  token_configured, seed_if_absent).
- Verification (umask 022): standalone `bash tests/unit/test_palwarden_config.sh`
  = 92 passed, 0 failed, with the root-only foreign-group chown assertion
  reported UNAVAILABLE (not passed) under the non-root harness. Full
  `./tests/run.sh` = all suites green (log
  `~/.hermes/profiles/code64/cache/scratch/palwarden-task1-unit.log`).
- Synthetic token fixtures only; no real credentials read or printed.
- Open note for Task 10 wiring: `install.sh` does not install `lib/` (it
  copies `sbin/` and `systemd/`); the container gets it via `COPY . /app`.
  Bare-metal users need the ops module on `PYTHONPATH`/importable location —
  decide the install path in Task 10/11, do not change install.sh yet.
- Review gate: independent spec/plan review was done via isolated read-only
  scout before implementation; Task 1 implementation itself is not yet
  independently reviewed (self-review only). A fresh review of the Task 1
  diff is recommended before Task 3 enrollment depends on these helpers.

The required concurrency fix deliberately expands the old plan beyond two
standalone scripts. Locking only the new helpers would leave update/restore
windows unsafe. Do not remove controller enrollment or replace socket handoff
with optimistic polling to make the patch smaller.

All spec acceptance items must have evidence or an explicit blocker. A passing
unit suite does not prove real-game saving, network retry behavior, browser
operation, or container recreation persistence. Stop and resolve any impossible
contract discovered during implementation instead of quietly weakening it.
