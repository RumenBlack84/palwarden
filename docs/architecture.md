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

**8. Web UI control plane** — the same operator commands, reachable from a
browser on `127.0.0.1:8088`, split across a privilege boundary that is a *file*,
not a socket:

```
   browser ──Basic auth──► palworld-config-webui.service
   (SSH tunnel)            palwarden-webui --serve   (user: palworld)
                             · serves the dashboard + editors + GET /api/*
                             · POST /api/jobs: validate, then write a job file
                             ▼
                           /var/lib/palworld/jobs/<id>.json   (0700, owned by palworld)
                             ▼
                           palwarden-jobd.service      (root)
                             · re-validates action + params against its own
                               allowlist — the queue is untrusted input
                             · runs a fixed argv template, one job at a time
                               under flock /run/palwarden-jobd.lock
                             · records state, exit code and output on the job
```

The property that matters: **the process that parses HTTP has no privilege, and
the process with privilege has no network input.** `palwarden-webui` refuses to
start as root and can do nothing worse than write a job file. `palwarden-jobd`
never trusts what it reads, so a bug in the HTTP handler — or a hand-edited job
file — cannot reach anything outside the allowlist. Both halves must be enabled;
with `jobd` down, jobs queue and never run.

Authentication is Basic on every path from `/etc/palworld/webui.env`, plus
`WEBUI_TOKEN` in `X-Palwarden-Token` and an `Origin`/`Sec-Fetch-Site` check on
mutations, and `confirm: true` for disruptive actions. Details and the recovery
procedures are in [`tools.md`](tools.md#web-ui-control-plane) and
[`palworld-service-runbook.md`](palworld-service-runbook.md) §14.

Two things this split deliberately does *not* do:

- It does not hide the server's own secrets from a UI user. The editors preload
  the live `PalWorldSettings.ini` via `GET /current/PalWorldSettings.ini`, so
  anyone who can log in reads `AdminPassword` in cleartext. `/api/config` redacts
  `AdminPassword`/`ServerPassword`, but that is defence-in-depth for diffs, logs
  and screenshots — not a boundary. What the separate `webui.env` credentials buy
  is the reverse direction: an in-game admin who knows `ADMIN_PASSWORD` does not
  thereby get shell-level control of the host.
- It does not make the queue directory root-owned. It is owned by the
  unprivileged web user on purpose, because that user is the one writing job
  files; root only reads and updates them. Root ownership breaks every button.

## Data / state directories

| Location | Owner | Purpose |
|----------|-------|---------|
| `/opt/palworld/server` | `palworld` | Game install + `Pal/Saved` (config, saves). Not in this repo. |
| `/opt/palworld/tools` | `palworld` | Web UI + reference docs (installed here). |
| `/opt/palworld/backups` | `root` (0755) | World save tarballs from `palworld-backup`. Root-owned deliberately — see the note below. |
| `/opt/palworld/config-backups` | `palworld` | Timestamped `PalWorldSettings.ini` / `Engine.ini` backups. |
| `/opt/palworld/config-snapshots` | `root` (0755) | Labeled config+state snapshots. Root-owned deliberately — see the note below. |
| `/etc/palworld` | mixed | `settings.env`, `notify.env`, `engine.env`, templates. |
| `/var/lib/palworld` | root/palworld | `metrics.sqlite3`, `public-info.env`, `service-events.json` (last observed service state). |
| `/var/lib/palworld/jobs` | `palworld` (0700) | Control-plane job queue: `<id>.json` per job. Written by the web UI, executed by `palwarden-jobd`. |
| `/var/log/palworld` | palworld | `server.log`. |

**Why `backups` and `config-snapshots` are root-owned.** Only root ever writes
them — `palwarden-jobd`'s `backup` and `snapshot_create` actions, the timers, or a
hand-run command. The web UI only *lists* them, which `0755` already permits, and
nothing prunes them. When they were service-account-owned, the unprivileged web
process could rename a directory root had just created and drop a symlink in its
place, redirecting root's writes — and its `chown` — anywhere on the filesystem.
`config-backups` stays service-account-owned because `palworld-engine-config
rollback` reads from it and the web UI is expected to manage it; it is safe there
because every use validates the name and opens it `O_NOFOLLOW`.
| `/run/palworld-*.lock` | — | `flock` files preventing overlapping timer runs. |
| `/run/palwarden-jobd.lock` | root | `palwarden-jobd`'s exclusive lock — one worker, one job at a time. |

## Concurrency & safety

- Timer-driven jobs that can collide with each other or with the server take a
  `flock` (`fps-sample`, `update`, `memory-watch`).
- `palwarden-jobd` takes its lock in **every** mode — the daemon loop, `--once`
  and `--reap` alike — so a hand-run one-shot can never race the service or
  mistake a live job for an orphan.
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
