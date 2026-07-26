# palwarden in Docker

An **all-in-one image** for Palworld: one artifact that can either **run the
dedicated server itself** (self-contained) or **manage/monitor an existing
server** elsewhere. Which role it plays is chosen at runtime, not at build time.

> **Status — increment 5:** the server is now **configured from the environment
> on boot** — `ADMIN_PASSWORD` enables the REST API and any `PALWORLD_CFG_<KEY>`
> is applied to `PalWorldSettings.ini` via `palworld-config-apply-env`, so
> embedded telemetry works out of the box with no hand-editing. Test suites
> (unit + docker integration) live in [`../tests/`](../tests/). Still deferred:
> `update-check` (in-container self-update) and `public-info-watch` — see
> [`../docs/docker-roadmap.md`](../docs/docker-roadmap.md).

## Process model

`s6-overlay` is PID 1 (as root) and supervises the services below. Workloads run
unprivileged as `steam` (uid/gid 1000) — except the memory watchdog, which runs
as root because restarting the server's s6 service requires it. Which services
run is decided at start by the entrypoint from `PALWARDEN_MODE` + config:

| Service | embedded | external | Runs as | Needs |
|---------|:---:|:---:|:---:|-------|
| `palworld-server` | ✅ | — | steam | game volume |
| `config-webui` | ✅ | — | steam | — |
| `fps-sample` (telemetry) | ✅ | ✅ | steam | `ADMIN_PASSWORD` + reachable REST API |
| `memory-watch` (watchdog) | ✅ | — | root | — |
| `daily-report` | ✅ | ✅ | steam | `DISCORD_WEBHOOK` |

The server binary is supervised directly, with the service's **`down-signal` set
to SIGINT** — so stop/restart (and container shutdown) tell Palworld to save its
world, matching the VM's `KillSignal=SIGINT`. A container-native
`palworld-graceful-restart` brings the service down (SIGINT save) and back up.

### Graceful shutdown (saves the world)

Stopping the container gracefully stops the **palworld-server** service first:
s6 sends it SIGINT, Palworld saves the world and exits, then the container
finishes shutting down. The server is given up to ~115s to save (its
`timeout-kill`), so **give the stop enough time**:

```bash
docker compose down        # uses stop_grace_period: 120s (recommended)
# or, for a raw container:
docker stop --time 120 palwarden
```

Plain `docker stop` (Docker's **10s** default) is only safe if the world saves
in under ~10s; for anything larger it may cut the save short. Compose is
configured with a 120s grace, so `docker compose down/stop` is the safe path.

### Host-ism shims

The tooling was written for a systemd host. Two shims (installed only in the
image, ahead of any real binary on PATH) let the scripts run unchanged:

- **`systemctl`** → s6/cgroup: `is-active`, `is-enabled`, `MemoryCurrent`/
  `MainPID`, `start`/`stop`/`restart` map to `s6-svc`/`s6-svstat`.
- **`sudo`** → passthrough (workloads already run as the owning user).

## The two modes

| | `embedded` | `external` |
|---|-----------|-----------|
| **Runs** | server + web UI + telemetry | telemetry only, targeting your server |
| **Game files** | Docker volume | none |
| **Toggle** | `COMPOSE_PROFILES=embedded` | `COMPOSE_PROFILES=external` + `PALWORLD_TARGET_HOST` |

Both come from the **same image**; the mode is a runtime env var.

## Credentials & notifications

The tooling talks to the Palworld REST API, which authenticates with
**`ADMIN_PASSWORD`** (HTTP Basic, user `admin`). Set it in `.env`:

- `ADMIN_PASSWORD` — enables telemetry/management. Blank ⇒ tooling disabled.
- `DISCORD_WEBHOOK` — optional, for notifications/reports.

Rendered to `/etc/palworld/{settings,notify}.env` (mode 0600, owned `steam`) at
start — **never baked into the image**. For **embedded**, setting
`ADMIN_PASSWORD` also **enables the REST API in the server's own
`PalWorldSettings.ini`** on boot (via `palworld-config-apply-env`), so telemetry
works with no hand-editing.

### Server settings (embedded)

Any `PALWORLD_CFG_<KEY>` env var is applied to `PalWorldSettings.ini` before the
server starts — e.g. `PALWORLD_CFG_SERVER_NAME`, `PALWORLD_CFG_MAX_PLAYERS`,
`PALWORLD_CFG_SERVER_PASSWORD`. See [`.env.example`](.env.example).

## Quick start — embedded (self-contained server)

```bash
cd docker
cp .env.example .env          # set ADMIN_PASSWORD (+ DISCORD_WEBHOOK) if wanted
COMPOSE_PROFILES=embedded docker compose up -d --build
docker compose logs -f palwarden
```

Players connect on `UDP 8211`; the config web UI is at
`http://127.0.0.1:8088/PalWorldSettingsEditor.html`. Stop gracefully with
`docker compose down` (server saves via SIGINT).

## Quick start — external (monitor an existing server)

```bash
cd docker
cp .env.example .env
#   PALWORLD_TARGET_HOST=<your server host/IP>
#   ADMIN_PASSWORD=<its REST admin password>
COMPOSE_PROFILES=external docker compose up -d --build
docker compose exec palwarden-external palworld-fps report --window 60m
```

The container samples the remote server's REST API on `FPS_SAMPLE_INTERVAL`
(default 15s) into a persistent `palwarden-state` volume. Your server must have
its REST API enabled and reachable by the container (private network / tunnel —
never the public Internet).

## Volumes

| Volume | Mounted at | Holds |
|--------|-----------|-------|
| `palworld-server` | `/opt/palworld/server` | Game install (embedded) |
| `palworld-saved` | `/opt/palworld/server/Pal/Saved` | Worlds + config (embedded) |
| `palwarden-state` | `/var/lib/palworld` | `metrics.sqlite3` telemetry (both modes) |

Bind mounts work too; match host ownership to `steam` (uid/gid **1000**).

## Security notes

- The REST API (`8212/tcp`) is **not** published to the host; the web UI is
  published to `127.0.0.1` only.
- Secrets are rendered at runtime from env; `.env`, `settings.env`, `notify.env`
  are git-ignored and never in the image.
- Workloads run non-root (`steam`); s6 is PID 1 root only to supervise.

## Configuration reference

`.env` (see [`.env.example`](.env.example)): `COMPOSE_PROFILES`,
`PALWARDEN_MODE`, `UPDATE_ON_START`, `PALWORLD_GAME_PORT`, `WEBUI_PORT`,
`ADMIN_PASSWORD`, `DISCORD_WEBHOOK`, `FPS_SAMPLE_INTERVAL`, `FPS_RETENTION_DAYS`,
`PALWORLD_TARGET_HOST`, `PALWORLD_REST_PORT`.

## Image internals

- Base `cm2network/steamcmd`; supervisor `s6-overlay` v3; services in
  [`s6-rc.d/`](s6-rc.d/) selected at runtime via the s6 `user` bundle.
- Periodic jobs use [`palwarden-run-periodic`](palwarden-run-periodic) (a small
  run-sleep loop) in place of systemd timers.
- The sampler reaches the API via `palworld-api`, which now honors
  `REST_API_HOST` (defaults to localhost, so bare-metal behavior is unchanged).
