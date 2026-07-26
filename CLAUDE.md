# CLAUDE.md

Guidance for AI agents (and humans) working in this repo.

## What this is

`palwarden` is operational tooling for a **Palworld dedicated server**. It runs
two ways from the same scripts:

- **Bare metal / VM** (systemd) — deployed by `install.sh` to real paths
  (`/usr/local/sbin`, `/etc/systemd/system`, …).
- **Docker (all-in-one)** — one image (`docker/`) that either runs the server
  itself (`PALWARDEN_MODE=embedded`) or manages an existing one
  (`PALWARDEN_MODE=external`), supervised by **s6-overlay**.

Start with `README.md`, `docs/architecture.md`, `docs/tools.md`, and
`docs/docker-roadmap.md`.

## Layout

| Dir | What |
|-----|------|
| `sbin/` | Operational commands (bash + python3). The real logic. |
| `lib/` | Sourced helpers (`palworld-notify`, config diff/summary). |
| `bin/` | `palworld-config-parser` — first-party Python tool that applies env vars to `PalWorldSettings.ini` (replaced a third-party binary). |
| `systemd/`, `needrestart/`, `config/` | Bare-metal units, hooks, config templates. |
| `webui/` | Third-party MIT config editors (keep `LICENSE.upstream-mit`). |
| `docker/` | Dockerfile, `compose.yaml`, entrypoint, `s6-rc.d/` services, shims. |
| `tests/` | `./tests/run.sh` (unit) / `--integration` (docker). |
| `docs/` | Architecture, per-tool reference, runbook, roadmap. |

## Core conventions

**Keep scripts host-portable.** The `sbin/` scripts run on bare metal *and* in
the container. Never hardcode container assumptions — gate them behind
environment variables with **bare-metal-preserving defaults**:

- `PALWORLD_USER`/`PALWORLD_GROUP` (default `palworld`; container `steam`)
- `PALWARDEN_CONTAINER=1` selects in-container branches (e.g. graceful
  restart/stop use `s6-svc` instead of systemd)
- `PALWORLD_STEAMCMD`, `PALWORLD_DROP_PRIV`, `PALWORLD_INSTALL_DIR`,
  `PALWORLD_CONFIG_FILE`, `PALWORLD_PUBLIC_INFO_FILE`, `PUBLIC_HOSTNAME`, …

Use `${VAR-default}` (not `${VAR:-default}`) when an explicit empty override must
be honored (see `palworld-update`'s `PALWORLD_DROP_PRIV`).

**Container host-isms** are handled by shims in `docker/shims/` (`systemctl`→s6,
`sudo`→passthrough), installed ahead on `PATH` in the image only. Prefer adding
to the shim over forking a script.

**Notifications are optional.** Every script that uses `palworld_notify` must
source the helper tolerantly and define a no-op fallback, or it dies with
"command not found" where the helper isn't installed:

```bash
source /usr/local/lib/palworld-notify 2>/dev/null || true
declare -F palworld_notify >/dev/null || palworld_notify() { :; }
```

`tests/unit/test_notify_optional.sh` enforces this as a repo invariant.

**Secrets** are never baked into the image or committed. `docker/entrypoint.sh`
renders `/etc/palworld/{settings,notify}.env` at start via
`palwarden-render-config` from env (`ADMIN_PASSWORD`, `DISCORD_WEBHOOK`,
`PALWORLD_CFG_<KEY>`). `.gitignore` blocks `settings.env`/`notify.env`/`*.sqlite3`
/keys.

**Licensing:** project is **AGPL-3.0**. First-party scripts carry
`SPDX-License-Identifier: AGPL-3.0-or-later` + `SPDX-FileCopyrightText: 2026
Brian Grant`. Do **not** stamp our copyright on the third-party `webui/` (MIT) or
the `bin/` parser (AGPL upstream); see `CREDITS.md`.

## Docker specifics

- `docker/s6-rc.d/<svc>/` = one service. The **entrypoint selects services at
  runtime** by writing markers into the s6 `user` bundle based on mode + config;
  markers are not baked in.
- The **server is supervised as the game binary directly** (entrypoint does
  PalServer.sh's steamclient.so prep), with `down-signal=SIGINT` so stop/restart
  save the world. Give slow saves room via `stop_grace_period`/`--time 120`.
- Jobs run as `steam` except `memory-watch`/`update-check`, which run as **root**
  (they control s6 services); those drop to steam for SteamCMD via
  `PALWORLD_DROP_PRIV`/`s6-setuidgid`.

## Testing (do this for every change)

```bash
./tests/run.sh                 # unit (fast, no docker)
RUN_INTEGRATION=1 ./tests/run.sh   # + builds image, runs container scenarios
```

Add unit tests under `tests/unit/test_*.sh` (source `tests/lib/assert.sh`, end
with `assert_report`). Make new script logic testable by parameterizing paths
via env (as the existing scripts do). Fixtures live in `tests/fixtures/`.

## Gotchas learned the hard way

- **Bash `trap` on TERM does not fire reliably under s6.** Don't rely on it for
  service shutdown — use the service's `down-signal`, or let default termination
  handle it (see `palwarden-run-periodic`).
- **`pkill -f <pattern>`** matches the invoking shell if its command line
  contains the pattern — avoid in tests; `pkill` skips its own pid but not a
  parent `sh -c '...pattern...'`.
- **Named-volume ownership**: pre-create paths in the image owned by `steam` so
  fresh volumes inherit it; never recursively `chown` a mounted volume at runtime
  (see runbook §11).
- **Config overwrite protection**: Palworld rewrites its own config on shutdown,
  so managed files are left `chattr +i`. Any write path must **unlock → write →
  relock** (see `lib/palworld-fileattr`, `palworld-config-apply-env`,
  `palworld-engine-config`). It needs e2fsprogs **and** `CAP_LINUX_IMMUTABLE`,
  which containers lack by default — so immutability must always degrade to a
  warning, never block the write. `subprocess.run(check=False)` does **not** catch
  a *missing* binary; you need `except FileNotFoundError/OSError`.
- **A `chattr +i` file blocks volume deletion.** `docker compose down -v` fails
  with "operation not permitted" while config is locked — unlock first (see
  `docker/README.md`). Tests that create locked files must clear the bit in their
  cleanup or they leak volumes.
- A **real embedded boot** (multi-GB SteamCMD download) has not been run E2E;
  increments were verified with dummy servers + a REST stub.

## Commits

SPDX headers on new scripts; clear messages; end with
`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Branch before
committing if on the default branch. Commit/push only when asked.
