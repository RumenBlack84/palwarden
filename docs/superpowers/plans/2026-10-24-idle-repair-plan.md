# Idle-Shutdown/Knock-Wake Repair Plan (F1-F10)

Date: 2026-10-24
Author: code64 session
Source findings: `2026-10-24-idle-shutdown-knock-wake-review-follow-ups.md`
Spec: `../specs/2026-10-18-idle-shutdown-knock-wake.md` (§4.1, §4.4, §5, §6, §7)
Status: DRAFT — pending independent review against spec + repository.

All line refs verified against the current working tree (master, b49b3cb +
uncommitted feature). Every repair below is spec conformance; no new contracts
are invented.

## Batch 1 — lifecycle protocol (F1, F2, F6, F7) — ONE protocol, tested together

### 1a. Sticky unsafe + owner-only writes (F2 core) — `lib/palwarden_lifecycle.py`

- `write_state()` (462): if current status is `unsafe`, refuse any write of
  `active`/`idle` by raising a new `UnsafeMaintenanceError(LifecycleError)`,
  unless `force=True`. `unsafe`->`unsafe` always allowed (escalation).
  `acknowledge_maintenance()` passes `force=True` (927).
- Rationale: spec §4.4 "do not clear it merely because flock became available".

### 1b. Acquire bridge publishes outer-transaction state (F1) — `lib/palwarden_lifecycle.py` + `lib/palwarden-lifecycle-bash`

REVISED (2026-10-24, pre-implementation): the original fork+wait supervisor
variant was dropped — `tests/unit/test_lifecycle_lock.sh` 4c pins the bridge
to exactly one process (`pgrep -fc == 1`), which fork+wait breaks. The
re-exec bridge is KEPT; completion marking moves to the owner script.

- `_cmd_acquire()` (817) with `-- command`: after `acquire()`, best-effort
  `write_state("active", rotate=True)` (warn on failure, never block the
  controller — feature-off usability); set `PALWARDEN_LIFECYCLE_TXN=1` in
  the exec env alongside `ownership_env(fd)`; exec as today. If `execvpe`
  fails: best-effort `write_state("unsafe")`, release, exit 72.
- `palworld_lifecycle_maybe_acquire` (re-exec'd owner pass: FD_ENV valid
  AND TXN=1): register `trap 'python3 -m palwarden_lifecycle complete "$?"
  ... || true' EXIT`, then UNSET TXN so nested child controllers (which
  inherit FD_ENV) never mark completion for the outer owner. New CLI
  subcommand `complete <rc>`: rc 0 -> `write_state("idle")`, else
  `write_state("unsafe")`; best-effort, sticky-unsafe-safe, never alters
  the controller's exit code.
- Borrowed invocations (FD_ENV valid, TXN unset — idle-watch's
  graceful-stop, `_start_service`'s systemctl child, jobd-passed steps)
  register nothing and write nothing (nested preservation).
- `acquire` WITHOUT a command (socket-lease use) writes no state — leases
  never rotate (spec §4.4).
- Known accepted limits (document in module docstring + runbook): a
  controller killed by SIGKILL (or an unguarded TERM that skips the EXIT
  trap) leaves status `active` — wake stays suppressed until explicit ack
  (fail closed); a `systemctl stop` that exits nonzero (e.g.
  already-stopped) marks `unsafe` — fail-closed per spec "failures only
  when service/data state is known safe".
- Consumers unchanged: graceful-stop/restart/update + systemctl shim all
  go through `palworld_lifecycle_maybe_acquire` -> this bridge; none of
  them define their own EXIT trap or exec-replace (verified).

### 1c. jobd ownership-aware marking (F2) — `sbin/palwarden-jobd`

- `run_job()` (1582): for wrapped `DISRUPTIVE_OPERATIONS` EXCEPT
  `backup_restore`, try `lc.acquire(timeout=0)` around `_execute_job`:
  - owner: mark `active`+rotate (best-effort; sticky-unsafe warns and
    persists), pass ownership to steps via `ownership_env(fd)` +
    `pass_fds` in `_run_step` (1301, Popen gains `env`/`pass_fds` args),
    mark `idle`/`unsafe` on completion, release;
  - busy: run WITHOUT any state write (a concurrent direct transaction keeps
    its state; the step's own controller acquisition fails visibly).
- `backup_restore` excluded from jobd wrapping: `palworld-restore` takes the
  lifecycle lock AFTER releasing the backup lock (restore docstring ~1843);
  wrapping in jobd would invert the spec's lock order (§4.1). Restore
  publishes its own state via 1d.
- `reap_orphans()` keeps marking `unsafe` (escalation; interrupted
  maintenance must fence).
- `_wake_fence_refusal` unchanged (admission + execution-time fence already
  correct; generation rotation by owners now makes it effective).

### 1d. Restore borrows instead of re-acquiring (F6) + publishes state — `sbin/palworld-restore`

- `restore_archive()` (1872): first `lifecycle.ownership_from_env()`;
  borrowed -> reuse fd, `_lifecycle_owned=False`, no state writes;
  else acquire as today, `_lifecycle_owned=True`, then
  `write_state("active", "restore", rotate=True)` best-effort.
- finally (1995-2012): release only when owned; borrowed -> never
  `release()`/LOCK_UN (outer owner keeps ownership).
- On completion when owned: `idle` on success, `unsafe` on failure paths
  after acquisition (best-effort, sticky-safe).
- Subprocess handoff (505-514) unchanged — works for owned and borrowed fd.

### 1e. Acknowledgement requires wanted-down (F7) — `lib/palwarden_lifecycle.py`

- `acknowledge_maintenance()` (927): replace the raw
  `systemctl is-active == "inactive"` check with `service_state()`;
  accept ONLY `"stopped"` (container: down + wanted-down marker; systemd:
  inactive + disabled). `crash-backoff`, `starting`, `stopping`, `running`,
  `unknown`, `no-supervisor` -> refuse, marker/generation untouched.
  Never starts the game. Root + `--confirm` guards unchanged.

### Batch 1 RED tests (add to `tests/unit/test_lifecycle_lock.sh`, real
flock + fifo coordination per file idiom; systemctl/s6 stubs per case):

1. direct `palworld-graceful-stop` under bridge: generation rotates, status
   `active` observed mid-run (fifo), `idle` after success; an admitted wake
   (generation+expiry) is refused after the stop starts.
2. bridge child killed (SIGKILL at step fifo): status `unsafe`; wake refused;
   ack required.
3. `update_check`/`api_save` success with pre-set `unsafe`: marker preserved
   (jobd busy/owner paths both covered).
4. jobd wrapped job while an external flock holder owns the lock: jobd writes
   no state; holder's `active` survives job completion.
5. nested: outer owner (fd via env) runs `palworld-restore` (storage stubbed
   like the reviewer probe) -> proceeds without 600s wait; competitor still
   excluded after nested return; borrowed cleanup does not unlock outer.
6. ack matrix with s6 fixture states: crash-backoff/starting/unknown refuse
   unchanged marker+generation; stopped+wanted-down succeeds without
   starting the game (root path exercised via the existing root-ack harness
   idiom; if unavailable in this environment, label explicitly).
7. feature-off: state dir unwritable -> bridge still runs the controller
   (warning only).

## Batch 2 — presence evidence (F3, F4, F5)

### 2a. Strict shared JSON parsing (F3) — `lib/palwarden_presence.py`

- New `parse_api_json(text)`: `json.loads(text, object_pairs_hook=...)`
  rejecting duplicate keys at ANY depth; result must be a dict (top-level
  arrays, trailing garbage, non-JSON -> `PresencePayloadError`).
- Replace `extract_json` in `sbin/palworld-idle-watch` (71) and
  `sbin/palworld-fps` (111) with the shared parser; `validate_players_payload`
  stays the schema gate after it. Other consumers of `extract_json` (fps
  `fetch_metrics`) keep working for well-formed objects.

### 2b. Policy revalidation before stop commit (F4) — `sbin/palworld-idle-watch`

- In `tick()` after final apply + eligibility recheck (355-361) and BEFORE
  `d["event"]/d["notify"]/d["stop"]`: re-read config; abort
  `abort final=config` if invalid, disabled, or timeout increased such that
  uptime/eligibility under the NEW timeout no longer holds (re-run
  `eligibility(new_timeout)` and the uptime gate). A stop already issued
  cannot be undone (spec §7.2).

### 2c. Sequenced failure application (F5) — `sbin/palworld-idle-watch`, `sbin/palworld-fps`

- idle-watch final-check failure paths (344-352): replace
  `presence.invalidate(con)` with `presence.apply_observation(con, seq,
  False, None, now_ms())` (fenced invalidate; superseded failures apply
  nothing). Keep `invalidate()` only for failures BEFORE reservation / DB
  unavailable (fail-closed, spec §5.1).
- fps (245): reserve a sequence before the pass where feasible and apply
  failures through `apply_observation(ok=False)`; pre-reservation failures
  keep `invalidate()`.
- No DB transaction spans HTTP (unchanged).

### Batch 2 RED tests (`test_player_presence.sh`, `test_idle_watch.sh`)

1. `[{\"players\":[]}]` and `{\"players\":[{\"playerId\":\"A\"}],\"players\":[]}`
   -> parse error, no stop, evidence invalidated; legitimate `{}`-shaped
   empty response still works; trailing garbage rejected.
2. final fetch blocked; config flips IDLE_TIMEOUT 1->0 (and 1->120) during
   fetch -> no stop issued; existing flip-before-acquire tests still pass.
3. older failure cannot erase newer success; newer failure fences older
   success; failed final check resets continuity (new full empty interval
   required); applied-sequence bookkeeping asserted.

## Batch 3 — operator correctness (F8, F9, F10)

### 3a. WebUI minutes (F8) — `webui/palwarden.html`

- Label (191) "Idle timeout (minutes)", help text "After this many minutes
  with the last player gone…", validation error (559) "whole number of
  minutes". Backend unit (minutes, 0..10080) and persisted values unchanged.
- Test (`test_webui_panel.sh` or jobs panel test idiom): rendered label/help
  contain "minutes", save round-trip posts the number unchanged.

### 3b. Notify adapter sources + invokes (F9) — `lib/palwarden_lifecycle.py`

- `_notify()` (678): run
  `bash -c 'source "$1" 2>/dev/null || exit 0; declare -F palworld_notify >/dev/null || exit 0; palworld_notify "$2" "$3"' _ kind text`
  — fixed code, argv-passed kind/message (no interpolation), bounded
  timeout, nonfatal on missing helper/function/failure. Shell metacharacters
  in messages stay literal.
- Test: function-only helper IS invoked (stub records argv); absence/failure
  nonfatal; `$(`, quotes, newlines in message arrive intact; idle/wake paths
  produce expected notification counts.

### 3c. Knock log bounds (F10) — `sbin/palworld-knock`

- Arming: keep per-lease `state["armed"]` reset, add cross-lease
  `state["was_armed"]`; log "listener armed" only on closed->armed
  transition (previous lease did not arm).
- Cooldown/no-op: `_handle_packet` (264-268) routes `already-running` /
  `cooldown` / `refused` through `_log_rate` (aggregated within LOG_RATE_S)
  instead of unthrottled `_log`.
- Tests (`test_knock.sh`): N consecutive quiet stopped leases -> exactly one
  arming line; repeated valid cooldown knocks -> bounded/aggregated lines,
  zero starts; tokens/payloads/addresses still absent; controller
  acquisition still succeeds under traffic.

## Verification order

1. Per-finding RED (fail for the right reason), then GREEN.
2. `bash tests/unit/test_lifecycle_lock.sh`, `test_idle_watch.sh`,
   `test_player_presence.sh`, `test_knock.sh`, `test_jobd.sh`,
   `test_restore_apply.sh`, `test_graceful_restart.sh`,
   `test_systemctl_shim.sh`, `test_notify_optional.sh`, webui tests.
3. `./tests/run.sh` full unit suite.
4. Docker acceptance (`RUN_INTEGRATION=1 ./tests/run.sh`) if the environment
   allows; otherwise record as NOT run (not a pass).
5. Record dispositions + command results in the follow-ups doc; independent
   review of the combined repair diff before declaring merge readiness.

## Explicit non-goals

- No wake-path redesign (start_if_down fencing stays as-is).
- No change to job API allowlist, config schema, or persisted units.
- No commits/pushes, no production restarts, no destructive recovery tests.
