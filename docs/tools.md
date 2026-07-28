# Tool reference

Every command, library, and unit in `palwarden`, grouped by function. Installed
paths are shown; in the repo they live under `sbin/`, `lib/`, `bin/`, and
`systemd/`. All admin commands generally require `sudo` (they read secret env
files, talk to the REST API, and touch `palworld`-owned files).

- [Lifecycle](#lifecycle)
- [REST API helpers](#rest-api-helpers)
- [Configuration](#configuration)
- [Web UI control plane](#web-ui-control-plane)
- [Telemetry & reporting](#telemetry--reporting)
- [Watchers](#watchers)
- [Status](#status)
- [Libraries](#libraries)
- [Config parser](#palworld-config-parser)
- [systemd units & timers](#systemd-units--timers)

---

## Lifecycle

### `palworld-graceful-stop`
`/usr/local/sbin/palworld-graceful-stop [--wait SECONDS] [--message TEXT]`

Saves the world (REST API), issues a timed API shutdown with a player notice
(default 300s), then waits for `palworld.service` to go inactive. No-ops if the
service isn't active. Notifies on completion/timeout.

### `palworld-graceful-restart`
`/usr/local/sbin/palworld-graceful-restart [--wait S] [--empty-wait S] [--message T] [--empty-message T] [--startup-timeout S]`

The preferred way to restart once the REST API is live. Checks current player
count via the API and picks a short `--empty-wait` (default 15s) when the server
is empty, otherwise the full `--wait` (300s). Runs `graceful-stop`, starts the
service, waits for systemd `active`, then waits for REST API readiness before
declaring success. Records `graceful restart requested` / `completed` event
markers. **Prefer this over `systemctl restart palworld.service`.**

### `palworld-update`
`/usr/local/sbin/palworld-update [--check] [--notify-no-update]`

Compares the local Steam buildid against the public branch before doing anything.
- default: exits 0 and does nothing if up to date; if an update exists, posts a
  Discord notice, graceful-stops with player warning, runs SteamCMD
  `app_update 2394010 validate`, restarts if it was running, and reports
  completion. Safe to run on a timer.
- `--check`: exit 0 if current, exit 10 if an update is available; never touches
  the server.
- `--notify-no-update`: also post a Discord message when already current.

Records `update detected` / `completed` markers.

### `palworld-backup`
`/usr/local/sbin/palworld-backup`

Tars `Pal/Saved/{SaveGames,Config}` to
`/opt/palworld/backups/palworld-save-<UTC>.tar.gz`, prints the path, and notifies
success/failure with the archive size.

### `palworld-backups`
`/usr/local/sbin/palworld-backups {--delete ARCHIVE | --prune | --if-due | --show-schedule}`

Owns the *collection* of world-save archives, where `palworld-backup` makes one and
`palworld-restore` turns one back into a world. Runs as **root** — the backups
directory is root-owned — from `palworld-backup-auto.timer`, the container's
`backup-auto` service, or `palwarden-jobd`'s `backup_delete` action.

- `--if-due`: create a backup if `BACKUP_INTERVAL_HOURS` has elapsed since the
  newest archive (by mtime, so an imported archive counts as "just written"). No
  archive at all is *due*, so a rebuilt host backs up on its first tick.
  `BACKUP_ENABLED=false` makes it a printed no-op.
- `--prune`: delete archives past `BACKUP_RETENTION_DAYS`, keeping the newest
  `BACKUP_KEEP_MIN` by name whatever their age and **never the last one**.
- `--delete ARCHIVE`: remove one archive, with **no floor** — the operator has
  passed three confirmations in the UI, the last of which says when it is the only
  copy left. Deliberately different from `--prune`; do not unify them.
- `--show-schedule`: the effective schedule as JSON. `/api/backup-schedule` shells
  out to this rather than parsing the file again, so the panel always shows what
  the tick will actually do.

`--if-due --prune` **compose, in that order**, and that is the exact argv both
platform services run: retention is applied to the collection *including* the
archive just created, so the new one counts toward `BACKUP_KEEP_MIN` and an expired
one ages out in the same tick. Pruning happens even when the create failed — a full
volume is the likeliest cause, and retention is what frees space for the next
attempt. `--delete` and `--show-schedule` combine with nothing.

The schedule lives in a **file** (`PALWORLD_BACKUP_SCHEDULE`, default
`/etc/palworld/backup.env`), not in a unit, and the services fire on a short fixed
tick that asks this tool whether anything is due. That is what lets one
implementation serve systemd and s6, lets the interval be changed from the browser
with nothing to reload, and lets a host that was powered off back up on the first
tick after boot instead of missing a window. A bad value in that file is therefore
**never fatal**: it warns on stderr and falls back to that key's default (the
default, not the nearest bound — `BACKUP_RETENTION_DAYS=3560` where `356` was meant
gives 14 days and a warning, not a silently accepted decade).

### `palworld-restore`
`/usr/local/sbin/palworld-restore {--import ARCHIVE | --restore ARCHIVE [--wait S] [--startup-timeout S]}`

Turns a world-save archive back into a world. Runs as **root** (normally via
`palwarden-jobd`'s `backup_import` / `backup_restore` actions). Import is
**round-trip only**: the name must be exactly what `palworld-backup` writes
(`palworld-save-<UTC>.tar.gz`) and every member must resolve under `SaveGames/`
or `Config/` — see [`palwarden_archive`](#libraries).

- `--import ARCHIVE`: promote an upload out of the web-writable staging dir
  (`PALWARDEN_UPLOAD_DIR`, default `/var/lib/palworld/uploads`) into the
  root-owned backups dir, 0644, **refusing to overwrite** an existing archive.
  It **copies first and validates the copy**, because the staging file's owner
  (the web process) can rewrite it in place between two reads. Prints the
  promoted path; deletes the upload only on success. The promotion is capped at
  `PALWARDEN_IMPORT_MAX_BYTES` (**default 8 GiB**, compressed) — a *different*
  limit from the HTTP one below (`PALWARDEN_MAX_UPLOAD_BYTES`, default 2 GiB,
  which bounds the request body the web process will accept). Both are real: the
  web server refuses a body over 2 GiB, and root refuses to promote a staged file
  over 8 GiB. Neither is the decompression-bomb cap, which
  [`palwarden_archive`](#libraries) applies to the *uncompressed* size.
- `--restore ARCHIVE`: replace the live world with the archive's contents.
  In order, stopping at the first failure: copy the archive into a root-only
  scratch dir (`PALWARDEN_RESTORE_SCRATCH`, default
  `/opt/palworld/restore-scratch`, 0700) and **validate that copy** — every
  archive in the backups dir is writable by the web process, so validating one
  in place would guarantee the name and not the bytes (bounded by
  `PALWARDEN_RESTORE_MAX_BYTES`, default 8 GiB compressed); a **conditional** safety
  backup via `palworld-backup` (skipped with a printed note when there is no
  world to preserve); `palworld-graceful-stop [--wait S]`, where an
  already-stopped server is success but a stop that leaves the server *running*
  aborts; extract into `Pal/Saved.restore-<stamp>` **beside** the target, rename
  the live tree to `Pal/Saved.replaced-<stamp>`, rename the new tree into place;
  `chown -R` to `PALWORLD_USER`/`PALWORLD_GROUP`; start the service and wait for
  REST readiness (`--startup-timeout`, default 180s — the same check
  `graceful-restart` uses).

  The replaced tree is **deleted only on a confirmed startup**. If the start
  fails, readiness times out, **or the REST API is not configured so readiness
  cannot be verified at all**, it is kept and its path is printed alongside the
  safety archive's name, so there are two routes back.

  The scratch dir lives under `/opt/palworld` and not next to the uploads dir
  because `/var/lib/palworld` is 0755 **service-account-owned** on both
  platforms: a "root-only" directory inside it is not root-only. The tool
  `fstat`s the directory it opened and refuses one it does not own or that has
  any group/other bits, holds that descriptor for the whole restore, and refuses
  if the scratch copy's inode changes between validation and extraction.

  Any `Pal/Saved.replaced-*` trees left by earlier restores are **listed at the
  start** of a restore (named only — never sized, never deleted), because each is
  a full world save and nothing else ever mentions them again.

`--restore` is **refused in `PALWARDEN_MODE=external`**: the game runs on another
host, so `systemctl is-active` (via the shim's `pgrep` fallback) cannot see it,
and a stop that failed against a *live* server would read as "already stopped"
and the world would be replaced underneath it. Stop and restore on the host that
runs the server.

Designed for disaster recovery, so it never assumes existing state: a missing or
empty `Pal/Saved` and a server that is already down are both normal.

---

## REST API helpers

The Palworld REST API authenticates with HTTP Basic `admin` + **`ADMIN_PASSWORD`**
(from `settings.env`), not `SERVER_PASSWORD`. All of these require
`REST_API_ENABLED=True` and a non-empty `ADMIN_PASSWORD`.

### `palworld-api`
`/usr/local/sbin/palworld-api {save|stop [seconds] [message]|info|metrics}`

Low-level client against `127.0.0.1:${REST_API_PORT}`. `info` returns
server/version JSON; `metrics` returns FPS/player/uptime JSON used by the
sampler and restart logic.

### `palworld-api-save` / `palworld-api-stop`
Thin wrappers that add Discord notifications around `palworld-api save` and
`palworld-api stop [seconds] [message]`.

---

## Configuration

See [`config-tools.md`](config-tools.md) for the full workflow narrative and
example variables. Summary of the commands:

### `palworld-config-apply-env`
`/usr/local/sbin/palworld-config-apply-env`

Reads `/etc/palworld/settings.env`, backs up the current `PalWorldSettings.ini`
to `/opt/palworld/config-backups/`, then applies every setting (passwords
included) via `palworld-config-parser`. Regenerates the pretty INI, posts a
redacted diff + settings summary, and records a config event marker.
**Requires a service restart to take effect.**

### `palworld-engine-config`
`/usr/local/sbin/palworld-engine-config {apply|status|rollback|pretty|diff|template} [...]`

Manages `Engine.ini` performance levers from `/etc/palworld/engine.env`
(tick rate, client/bandwidth limits, streaming/async options). `apply` backs up
and writes managed values; `status` shows managed values + nearest profile match;
`status --check` flags drift, comparing values *semantically* so the game's own
reformatting (`True` vs `1`, `60.000000` vs `60`) is not mistaken for drift;
`rollback` restores a prior backup. Records event markers. Reminds you to
`graceful-restart` — it never restarts on its own.


### `palworld-config-pretty`
`/usr/local/sbin/palworld-config-pretty`

Regenerates `PalWorldSettings.pretty.ini` — a multi-line, human-readable copy of
the monolithic single-line `OptionSettings=(...)`. Reference only; the canonical
file is unchanged.

### `palworld-config-snapshot`
`/usr/local/sbin/palworld-config-snapshot {create LABEL [--no-mark]|list}`

Captures a labeled bundle under `/opt/palworld/config-snapshots/`: both INIs +
pretty copies, `engine.env`, a **redacted** `settings.env`, engine status, FPS
report (text+json), 24h events, service status, API metrics, buildid, and a
`manifest.json`. Records a quiet event marker unless `--no-mark`.

---

## Web UI control plane

Two processes with a deliberate privilege split: `palwarden-webui` parses HTTP
and has no privilege, `palwarden-jobd` has root and no network input. Both must
be running or queued actions never execute. See
[`architecture.md`](architecture.md) for the boundary and
[`palworld-service-runbook.md`](palworld-service-runbook.md) §14 for recovery.

### `palwarden-webui`
`/usr/local/sbin/palwarden-webui {--serve|--init-credentials}`

Serves the web UI and the JSON API on `127.0.0.1:8088`. **Every path requires
HTTP Basic auth**, including the vendored editor, using credentials in
`/etc/palworld/webui.env` (`--init-credentials` generates them once, as root, and
never overwrites an existing file; `install.sh` and the container entrypoint call
it for you). With no arguments it prints help and exits — the service uses
`--serve`.

Read endpoints (Basic auth is enough): `/api/health`, `/api/fps`, `/api/events`,
`/api/service-events`, `/api/engine`, `/api/config` (passwords redacted),
`/api/backups`, `/api/snapshots`, `/api/backup-schedule`, `/api/jobs`,
`/api/jobs/<id>`, `/api/token`. A failing tool answers `200` with
`{"ok": false, "error": ...}` rather than a `500`, so one broken tool cannot blank
the dashboard. `/api/backups` lists only names matching the archive pattern, so a
`palworld-restore --import` copy that is still in flight is never shown as a
backup. `/api/backup-schedule` also carries `max_upload_bytes` *beside* `data` (the
server's upload ceiling, not part of the schedule): an over-cap upload is answered
`413` without the body being read and the connection is then closed, so a browser
still streaming a large file often sees only a transport error — the Backups page
uses this number to refuse such a file before sending it, naming both sizes.

`GET /api/backups/<name>/download` streams one archive
(`Content-Type: application/gzip`, `Content-Disposition: attachment`,
`Cache-Control: no-store`). Basic auth only — it is a read. The name must match
`palworld-save-<UTC stamp>.tar.gz`; anything else, and anything that is not a
regular file (a symlink or FIFO planted in the backups directory under a valid
name), is `404`.

`GET /api/token` returns `{"ok": true, "data": {"token": "..."}}` — the `WEBUI_TOKEN` value
needed to mutate. The Engine.ini editor fetches it on first Save (cached in
`sessionStorage` for the tab, with a `window.prompt` fallback if the endpoint is
missing), so **the operator is never asked to type a token**. Scripts can do the
same: Basic auth is all it takes to obtain the token, so there is no second secret
to provision. It is the one read that is *also* Origin-checked — `403` unless
`Sec-Fetch-Site` is `same-origin` (or absent) and any `Origin` is loopback —
because the response is itself the secret; it answers `Cache-Control: no-store`
plus `Pragma: no-cache`, and the value never reaches a log line.

Consequently **Basic auth alone is sufficient to mutate**: the token is a CSRF
token, not a second factor (see [`architecture.md`](architecture.md) and the
design spec's "Authentication and hardening"). Guard `WEBUI_PASSWORD` accordingly.

Mutating: `POST /api/jobs` with `{"action": ..., "params": {...}}` → `202
{"id": ...}`. It validates the request and writes a job file; **it never executes
anything**. On top of Basic auth a mutation needs the `WEBUI_TOKEN` value in the
**`X-Palwarden-Token`** header (not `Authorization: Bearer` — Basic already
occupies that header) and a loopback `Origin`/`Sec-Fetch-Site`. Disruptive
actions additionally need `"confirm": true` in the body. Status codes: `401`
bad/missing Basic · `403` missing/bad token or refused Origin · `400` validation
failure · `409` a disruptive job is already queued or running (the body carries
`blocked_by` with its `id`/`action`/`state`) · `500` internal.

`POST /api/backups/upload` stages a world-save archive for a later `backup_import`
job. Same gate as any mutation (Basic + `X-Palwarden-Token` + loopback
`Origin`/`Sec-Fetch-Site`). The **whole request body is the archive** —
`Content-Type: application/octet-stream`, no multipart — with the intended name in
**`X-Palwarden-Filename`**, which must match `palworld-save-<UTC stamp>.tar.gz`.
The bytes are streamed to `PALWARDEN_UPLOAD_DIR` (default
`/var/lib/palworld/uploads`, created 0700) and nothing else happens to them: this
process never unpacks or promotes an upload. Extra status codes: `413` over
`PALWARDEN_MAX_UPLOAD_BYTES` (default 2 GiB) · `507` too little free space
(`PALWARDEN_UPLOAD_FREE_MARGIN`, default 64 MiB, is kept free for the job queue and
the telemetry DB). The upload path uses its own socket timeout
(`PALWARDEN_UPLOAD_TIMEOUT`, default 600s) for that request only, because the
10-second request timeout would abort a real upload mid-flight.

```bash
# the token can be read out of webui.env, or simply fetched with Basic auth
WEBUI_TOKEN="$(curl -sS -u admin:"$WEBUI_PASSWORD" \
  http://127.0.0.1:8088/api/token | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["token"])')"

curl -sS -u admin:"$WEBUI_PASSWORD" -H "X-Palwarden-Token: $WEBUI_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"action":"backup"}' http://127.0.0.1:8088/api/jobs
```

Runs unprivileged and refuses to start as root. Basic auth over plain HTTP is
safe here only because the listener is loopback-bound; reach it through an SSH
tunnel (`ssh -L 8088:127.0.0.1:8088 <host>`), never expose it directly.

> **Not a boundary:** the editors preload the live config over
> `GET /current/PalWorldSettings.ini`, so anyone who can log into the UI can read
> `AdminPassword` in cleartext. `/api/config` redacts it, but that is
> defence-in-depth for diffs, logs and screenshots only.

### `palwarden-jobd`
`/usr/local/sbin/palwarden-jobd [--once|--reap]`

The root worker. Polls `/var/lib/palworld/jobs` (default; `PALWARDEN_JOBS_DIR`),
claims the oldest `queued` job, **re-validates its action and every parameter
against a hardcoded allowlist**, and runs a fixed argv template — nothing is ever
passed to a shell. The queue is written by the unprivileged web UI and therefore
treated as untrusted input; an unrecognised action, an unknown parameter name or
an out-of-range value fails the job with the reason recorded on it.

| Mode | Does |
|------|------|
| *(default)* | Reap orphans, then poll forever (`PALWARDEN_JOBD_INTERVAL`, default 2s), pruning finished jobs after 7 days. This is what the service runs. |
| `--reap` | Mark every job left `running` by a crashed worker as `failed`, then exit. |
| `--once` | Reap, run at most one queued job, prune, exit. |

All three modes take the **same exclusive `flock` on
`/run/palwarden-jobd.lock`** and hold it for the life of the process, so only one
worker can ever run: `--once`/`--reap` by hand while the service is up exits `1`
with `another palwarden-jobd holds ...` instead of racing it or failing a job the
live worker legitimately owns. Must run as root (it cannot even open the lock
otherwise).

Actions: `config_apply`, `engine_apply`, `config_pretty`, `snapshot_create`,
`backup`, `mark`, `engine_save`, `backup_import`, `backup_schedule_save`
(file-only) and `graceful_restart`, `graceful_stop`, `update_check`,
`update_apply`, `engine_rollback`, `api_save`, `engine_save_apply_restart`,
`backup_restore`, `backup_delete` (disruptive, `confirm: true` required).
Composite actions stop at the first failure — a failed save or apply never reaches
the restart. Output is captured combined and capped.

`backup_delete` is disruptive despite stopping no service: the classification gates
*irreversible* actions, and deleting the archive that would have recovered the
world is the least reversible thing here.

The four backup-family actions (`backup`, `backup_import`, `backup_restore`,
`backup_delete`) additionally take **`/run/palworld-backups.lock`** — the same lock
the scheduled tick holds (`palworld-backup-auto.service` on bare metal, the
`backup-auto` s6 service in the container). The jobd lock alone only makes the
*worker* single, which says nothing about the timer. This side **waits** for the
lock (`PALWARDEN_BACKUP_LOCK_WAIT`, default 1800s, then the job fails saying so)
while the tick takes it with `-n` and skips: a missed tick is recovered by the next
one, an action the operator is watching must not be dropped. If the lock file
cannot be opened at all the action still runs, unserialised, with a warning on the
service log — a lock must never be the thing that stops backups.

Platform wiring: `palwarden-jobd.service` on bare metal, the `jobd` s6 service in
the container (both run it as root; see
[`../docker/README.md`](../docker/README.md)).

---

## Telemetry & reporting

### `palworld-fps`
`/usr/local/sbin/palworld-fps <subcommand>` — Python 3, owns
`/var/lib/palworld/metrics.sqlite3`.

| Subcommand | Purpose |
|------------|---------|
| `sample [--retention-days N]` | Pull one FPS/player sample from the REST API and store it (driven by the 15s timer). Prunes old rows. |
| `report [--window 24h] [--graph FILE.png]` | Text stats (avg / 1% low / 0.1% low, player avg/max) over a window; optional two-panel PNG (FPS + player count) with event markers. |
| `discord [--window] [--dry-run]` | Post the report + graph to Discord. |
| `mark TEXT --category C [--details ...]` | Add an operational event marker. |
| `events [--window] [--json]` | List recent markers. |
| `compare --mark NAME --before 1h --after 1h [--json]` | Compare FPS windows around a marker or timestamp. |

Graphs require `matplotlib`; text output does not.

### `palworld-health-report`
`/usr/local/sbin/palworld-health-report {report|discord} [--json] [--window 24h] [--graph FILE.png]`

Read-only daily rollup: service state, API/live players, all FPS windows, player
avg/max, Engine.ini profile + drift, latest backup/snapshot, Steam buildid, disk
usage, and recent markers. `discord` attaches the FPS/player graph. Drives the
09:00 ET `palworld-fps-daily-report.timer`. **Never mutates state.**

---

## Watchers

### `palworld-memory-watch`
`/usr/local/sbin/palworld-memory-watch [--threshold PCT] [--wait S] [--message T]`

Restarts the server before memory pressure takes it out. Which memory it judges
depends on where it runs:

- **Container with a memory limit** — compares cgroup usage against *that limit*.
  (`/proc/meminfo` reports the host's RAM inside a container, so judging against
  the host made the watchdog useless: a server filling a 512 MiB limit is ~1.5% of
  a 32 GiB host and would never trigger.)
- **Bare metal / no limit** — host RAM used%, plus the unit's own cgroup, so a
  leaking server is caught before it drags the box down.

Over the threshold (default 85%) it warns to Discord and triggers a
`graceful-restart` under a `flock`. No-ops if the service is down. Timer: every
5 min.

### `palworld-public-info-watch`
`/usr/local/sbin/palworld-public-info-watch`

Reads `ServerPassword`/`PublicPort` from the live config and the current public
IP, and if the join info changed since `/var/lib/palworld/public-info.env`,
rewrites that file (mode 0600) and posts the new IP/port/password to Discord.
Timer: every 10 min.

### `palworld-service-events`
`/usr/local/sbin/palworld-service-events {sample|summary [--since 24h] [--json]}`

Crash/restart watchdog. `sample` compares the service's state and main PID against
the previous sample and records an event marker when they changed — classified
**planned** when the tooling requested a restart shortly before, or **unexpected**
(a crash, an OOM kill, something outside the tooling) otherwise. It also records
outages and recoveries. `summary` reports the counts and recent events, and feeds
the daily health report.

Why observe rather than ask: systemd's `NRestarts` resets with the unit and s6
keeps no counter at all, so this is the only restart count that means the same
thing on both platforms. Markers land in the telemetry DB, so restarts appear on
the FPS graphs next to config applies and updates. Timer/service: every 60s.

### `palworld-launch-watch` *(dated / inert)*
`/usr/local/sbin/palworld-launch-watch`

One-off high-frequency watcher for the Palworld 1.0 launch (2026-07-10). Runs the
update check each minute until v1.0 is detected, then disables its own timer. Do
not enable on a fresh install; kept for history.

---

## Status

### `palworld-status`
`/usr/local/sbin/palworld-status`

Human-readable one-shot dashboard: service/PID/memory, host memory, listening
ports (8211/8212/27015/8088), REST API health + server info, local Steam
buildid, join info (password shown as `[set]`), Palworld timers, and a log tail.

---

## Libraries

Installed to `/usr/local/lib`, not run directly.

- **`palworld-notify`** — sourced shell function `palworld_notify LEVEL MESSAGE`.
  Reads `/etc/palworld/notify.env`; posts an emoji-prefixed message to the Discord
  webhook. Silently no-ops if the file or webhook is missing, so every caller
  works with or without Discord. Callers also define a no-op fallback so they keep
  working when the helper itself isn't installed.
- **`palworld-config-diff`** — Python; prints a non-secret diff between two
  `PalWorldSettings.ini` files (`--discord` formats for chat). Redacts secret keys.
- **`palworld-config-summary`** — Python; prints a summary of the
  operationally-relevant live settings for notifications.

---

## `palworld-config-parser`

`/usr/local/bin/palworld-config-parser` — first-party **Python** tool that applies
environment variables to `PalWorldSettings.ini`. Wrapped by
`palworld-config-apply-env`; also usable directly:

```bash
palworld-config-parser                                  # ./Pal/Saved/.../PalWorldSettings.ini from env
palworld-config-parser --config FILE --env-file FILE    # explicit paths
palworld-config-parser --dry-run                        # report without writing
```

**How env names map to INI keys:** instead of a hardcoded table of ~90 mappings,
keys are resolved against the keys *present in the live config* — compared with
underscores removed, case-insensitively, and allowing Unreal's `b` boolean prefix.
So `PAL_AUTO_HP_REGENE_RATE` finds `PalAutoHPRegeneRate`, `IS_PVP` finds `bIsPvP`,
and keys added by future game updates work with no code change. Only genuinely
irregular names (`MAX_PLAYERS` → `ServerPlayerMaxNum`, `SERVER_PORT` →
`PublicPort`, `ENABLE_ENEMY` → `bEnableInvaderEnemy`, …) need the small
`EXCEPTIONS` table.

**Safety:** only keys whose env var is set are touched (every other byte is
preserved); each value keeps its existing shape, with the live file acting as the
schema — quoted strings stay quoted and escaped, booleans stay `True`/`False`,
numbers stay numeric, and Palworld's bare enums (`Difficulty=None`) stay bare
tokens. A value that would corrupt the config is **rejected with a warning**
rather than written. Secret values (`AdminPassword`, `ServerPassword`) are applied
but never printed.

**Known limitation:** tuple-valued settings (`CrossplayPlatforms=(Steam,Xbox,…)`)
are parsed and preserved intact but cannot be *changed* by this tool; edit them by
hand or via the web UI.

> This replaced a prebuilt AGPL binary from
> [pelican-eggs/Palworld-Config-Parser-Tool](https://github.com/pelican-eggs),
> which established the interface. See [`CREDITS.md`](../CREDITS.md).

---

## systemd units & timers

Installed to `/etc/systemd/system`. Enable only what you need.

| Unit | Type | Schedule | Runs |
|------|------|----------|------|
| `palworld.service` | service | — | The dedicated server (`PalServer.sh`). |
| `palworld-config-webui.service` | service | — | `palwarden-webui --serve` on `127.0.0.1:8088`: the dashboard, the config editors and the JSON API, unprivileged (hardened: `ProtectSystem=strict`, etc.). |
| `palwarden-jobd.service` | service | — | Root worker that executes the jobs the web UI queues. Lightly sandboxed — `ProtectSystem=true` only, since it must keep writing `/etc/palworld`, the game config under `/opt/palworld` and `/var/lib/palworld`; enable it alongside `palworld-config-webui.service` or queued jobs never run. |
| `palworld-fps-sample.timer` | timer | every 15s (after boot+1m) | `palworld-fps sample --retention-days 7` under a lock. |
| `palworld-fps-daily-report.timer` | timer | 09:00 daily | `palworld-health-report discord --window 24h`. |
| `palworld-update-check.timer` | timer | every 30m | `palworld-update` under a lock. |
| `palworld-memory-watch.timer` | timer | every 5m | `palworld-memory-watch --threshold 85 --wait 300`. |
| `palworld-public-info-watch.timer` | timer | every 10m | `palworld-public-info-watch`. |
| `palworld-service-events.timer` | timer | every 1m | `palworld-service-events sample` — detects restarts/outages. |
| `palworld-backup-auto.timer` | timer | every 15m | `palworld-backups --if-due --prune` under a lock, as **root**. The tick is fixed; the *schedule* is `/etc/palworld/backup.env` (editable from the Backups page), so changing how often you back up needs no `daemon-reload`. Hardened like `palwarden-jobd.service` — `ProtectSystem=true` only, because it must write `/opt/palworld/backups`. |
| `palworld-1dot0-watch.timer` | timer | every 1m *(dated)* | `palworld-launch-watch`. Inert; do not enable. |

Each `*.timer` has a matching one-shot `*.service`. After changing any unit:
`sudo systemctl daemon-reload`.
