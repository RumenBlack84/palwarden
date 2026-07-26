# palwarden in Docker

An **all-in-one image** for Palworld: one artifact that can either **run the
dedicated server itself** (self-contained) or **manage/monitor an existing
server** elsewhere. Which role it plays is chosen at runtime, not at build time.

> **Status — increment 3:** **external mode is now functional for telemetry.**
> Under s6, the embedded container runs the server + config web UI, and — in
> either mode, when `ADMIN_PASSWORD` is set — the **FPS/player telemetry
> sampler**. Remaining background jobs (update-check, memory watchdog,
> public-info watcher, daily report) need the systemctl/cgroup host-isms
> abstracted and land in the next increment. See
> [`../docs/docker-roadmap.md`](../docs/docker-roadmap.md).

## Process model

`s6-overlay` is PID 1 (as root) and supervises the workloads; **every workload
runs unprivileged as `steam`** (uid/gid 1000). Which services run is decided at
start by the entrypoint from `PALWARDEN_MODE` + config:

| Service | embedded | external | Needs |
|---------|:---:|:---:|-------|
| `palworld-server` | ✅ | — | game volume |
| `config-webui` | ✅ | — | — |
| `fps-sample` (telemetry) | ✅ | ✅ | `ADMIN_PASSWORD` + reachable REST API |

On stop, s6 receives SIGTERM and the server service forwards **SIGINT** to the
game so it saves (within the 120s grace).

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
start — **never baked into the image**. For **embedded**, the server's own
`PalWorldSettings.ini` must also enable the REST API with the *same* password
(server-config rendering lands in a later increment); until then, embedded
telemetry records "error" rows until the API is reachable.

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
