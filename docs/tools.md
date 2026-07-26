# Tool reference

Every command, library, and unit in `palwarden`, grouped by function. Installed
paths are shown; in the repo they live under `sbin/`, `lib/`, `bin/`, and
`systemd/`. All admin commands generally require `sudo` (they read secret env
files, talk to the REST API, and touch `palworld`-owned files).

- [Lifecycle](#lifecycle)
- [REST API helpers](#rest-api-helpers)
- [Configuration](#configuration)
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
`/usr/local/sbin/palworld-config-apply-env [--no-protect]`

Reads `/etc/palworld/settings.env`, backs up the current `PalWorldSettings.ini`
to `/opt/palworld/config-backups/`, then applies every setting (passwords
included) via `palworld-config-parser`. Regenerates the pretty INI, posts a
redacted diff + settings summary, and records a config event marker.
**Requires a service restart to take effect.**

**Overwrite protection:** Palworld rewrites its own config when the server shuts
down, silently reverting managed settings. So the flow is *unlock → write →
relock*: the file is left **immutable (`chattr +i`)** after a successful apply
(and relocked even if a later step fails). `--no-protect` leaves it mutable. Use
[`palworld-config-protect`](#palworld-config-protect) for manual control. Where
the immutable bit is unavailable — a container without `CAP_LINUX_IMMUTABLE` —
this degrades to a warning and the config is still written.

### `palworld-config-protect`
`/usr/local/sbin/palworld-config-protect {status|lock|unlock}`

Manual control of the immutable bit on `PalWorldSettings.ini` — the counterpart
to `palworld-engine-config lock|unlock` for Engine.ini. `unlock` before editing
the file by hand; `apply-env` handles locking automatically. Reports and exits 0
(rather than failing) where the immutable bit is unavailable.

### `palworld-engine-config`
`/usr/local/sbin/palworld-engine-config {apply|status|rollback|lock|unlock|pretty|diff|template} [...]`

Manages `Engine.ini` performance levers from `/etc/palworld/engine.env`
(tick rate, client/bandwidth limits, streaming/async options). `apply` backs up
and writes managed values; `status` shows managed values + nearest profile match,
the immutable state, and (`--check`) flags drift; `rollback` restores a prior
backup. Records event markers. Reminds you to `graceful-restart` — it never
restarts on its own.

**Overwrite protection:** like the settings file, `Engine.ini` is left
**immutable (`chattr +i`)** after `apply`/`rollback` so the server cannot revert
it on shutdown (`--no-protect` opts out). `lock` / `unlock` give manual control.
Unavailable immutability (container without `CAP_LINUX_IMMUTABLE`) degrades to a
warning — the config is still written.

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

Compares host RAM used% and the `palworld.service` cgroup memory against a
threshold (default 85%). Over the line, it warns to Discord and triggers a
`graceful-restart` (under a `flock`). No-ops if the service is down. Timer: every
5 min.

### `palworld-public-info-watch`
`/usr/local/sbin/palworld-public-info-watch`

Reads `ServerPassword`/`PublicPort` from the live config and the current public
IP, and if the join info changed since `/var/lib/palworld/public-info.env`,
rewrites that file (mode 0600) and posts the new IP/port/password to Discord.
Timer: every 10 min.

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
- **`palworld-fileattr`** — sourced shell helpers for the Linux immutable bit
  (`fileattr_is_immutable`, `fileattr_set_immutable`, `fileattr_supported`). Used
  by `palworld-config-apply-env` / `palworld-config-protect`. Degrades gracefully
  (warn once, report "not immutable") where `chattr`/`lsattr` or
  `CAP_LINUX_IMMUTABLE` are unavailable, so a missing immutable bit never blocks
  a config write.

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
| `palworld-config-webui.service` | service | — | Local-only static config editor on `127.0.0.1:8088` (hardened: `ProtectSystem=strict`, etc.). |
| `palworld-fps-sample.timer` | timer | every 15s (after boot+1m) | `palworld-fps sample --retention-days 7` under a lock. |
| `palworld-fps-daily-report.timer` | timer | 09:00 daily | `palworld-health-report discord --window 24h`. |
| `palworld-update-check.timer` | timer | every 30m | `palworld-update` under a lock. |
| `palworld-memory-watch.timer` | timer | every 5m | `palworld-memory-watch --threshold 85 --wait 300`. |
| `palworld-public-info-watch.timer` | timer | every 10m | `palworld-public-info-watch`. |
| `palworld-1dot0-watch.timer` | timer | every 1m *(dated)* | `palworld-launch-watch`. Inert; do not enable. |

Each `*.timer` has a matching one-shot `*.service`. After changing any unit:
`sudo systemctl daemon-reload`.
