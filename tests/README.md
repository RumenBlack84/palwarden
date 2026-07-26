# Tests

Dependency-free test suites for palwarden.

```bash
./tests/run.sh                 # unit tests only (fast, no docker)
./tests/run.sh --integration   # unit + docker integration tests
RUN_INTEGRATION=1 ./tests/run.sh
./tests/lint.sh                # shellcheck (via docker if not installed) + python
```

CI (`.github/workflows/ci.yml`) runs `lint.sh`, the unit tests, and the
integration tests as separate jobs on every push / PR.

## Layout

- `lib/assert.sh` — minimal assertion helpers (no external deps).
- `unit/` — fast tests for individual scripts:
  - `test_sudo_shim.sh` — the container `sudo` passthrough.
  - `test_systemctl_shim.sh` — the `systemctl`→s6/cgroup shim (fakes `s6-svstat`/
    `s6-svc` and the cgroup file).
  - `test_render_config.sh` — env → `settings.env`/`notify.env` rendering,
    verified by sourcing the output (spaces and shell metacharacters must survive).
  - `test_update_check.sh` — `palworld-update` buildid comparison + exit codes,
    with a fake SteamCMD and manifest (check paths only; no update applied).
  - `test_public_info.sh` — `palworld-public-info-watch` reads config / resolves
    IP / writes the join-info state file, with fake `curl`/`sudo`.
  - `test_notify_optional.sh` — Discord notifications are optional: asserts the
    repo invariant that every script sourcing `palworld-notify` also defines a
    no-op fallback, and that scripts still run when the helper isn't installed.
  - `test_memory_watch.sh` — the memory watchdog, including the regression that
    matters: a container at 97% of its memory limit must restart (judging against
    the host's RAM made it never fire), plus that the restart it invokes returns
    promptly when no REST API is configured.
  - `test_service_events.sh` — the crash/restart watchdog: baseline, no-change,
    unexpected vs planned restarts, outage/recovery, and the summary (incl. JSON
    and an empty DB).
  - `test_config_parser.sh` — `palworld-config-parser`: env→INI key resolution
    (including PascalCase quirks and the exceptions table), quoting/escaping,
    enum + boolean + numeric handling, rejection of structure-breaking values,
    secret redaction, idempotency, and a **systematic** check that every env var
    documented in `config/settings.env.example` resolves against the full 90-key
    fixture.
- `integration/test_docker.sh` — builds the image and exercises real container
  scenarios: mode-based service selection, the systemctl shim, env-driven config
  application (`RESTAPIEnabled=True`), external-mode telemetry against a REST
  stub, container-native graceful restart, and graceful save-on-stop.
- `integration/test_persistence.sh` — drives the real `docker/compose.yaml`
  (own project + ports) to prove `compose down` then `up` preserves the world and
  config: the nested `palworld-saved` submount holds the saves, `down` without
  `-v` keeps the volumes, and a second boot re-applies config cleanly.
- `integration/test_update_apply.sh` — simulates a new Steam build and drives the
  full `palworld-update` apply flow in-container (graceful stop → fake SteamCMD
  install → restart → event markers), plus the already-current no-op case.
- `fixtures/` — a fake server (`fake-server/`, whose "binary" saves on SIGINT), a
  REST-serving fake server for the update flow (`fake-server-rest/`), a fake
  SteamCMD (`fake-steamcmd`, reports `STUB_REMOTE_BUILDID` and "installs" by
  bumping the manifest), a Palworld REST API stub (`rest-stub.py`), and
  `PalWorldSettings.full.ini` — a realistic config with all 90 canonical keys
  (quoted strings, bools, numbers, bare enums, and a paren tuple).

## What is and isn't covered

Unit tests cover the first-party logic with no dependencies: the container glue
(shims, config rendering) and the config parser (against a full 90-key fixture).
Integration tests cover container behavior end-to-end using a dummy server — they
do **not** download or run the real Palworld server, so the real SteamCMD
install/boot path is exercised only by a manual embedded boot (last verified
against Palworld v1.0.1.100619: game installs, server boots, REST API healthy,
config applied, graceful save-on-stop, and config survives repeated restarts).

## Adding tests

Unit tests: create `unit/test_*.sh`, `source ../lib/assert.sh`, assert, and end
with `assert_report`. The runner discovers them automatically.
