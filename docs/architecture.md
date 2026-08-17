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
mutations, and `confirm: true` for disruptive actions. The token is a **CSRF
defence, not a second factor**: the pages fetch it from `GET /api/token` with the
Basic session they already hold, so Basic auth alone is what gates mutation. What
the custom header stops is a *cross-site* page acting as you — it cannot set the
header without a preflight we never answer, and it cannot read the token either.
Details and the recovery procedures are in
[`tools.md`](tools.md#web-ui-control-plane) and
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

### Player presence & the Players tab

Palworld persists no playtime (the save format was checked exhaustively —
see `docs/superpowers/specs/2026-08-16-player-presence-design.md`), so
palwarden observes it: the 15-second `palworld-fps sample` tick also calls
`GET /v1/api/players` and folds who it sees into identity rows and
grace-window sessions in `metrics.sqlite3`. The Players tab reads the rollup
via `GET /api/playtime`. Two contracts matter: the metrics and presence
passes fail independently (a REST outage is a gap in observation, never a
sampler error), and playtime is **tracked-since**, not all-time — the page
says so. The REST payload's `ip`/`ping`/`location` are deliberately never
stored.

### The settings editor

`webui/PalWorldSettingsEditor.html` is a fork of the MIT upstream settings
editor (see `CREDITS.md`) with the live control plane integrated directly into
the page — the full ~90-field form gained **Load Live Config**, which fills the
form from `GET /current/PalWorldSettings.ini`, and save buttons that diff the
form against that baseline and send only the *changed* keys as a
`settings_save` (file-only) or `settings_save_apply_restart` (disruptive) job.
Served over HTTP it is the live editor (fields the page can never save —
passwords, the REST API keys, `CrossplayPlatforms` — are hidden); opened as a
local file it remains upstream's offline generate/copy editor. jobd validates
every key and value against the live config's own shapes using
`palworld-config-parser`'s resolver/renderer — the exact code `config_apply`
runs later — refuses the password keys (managed via `settings.env`) and the
REST API keys (the control plane's own lifeline), and merge-writes
`PALWORLD_SETTINGS_OVERRIDES` (`/etc/palworld/settings-overrides.env` on bare
metal, `/var/lib/palworld/settings-overrides.env` in the container — on the
`palwarden-state` volume for the same reason the backup schedule is).
`palworld-config-apply-env` applies that file in a second parser pass after
`settings.env`, on every apply including the container's boot-time one: a value
saved in the browser wins over its `PALWORLD_CFG_*` variable and is re-asserted
on every start, while an untouched key stays owned by whatever set it. The
disruptive composite applies **inside the restart window**
(`palworld-graceful-restart --apply-config`), after the server has fully
stopped — the game rewrites its config from memory as it exits, so an apply
against a running server is silently clobbered.

### The backup panel

`webui/backups.html` is the same control plane applied to world saves: list,
download, upload, import, restore, delete, and the schedule form. It adds no new
privilege — every mutation is still a job file that `palwarden-jobd` re-validates
and runs as root (`backup_import`, `backup_restore`, `backup_delete`,
`backup_schedule_save`) — plus two endpoints that move *bytes* rather than jobs:
`POST /api/backups/upload` (streams into the staging dir; promotes nothing) and
`GET /api/backups/<name>/download` (streams one archive out). Both are described
in [`tools.md`](tools.md#palwarden-webui).

Scheduled backups are a third path that involves neither: `palworld-backups
--if-due --prune`, run as root on a short fixed tick by
`palworld-backup-auto.timer` or the container's `backup-auto` service. The
*schedule* is a file the panel writes through `backup_schedule_save`, so the web
process never has to be given control of a timer. That file is
`/etc/palworld/backup.env` on bare metal and `/var/lib/palworld/backup.env` in the
container (`PALWORLD_BACKUP_SCHEDULE`): it holds operator state the panel rewrites,
so on each platform it has to live somewhere that survives a restart of the
tooling — in the container that means the `palwarden-state` volume, because
`/etc/palworld` there is re-rendered into the writable layer.

**Why the two new directories have opposite ownership.** This is the panel's whole
security argument, and getting either one backwards is silent on the happy path:

| Path | Owner | Mode | Because |
|------|-------|------|---------|
| `/var/lib/palworld/uploads` | service account | 0700 | The unprivileged web process is its **only writer** — it streams a browser upload straight into it, exactly as it writes the job queue. `palwarden-webui` refuses an upload outright unless it owns this directory with no group/other bits, so a root-owned one breaks every upload. |
| `/opt/palworld/restore-scratch` | `root:root` | 0700 | `palworld-restore` copies an archive here and validates **the copy**, because `palworld-backup` chowns each archive to the service account — so an archive in the backups directory is writable by the web process, and validating one in place would prove the name and not the bytes. |

The scratch directory's **parent** matters as much as the directory: it lives under
the root-owned `/opt/palworld` rather than beside `uploads`, because
`/var/lib/palworld` is `0755` service-account-owned. Inside a tree that account
can write, a "root-only" directory is not root-only — the account could pre-create
it, or `rename` root's aside and put its own at the same name at any moment, and a
substituted archive would then be restored while the job reported success. That is
not hypothetical: an earlier draft defaulted the scratch directory to
`/var/lib/palworld/restore-scratch` and a review demonstrated exactly that. The
tool also `fstat`s the directory it opened and refuses one it does not own, so a
mis-provisioned host gets a clean refusal rather than a silent hole — but both
platforms create it correctly (`install.sh`, `docker/entrypoint.sh`, and the image
itself).

Ordinary recovery procedures — a failed restore, changing the schedule — are in
[`palworld-service-runbook.md`](palworld-service-runbook.md) §15.

## Data / state directories

| Location | Owner | Purpose |
|----------|-------|---------|
| `/opt/palworld/server` | `palworld` | Game install + `Pal/Saved` (config, saves). Not in this repo. |
| `/opt/palworld/tools` | `palworld` | Web UI + reference docs (installed here). |
| `/opt/palworld/backups` | `root` (0755) | World save tarballs from `palworld-backup`. Root-owned deliberately — see the note below. |
| `/opt/palworld/config-backups` | `palworld` | Timestamped `PalWorldSettings.ini` / `Engine.ini` backups. |
| `/opt/palworld/config-snapshots` | `root` (0755) | Labeled config+state snapshots. Root-owned deliberately — see the note below. |
| `/etc/palworld` | mixed | `settings.env`, `notify.env`, `engine.env`, templates. |
| `/var/lib/palworld` | root/palworld | `metrics.sqlite3`, `public-info.env`, `service-events.json` (last observed service state), and in the container `backup.env` (the schedule; `/etc/palworld/backup.env` on bare metal). |
| `/var/lib/palworld/jobs` | `palworld` (0700) | Control-plane job queue: `<id>.json` per job. Written by the web UI, executed by `palwarden-jobd`. |
| `/var/lib/palworld/uploads` | `palworld` (0700) | Upload staging for the backup panel. Written by the web UI, read (and emptied) by `palworld-restore --import`. |
| `/opt/palworld/restore-scratch` | `root` (0700) | Where `palworld-restore` copies an archive to validate it. Root-owned *and* under a root-owned parent — see below. |
| `/var/log/palworld` | palworld | `server.log`. |
| `/run/palworld-*.lock` | — | `flock` files preventing overlapping timer runs. |
| `/run/palwarden-jobd.lock` | root | `palwarden-jobd`'s exclusive lock — one worker, one job at a time. |

**Why `backups` and `config-snapshots` are root-owned.** Only root ever writes
them — `palwarden-jobd`'s `backup` and `snapshot_create` actions, the timers, or a
hand-run command. The web UI only *lists* them, which `0755` already permits;
world-save archives are pruned by `palworld-backups --prune` (also root, from the
scheduled tick), while `config-snapshots` still has no retention at all. When they
were service-account-owned, the unprivileged web
process could rename a directory root had just created and drop a symlink in its
place, redirecting root's writes — and its `chown` — anywhere on the filesystem.
`config-backups` stays service-account-owned because `palworld-engine-config
rollback` reads from it and the web UI is expected to manage it; it is safe there
because every use validates the name and opens it `O_NOFOLLOW`. The *archives* in
`backups` are still chowned to the service account (the root-owned directory is
what keeps their names from being substituted), which is precisely why
`palworld-restore` validates a root-owned copy instead of the file in place.

## Concurrency & safety

- Timer-driven jobs that can collide with each other or with the server take a
  `flock` (`fps-sample`, `update`, `memory-watch`, `backup-auto`).
- `palwarden-jobd` takes its lock in **every** mode — the daemon loop, `--once`
  and `--reap` alike — so a hand-run one-shot can never race the service or
  mistake a live job for an orphan.
- That lock makes the *worker* single, not the schedule, so the backup family
  (`backup`, `backup_import`, `backup_restore`, `backup_delete`) also takes
  `/run/palworld-backups.lock` — the scheduled tick's lock, on both platforms.
  The tick takes it with `-n` and skips; jobd waits, because an action an operator
  queued must not be dropped for a tar that happened to be running.
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
