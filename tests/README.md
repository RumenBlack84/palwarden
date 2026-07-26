# Tests

Dependency-free test suites for palwarden.

```bash
./tests/run.sh                 # unit tests only (fast, no docker)
./tests/run.sh --integration   # unit + docker integration tests
RUN_INTEGRATION=1 ./tests/run.sh
```

## Layout

- `lib/assert.sh` — minimal assertion helpers (no external deps).
- `unit/` — fast tests for individual scripts:
  - `test_sudo_shim.sh` — the container `sudo` passthrough.
  - `test_systemctl_shim.sh` — the `systemctl`→s6/cgroup shim (fakes `s6-svstat`/
    `s6-svc` and the cgroup file).
  - `test_render_config.sh` — env → `settings.env`/`notify.env` rendering,
    verified by sourcing the output (spaces and shell metacharacters must survive).
- `integration/test_docker.sh` — builds the image and exercises real container
  scenarios: mode-based service selection, the systemctl shim, env-driven config
  application (`RESTAPIEnabled=True`), external-mode telemetry against a REST
  stub, container-native graceful restart, and graceful save-on-stop.
- `fixtures/` — a fake server (`fake-server/`, whose "binary" saves on SIGINT)
  and a Palworld REST API stub (`rest-stub.py`).

## What is and isn't covered

Unit tests cover the container-only glue (shims, config rendering) with no
dependencies. Integration tests cover container behavior end-to-end using a
dummy server — they do **not** download or run the real Palworld server, so the
real SteamCMD install/boot path and the third-party config parser's edits are
exercised only against fixtures. A real embedded boot remains a manual check.

## Adding tests

Unit tests: create `unit/test_*.sh`, `source ../lib/assert.sh`, assert, and end
with `assert_report`. The runner discovers them automatically.
