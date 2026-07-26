# Architecture

How the `palwarden` pieces fit together on a running host.

## Big picture

```
                         ┌─────────────────────────────────────────────┐
                         │              palworld.service                │
                         │   PalServer.sh (user: palworld)              │
                         │   game port 8211/udp · REST API 8212/tcp     │
                         └───────────────┬───────────────┬─────────────┘
                                         │               │
                       localhost REST API│               │writes save data
                       (ADMIN_PASSWORD)  │               ▼
                                         │      /opt/palworld/server/Pal/Saved
                                         │        ├── Config/LinuxServer/*.ini
                                         │        └── SaveGames/
                                         │
   ┌─────────────────────────────────────┼──────────────────────────────────┐
   │ systemd timers (background jobs)     │                                  │
   │                                      ▼                                  │
   │  fps-sample.timer ─────► palworld-fps sample ──┐                        │
   │   (every 15s)                                  │  writes                │
   │  update-check.timer ───► palworld-update       ▼                        │
   │   (every 30m)                        /var/lib/palworld/metrics.sqlite3  │
   │  memory-watch.timer ───► palworld-memory-watch    (fps + fps_events)    │
   │   (every 5m)                                  ▲                          │
   │  public-info-watch ────► palworld-public-info-watch                     │
   │   (every 10m)              writes public-info.env                       │
   │  service-events.timer ─► palworld-service-events sample                 │
   │   (every 1m)               records restarts/outages as markers          │
   │  fps-daily-report ─────► palworld-health-report discord ──┐            │
   │   (09:00 ET)                                               │            │
   └───────────────────────────────────────────────────────────┼───────────┘
                                                                │
   operator commands (manual, via sudo)                         │ reads
     palworld-graceful-restart / -stop                          ▼
     palworld-backup            all record ────────►  reports + FPS/player graph
     palworld-config-apply-env  event markers                   │
     palworld-engine-config     in metrics.sqlite3              ▼
     palworld-config-snapshot                          palworld-notify ──► Discord webhook
     palworld-status                                    (/etc/palworld/notify.env)
```

## Layers

**1. The server** — `palworld.service` runs the SteamCMD-installed
`PalServer.sh` under the `palworld` user with performance flags, logging to
`/var/log/palworld/server.log`. All other tooling orbits this one unit.

**2. REST API client layer** — `palworld-api` is the low-level client
(`save`/`stop`/`info`/`metrics`) that talks to `127.0.0.1:8212` using HTTP Basic
auth with `admin` + `ADMIN_PASSWORD` from `/etc/palworld/settings.env`.
`palworld-api-save` and `palworld-api-stop` are thin notifying wrappers.

**3. Lifecycle orchestration** — `palworld-graceful-stop` (save → timed API
shutdown → wait for exit) and `palworld-graceful-restart` (stop → start → wait
for systemd active → wait for REST API ready). Restart auto-shortens the player
warning when the server is empty. `palworld-update` and the memory/needrestart
hooks all funnel through these instead of raw `systemctl restart`.

**4. Config management** — env-driven, backed up on every change:
- `palworld-config-apply-env` renders `settings.env` → `PalWorldSettings.ini`
  (via `palworld-config-parser`, with secrets written separately), backs up the
  old file, posts a redacted diff, and records an event marker.
- `palworld-engine-config` manages `Engine.ini` performance levers from
  `engine.env`, with `apply` / `status` / `rollback` subcommands and backups.
- `palworld-config-pretty` regenerates human-readable `*.pretty.ini` references.
- `palworld-config-snapshot` captures a labeled bundle of config + live state.

**5. Telemetry** — `palworld-fps` owns `metrics.sqlite3`: it `sample`s FPS and
player count from the REST API on a 15s timer (7-day retention), stores
operational `fps_events` markers, and produces `report` / `compare` / `graph`
output. `palworld-health-report` reads that DB and system state into one daily
Discord-safe summary.

**6. Notification** — `lib/palworld-notify` is a sourced shell function every
script calls. It reads the Discord webhook from `/etc/palworld/notify.env` and
no-ops silently if that file is absent, so the tooling runs fine without Discord.

**7. Watchers** — one-shot timer jobs: `memory-watch` (graceful restart over a
memory threshold — the container's cgroup limit when there is one, else host RAM),
`service-events` (notice restarts/outages and record them as markers, classified
planned vs unexpected), `public-info-watch` (republish join info on change), and
`launch-watch` (a dated one-off for the Palworld 1.0 launch — see below).

Restart detection is observational on purpose: systemd's `NRestarts` resets with
the unit and s6 keeps no counter, so sampling state + main PID is the only measure
that means the same thing on bare metal and in the container.

## Data / state directories

| Location | Owner | Purpose |
|----------|-------|---------|
| `/opt/palworld/server` | `palworld` | Game install + `Pal/Saved` (config, saves). Not in this repo. |
| `/opt/palworld/tools` | `palworld` | Web UI + reference docs (installed here). |
| `/opt/palworld/backups` | `palworld` | World save tarballs from `palworld-backup`. |
| `/opt/palworld/config-backups` | `palworld` | Timestamped `PalWorldSettings.ini` / `Engine.ini` backups. |
| `/opt/palworld/config-snapshots` | `palworld` | Labeled config+state snapshots. |
| `/etc/palworld` | mixed | `settings.env`, `notify.env`, `engine.env`, templates. |
| `/var/lib/palworld` | root/palworld | `metrics.sqlite3`, `public-info.env`, `service-events.json` (last observed service state). |
| `/var/log/palworld` | palworld | `server.log`. |
| `/run/palworld-*.lock` | — | `flock` files preventing overlapping timer runs. |

## Concurrency & safety

- Timer-driven jobs that can collide with each other or with the server take a
  `flock` (`fps-sample`, `update`, `memory-watch`).
- Every config mutation writes a timestamped backup first; `engine-config` and
  `config-snapshot` add rollback paths.
- `needrestart` is configured so unattended `apt` upgrades **report** but never
  auto-restart `palworld.service`; an explicit needrestart request is rerouted
  through `palworld-graceful-restart`.

## Notes on the `1dot0-watch` unit

`palworld-1dot0-watch.{service,timer}` + `palworld-launch-watch` were a
**time-boxed** helper that polled every minute around the Palworld 1.0 launch
(2026-07-10 03:30 UTC) and self-disabled once v1.0 was detected. It is kept for
history but is effectively inert now; don't enable it on a fresh install.
