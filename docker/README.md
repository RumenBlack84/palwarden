# palwarden in Docker

An **all-in-one image** for Palworld: one artifact that can either **run the
dedicated server itself** (self-contained) or **manage/monitor an existing
server** elsewhere. Which role it plays is chosen at runtime, not at build time.

Everything the bare-metal VM did now runs in the container: the server itself,
the config web UI, FPS/player telemetry, a memory watchdog, a daily Discord
report, and (opt-in) Steam auto-update plus a public join-info watcher. Verified
against a real server — see [`../tests/`](../tests/) for the suites and
[`../docs/docker-roadmap.md`](../docs/docker-roadmap.md) for how it got here.

## Process model

`s6-overlay` is PID 1 (as root) and supervises the services below. Workloads run
unprivileged as `steam` (uid/gid 1000) — except the memory watchdog, the update
checker, the job worker and the scheduled-backup tick, which run as root because
cycling the server's s6 service (or writing the root-owned backups directory)
requires it. Which services run is decided at start by the entrypoint
from `PALWARDEN_MODE` + config:

| Service | embedded | external | Runs as | Needs |
|---------|:---:|:---:|:---:|-------|
| `palworld-server` | ✅ | — | steam | game volume |
| `config-webui` | ✅ | — | steam | — |
| `jobd` (job worker) | ✅ | — | root | — |
| `fps-sample` (telemetry) | ✅ | ✅ | steam | `ADMIN_PASSWORD` + reachable REST API |
| `memory-watch` (watchdog) | ✅ | — | root | — |
| `daily-report` | ✅ | ✅ | steam | `DISCORD_WEBHOOK` |
| `update-check` (auto-update) | ✅ | — | root | `UPDATE_CHECK=true` |
| `public-info-watch` | ✅ | — | steam | `PUBLIC_HOSTNAME` |
| `service-events` (crash watchdog) | ✅ | — | steam | — |
| `backup-auto` (scheduled backups) | ✅ | — | root | — |

`backup-auto` is enabled on every embedded boot and is **not** gated on a
`BACKUP_*` variable: whether a backup actually happens is decided per tick by
`palworld-backups`, from `/etc/palworld/backup.env`. That is what lets the Backups
page switch scheduled backups off and on with nothing to restart. It runs as root
because `/opt/palworld/backups` is root-owned and the tool reads the whole world
tree. `BACKUP_TICK_SECONDS` (default 900) is the tick, not the backup interval.

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

### Does Palworld overwrite managed config?

Short answer: **it rewrites the files but preserves your values**, so palwarden
does not lock anything.

Measured against a real server (**v1.0.1.100619**, empty world, 4 restarts) with
both config files mutable: every custom value survived, all 119
`PalWorldSettings.ini` keys were retained, and the REST API kept answering — so
the server genuinely read and honoured the file. The game *does* normalise the
files once (`PalWorldSettings.ini` reformatted, `Engine.ini` expanded with
Unreal's own sections around our values), after which the contents are stable.

Two related quirks worth knowing:

* A config containing **only default values** is truncated to a single newline on
  first start — Unreal writes only non-defaults. Harmless, but it looks like your
  config was wiped.
* Because the game rewrites values in its own format, drift checks must compare
  *semantically* — `palworld-engine-config status --check` normalises both sides
  (so `True` == `1` and `60.000000` == `60`) instead of comparing raw text.

An earlier version of palwarden left these files immutable (`chattr +i`). That is
gone: it was unnecessary, needed `CAP_LINUX_IMMUTABLE` plus e2fsprogs, and an
immutable file blocks `docker compose down -v`.

### The web UI's privilege split

`config-webui` parses HTTP but has no privilege; `jobd` has root but no network
input. The web UI can only *write* a job file into `/var/lib/palworld/jobs`;
`jobd` re-validates it against its own allowlist and runs it. Both are enabled
together in embedded mode — with `jobd` down, queued actions simply never run.
See [`../docs/architecture.md`](../docs/architecture.md) for the boundary and
[`../docs/palworld-service-runbook.md`](../docs/palworld-service-runbook.md) for
recovery.

```bash
docker compose exec palwarden s6-svstat /run/service/jobd   # state + uptime
docker compose exec palwarden s6-svc -r /run/service/jobd   # restart it
docker compose logs palwarden                               # its stderr lands here
```

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

Any `PALWORLD_CFG_<KEY>` in your `.env` is applied to `PalWorldSettings.ini`
before the server starts — e.g. `PALWORLD_CFG_SERVER_NAME`,
`PALWORLD_CFG_MAX_PLAYERS`, `PALWORLD_CFG_SERVER_PASSWORD`. See
[`.env.example`](.env.example). Compose passes `.env` into the container
(`env_file`) as well as using it for interpolation, which is what makes these
open-ended keys work — setting them only in your shell will *not* reach the
container.

## Quick start — embedded (self-contained server)

```bash
cd docker
cp .env.example .env          # set ADMIN_PASSWORD (+ DISCORD_WEBHOOK) if wanted
COMPOSE_PROFILES=embedded docker compose up -d --build
docker compose logs -f palwarden
```

> **Upgrading an existing stack from a release before the backups volume?** Copy
> `/opt/palworld/backups` out of the **old** container *before* the first `up` —
> a recreate deletes the writable layer those archives were in and replaces it
> with an empty volume. See
> [Upgrading from a pre-volume image](#upgrading-from-a-pre-volume-image-do-this-before-the-first-up).

Players connect on `UDP 8211`. Stop gracefully with
`docker compose down` (server saves via SIGINT).

The config web UI is published to `127.0.0.1:8088` and **requires Basic auth on all paths** — the dashboard is at `/` and the vendored editors (like `PalWorldSettingsEditor.html`) are accessible by their filenames. Credentials are generated on first start; read them with:

```bash
docker compose exec palwarden cat /etc/palworld/webui.env
```

There are two secrets in that file. `WEBUI_PASSWORD` gets you the page;
`WEBUI_TOKEN` is the second factor every *mutating* request must send in the
`X-Palwarden-Token` header (the editor's Save buttons prompt for it once per
tab). Basic auth alone is refused with `403` on mutations by design.

**Credential persistence**: `/etc/palworld` is not a volume, so credentials regenerate when the container is recreated (e.g. `docker compose up --build`). Set `WEBUI_USER` / `WEBUI_PASSWORD` / `WEBUI_TOKEN` in `.env` if you want stable credentials across container rebuilds — **all three**. Pinning only the password leaves the token regenerating, which loads a working page on which every button 403s.

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
| `palwarden-state` | `/var/lib/palworld` | `metrics.sqlite3` telemetry, the job queue, upload staging (both modes) |
| `palwarden-backups` | `/opt/palworld/backups` | World-save archives (embedded) |
| `palwarden-config-snapshots` | `/opt/palworld/config-snapshots` | Config snapshots / rollback material (embedded) |
| `palwarden-config-backups` | `/opt/palworld/config-backups` | `Engine.ini` pre-rollback copies (embedded) |

`palwarden-backups` is deliberately its own volume and **not** a directory inside
`palworld-saved`: a backup has to outlive the thing it backs up, and anything left
in the container's writable layer is destroyed by a plain
`docker compose up --force-recreate`. Docker seeds a fresh named volume from the
image path, which is pre-created root-owned `0755` — the ownership
`palworld-backup` and `palworld-restore` both require — so it never needs a
runtime `chown`. `docker compose down -v` deletes your backups along with
everything else; copy them off the host (the Backups page's download button, or
`docker cp`) before you do that.

**`/opt/palworld` as a whole is *not* persisted** — only the three paths named in
the table above are. `/opt/palworld/restore-scratch` and `/opt/palworld/tools`
live in the writable layer and are recreated on every start, which is correct:
the scratch directory holds one archive for the duration of a single import and
the web root ships in the image. The two config directories got volumes of their
own because they are recovery material with the same exposure as the backups —
`config-snapshots` is what you roll a bad config change back from, and a recreate
is exactly when you want it.

Bind mounts work too; match host ownership to `steam` (uid/gid **1000**).

### Upgrading from a pre-volume image (do this BEFORE the first `up`)

Releases before the backups volume kept `/opt/palworld/backups` in the
container's **writable layer**. `git pull && docker compose up -d` recreates the
container, which deletes that layer, and the new empty `palwarden-backups` volume
takes its place — **every existing archive is gone**, with nothing to recover
from once the old container is removed. The same applies to
`/opt/palworld/config-snapshots` and `/opt/palworld/config-backups`.

While the **old** container still exists (before any `up`, `down` or
`--force-recreate` on the new image):

```bash
cd docker
docker compose cp palwarden:/opt/palworld/backups ./backups-migrate
docker compose cp palwarden:/opt/palworld/config-snapshots ./snapshots-migrate   # optional
```

Then bring the new image up and copy the archives back into the volume:

```bash
COMPOSE_PROFILES=embedded docker compose up -d --build
docker compose cp ./backups-migrate/. palwarden:/opt/palworld/backups
docker compose exec palwarden chown -R root:root /opt/palworld/backups
docker compose exec palwarden chown steam:steam /opt/palworld/backups/palworld-save-*.tar.gz
docker compose exec palwarden ls -l /opt/palworld/backups     # dir root 0755, files steam
```

The ownership matters: the directory must stay **root-owned `0755`** (that is
what stops the unprivileged web process substituting an archive) and the archives
themselves are handed to `steam`. `palworld-restore` refuses outright if that is
wrong, so a mistake here is a clean refusal rather than a bad restore.

If you have already upgraded and the archives are gone, the container says so on
start: `WARNING: /opt/palworld/backups is empty but this world already has
saves`.

## Security notes

- The REST API (`8212/tcp`) is **not** published to the host; the web UI is
  published to `127.0.0.1` only.
- Secrets are rendered at runtime from env; `.env`, `settings.env`, `notify.env`
  are git-ignored and never in the image.
- Workloads run non-root (`steam`); s6 is PID 1 root only to supervise, plus the
  three services the table above marks root.
- Web UI access is **not** a security boundary against reading `ADMIN_PASSWORD`:
  the editors preload the live `PalWorldSettings.ini` over `GET /current/...`, so
  anyone who can log into the UI can read it in cleartext. See the security note
  in [`../docs/architecture.md`](../docs/architecture.md).

## Configuration reference

`.env` (see [`.env.example`](.env.example)): `COMPOSE_PROFILES`,
`PALWARDEN_MODE`, `UPDATE_ON_START`, `PALWORLD_GAME_PORT`, `WEBUI_PORT`,
`ADMIN_PASSWORD`, `DISCORD_WEBHOOK`, `WEBUI_USER`, `WEBUI_PASSWORD`,
`WEBUI_TOKEN`, `FPS_SAMPLE_INTERVAL`, `FPS_RETENTION_DAYS`,
`PALWORLD_TARGET_HOST`, `PALWORLD_REST_PORT`, `BACKUP_ENABLED`,
`BACKUP_INTERVAL_HOURS`, `BACKUP_RETENTION_DAYS`, `BACKUP_KEEP_MIN`,
`BACKUP_TICK_SECONDS`.

The four `BACKUP_*` schedule variables **seed `/etc/palworld/backup.env` on the
first start only**. The Backups page rewrites that file when the operator saves
the schedule form, so re-rendering it on every start would revert their change;
`BACKUP_TICK_SECONDS` is read from the environment on every start because it is
this container's tick, not part of the schedule.

## Image internals

- Base `cm2network/steamcmd`; supervisor `s6-overlay` v3; services in
  [`s6-rc.d/`](s6-rc.d/) selected at runtime via the s6 `user` bundle.
- Periodic jobs use [`palwarden-run-periodic`](palwarden-run-periodic) (a small
  run-sleep loop) in place of systemd timers.
- The sampler reaches the API via `palworld-api`, which now honors
  `REST_API_HOST` (defaults to localhost, so bare-metal behavior is unchanged).
