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
- [Test tiers](#test-tiers)

---

## Lifecycle

### `palworld-graceful-stop`
`/usr/local/sbin/palworld-graceful-stop [--wait SECONDS] [--message TEXT]`

Saves the world (REST API), issues a timed API shutdown with a player notice
(default 300s), then waits for `palworld.service` to go inactive. No-ops if the
service isn't active. Notifies on completion/timeout.

### `palworld-graceful-restart`
`/usr/local/sbin/palworld-graceful-restart [--wait S] [--empty-wait S] [--message T] [--empty-message T] [--startup-timeout S] [--apply-config] [--apply-engine]`

The preferred way to restart once the REST API is live. Checks current player
count via the API and picks a short `--empty-wait` (default 15s) when the server
is empty, otherwise the full `--wait` (300s). Runs `graceful-stop`, starts the
service, waits for systemd `active`, then waits for REST API readiness before
declaring success. Records `graceful restart requested` / `completed` event
markers. **Prefer this over `systemctl restart palworld.service`.**

`--apply-config` / `--apply-engine` run `palworld-config-apply-env` /
`palworld-engine-config apply` in the window where the server is fully stopped
— the only moment an apply is safe: the game rewrites its config files from
memory as it exits, so an apply issued while it still runs is silently
clobbered mid-shutdown (observed on v1.0.3). A failed apply never leaves the
server down — it is started regardless and the script exits nonzero so the
caller sees the apply failed.

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

The schedule lives in a **file** (`PALWORLD_BACKUP_SCHEDULE`), not in a unit, and
the services fire on a short fixed tick that asks this tool whether anything is
due. That is what lets one implementation serve systemd and s6, lets the interval
be changed from the browser with nothing to reload, and lets a host that was
powered off back up on the first tick after boot instead of missing a window. A bad
value in that file is therefore **never fatal**: it warns on stderr and falls back
to that key's default (the default, not the nearest bound —
`BACKUP_RETENTION_DAYS=3560` where `356` was meant gives 14 days and a warning, not
a silently accepted decade).

The default is `/etc/palworld/backup.env`, which is where it stays on bare metal;
**the container points the variable at `/var/lib/palworld/backup.env`** (its state
volume) instead, because `/etc/palworld` there is rendered into the writable layer,
so a `docker compose up` reverted a schedule the operator had saved and the next
prune then applied the reverted retention. See
[`../docker/README.md`](../docker/README.md).

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
  aborts; extract into `Pal/Saved.restore-<stamp>` **beside** the target, then swap
  the target's **contents** — move `Pal/Saved`'s entries into
  `Pal/Saved.replaced-<stamp>` and the extracted tree's entries in;
  `chown -R` to `PALWORLD_USER`/`PALWORLD_GROUP`; start the service and wait for
  REST readiness (`--startup-timeout`, default 180s — the same check
  `graceful-restart` uses).

  The replaced tree is **deleted only on a confirmed startup**, and the three
  endings are distinct — two of them succeed:

  | Ending | Exit | Replaced tree | Means |
  |--------|:----:|---------------|-------|
  | `started: ... the REST API is healthy.` | 0 | **deleted** | `palworld-api info` answered, so the world is restored *and* the server is confirmed up. The safety archive stays. |
  | `readiness could NOT be verified` | 0 | **kept** | The REST API is not configured (`palworld-api` exit 2 — no `ADMIN_PASSWORD`, API disabled), so nothing could confirm the startup. The world **was** restored; the previous world stays at `Pal/Saved.replaced-<stamp>` precisely because the startup is unconfirmed. |
  | `the startup is not confirmed` / start failed | 1 | **kept** | REST *was* configured and never became ready within `--startup-timeout`, or `systemctl start` failed. The world has already been replaced. |

  The middle row is the normal ending of a disaster-recovery restore on a rebuilt
  host, where nothing has set `ADMIN_PASSWORD` yet. It is a success, but it leaves
  **a full second copy of the world** on disk (printed as `kept: ...`); remove it
  by hand once the server is known good. Both keeping cases print the replaced
  tree's path alongside the safety archive's name, so there are two routes back.

  The scratch dir lives under `/opt/palworld` and not next to the uploads dir
  because `/var/lib/palworld` is 0755 **service-account-owned** on both
  platforms: a "root-only" directory inside it is not root-only. The tool
  `fstat`s the directory it opened and refuses one it does not own or that has
  any group/other bits, holds that descriptor for the whole restore, and refuses
  if the scratch copy's inode changes between validation and extraction.

  Any `Pal/Saved.replaced-*` **or** `Pal/Saved.restore-*` trees left by earlier
  restores are **listed at the start** of a restore (named only — never sized,
  never deleted), because each is a full world save and nothing else ever mentions
  them again.

  **The swap moves contents, not the directory, and is therefore not atomic.**
  `Pal/Saved` is a *mount point* in every Docker deployment (a named volume in
  `docker/compose.yaml`, a bind mount in `docker/compose.live.yaml`) and
  `rename(2)` on a mount point is `EBUSY`, so renaming the directory — which is
  what this used to do — could not succeed in any container. Moving the entries
  works for a mount point and an ordinary directory alike, so bare metal and every
  container share one code path; where the two directories are under different
  *mounts* (which is exactly the mount-point case) each move falls back to a copy on
  `EXDEV`, as `shutil.move` does.

  **Free space, in the container: budget about 2× the world on the *server*
  volume.** With `docker/compose.yaml`'s layout the extracted staging tree and the
  replaced world tree both land beside `Pal/Saved` — that is the **server** volume
  — while the restored world is copied *into* the `Saved` volume, so a
  containerised restore holds a full extracted copy and a full replaced copy on the
  server volume at the same time, plus one world's worth on the Saved volume.
  Bare metal renames instead and needs none of it. `ENOSPC` is consequently the
  most likely way a swap fails, and a swap that fails partway is the mixed-tree
  state below, so each cross-mount move is preceded by a `statvfs` check of the
  destination against everything that phase still has to move (plus
  `PALWARDEN_IMPORT_FREE_HEADROOM`) and **refuses before anything moves** if it will
  not fit. A move that renames is not checked at all, because a rename consumes no
  space.

  Every destination the copy path creates is created **through the destination
  directory's descriptor** with a call that fails on an existing name
  (`O_CREAT|O_EXCL|O_NOFOLLOW`, `mkdir`, `symlink`), so a name already occupied in
  `Pal/Saved` — which the service account can create at any time — is a refusal and
  never a write through someone else's symlink. A copy that fails partway has its
  half-written **destination** entry removed before the failure is reported, so both
  directories hold only whole entries and the recovery instructions below are safe
  to follow literally. The ownership pass then walks the restored tree through
  descriptors (`os.fwalk` + `chown(..., dir_fd=…, follow_symlinks=False)`) and
  **refuses any non-directory entry with more than one hard link**: `Pal/Saved` is
  writable by the service account throughout the swap, and a hardlink planted in it
  resolves to its target inode through a descriptor exactly as it does through a
  path.

  The cost of moving entries is that a failure **partway** can leave
  `Pal/Saved` holding part of one world and part of another, where a directory
  rename could only fail before or after. Every such failure prints exactly which
  state the tree is in, which top-level entries are in which directory (by name),
  the replaced tree's path,
  the staging tree's path when it still holds entries, and the safety archive's
  name — a mixed tree must not be started on, and the output is what says so.

`--restore` is **refused in `PALWARDEN_MODE=external`**: the game runs on another
host, so `systemctl is-active` (via the shim's `pgrep` fallback) cannot see it,
and a stop that failed against a *live* server would read as "already stopped"
and the world would be replaced underneath it. Stop and restore on the host that
runs the server.

Designed for disaster recovery, so it never assumes existing state: a missing or
empty `Pal/Saved` and a server that is already down are both normal. The operator
procedure for the whole loop — download an archive off the host, upload it back,
import, restore — is
[`palworld-service-runbook.md`](palworld-service-runbook.md) §15.

### Backup-family environment overrides

Defaults are the installed bare-metal paths; the container overrides the ones it
needs in `docker/compose.yaml` and `docker/entrypoint.sh`. All are read by `palworld-backup`,
`palworld-backups`, `palworld-restore`, `palwarden-webui` or
[`palwarden_archive`](#libraries) — one variable moves every tool that touches the
same directory.

| Variable | Default | What |
|----------|---------|------|
| `PALWARDEN_SAVE_BACKUP_DIR` | `/opt/palworld/backups` | The archives directory, root-owned `0755`. Moves the writer, the lister, the importer and the pruner together. (`PALWORLD_BACKUP_DIR` is a different thing — *config* backups.) |
| `PALWARDEN_UPLOAD_DIR` | `/var/lib/palworld/uploads` | Upload staging, service-account-owned `0700`. |
| `PALWARDEN_RESTORE_SCRATCH` | `/opt/palworld/restore-scratch` | The root-only `0700` scratch dir `--restore` validates from. Must be root-owned **under a root-owned parent**, or the restore refuses. |
| `PALWORLD_BACKUP_SCHEDULE` | `/etc/palworld/backup.env` | The schedule file. `/var/lib/palworld/backup.env` in the container. |
| `PALWORLD_SAVED_DIR` / `PALWORLD_INSTALL_DIR` | `/opt/palworld/server` + `/Pal/Saved` | The live world tree, resolved identically by `palworld-backup` and `palworld-restore`. A *set but empty* `PALWORLD_SAVED_DIR` is honoured. |
| `PALWORLD_USER` / `PALWORLD_GROUP` | `palworld` (container: `steam`) | Who the restored tree is chowned to. An unresolvable name warns and leaves ownership alone rather than failing the restore. |
| `PALWARDEN_IMPORT_MAX_BYTES` | 8 GiB | Ceiling on the *compressed* size one `--import` may promote. |
| `PALWARDEN_IMPORT_FREE_HEADROOM` | 64 MiB | Free space required on the backups filesystem *beyond* the archive, so a promotion cannot leave `palworld-backup` no room. |
| `PALWARDEN_RESTORE_MAX_BYTES` | 8 GiB | Ceiling on the compressed size copied into the scratch dir. |
| `PALWARDEN_RESTORE_STARTUP_TIMEOUT` | 180 | Readiness bound after the restart, when `--startup-timeout` is not given. |
| `PALWARDEN_RESTORE_POLL_SECONDS` | 3 | Readiness poll interval. |
| `PALWARDEN_MODE` | *(unset)* | `embedded` / `external`, set by the compose stack. Unset on bare metal. `--restore` refuses in `external`. |

A malformed or non-positive value for any of the byte/second limits is **ignored
with the default used**, never treated as "no limit" or as zero
([`palwarden_archive.env_int`](#libraries)).

`PALWARDEN_SBIN_DIR`, `PALWARDEN_SYSTEMCTL_BIN`, `PALWARDEN_JOBD_BIN`,
`PALWARDEN_PARSER_BIN`, `PALWARDEN_WEBUI_ENV` and `PALWARDEN_WEBUI_ROOT` exist so
the suites can point a tool at stubs and so packaging can relocate it; they are
**not operator knobs** and are not documented per-tool.

---

## REST API helpers

The Palworld REST API authenticates with HTTP Basic `admin` + **`ADMIN_PASSWORD`**
(from `settings.env`), not `SERVER_PASSWORD`. All of these require
`REST_API_ENABLED=True` and a non-empty `ADMIN_PASSWORD`.

### `palworld-api`
`/usr/local/sbin/palworld-api {save|stop [seconds] [message]|info|metrics|players}`

Low-level client against `127.0.0.1:${REST_API_PORT}`. `info` returns
server/version JSON; `metrics` returns FPS/player/uptime JSON used by the
sampler and restart logic; `players` returns the online-players list
(name, playerId, userId/SteamID, level — plus ip/ping/location, which the
presence recorder deliberately does not store).

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
included) via `palworld-config-parser`. If the web editor has saved overrides
(`PALWORLD_SETTINGS_OVERRIDES`, default `/etc/palworld/settings-overrides.env`,
written by `palwarden-jobd`'s `settings_save`), those are applied in a second
parser pass **after** `settings.env`, so a value saved in the browser wins over
its `PALWORLD_CFG_*` variable; one backup and one diff cover both passes.
Regenerates the pretty INI, posts a redacted diff + settings summary, and
records a config event marker. **Requires a service restart to take effect.**

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

Serves the web UI and the JSON API on `127.0.0.1:8088`
(`PALWARDEN_WEBUI_BIND`/`PALWARDEN_WEBUI_PORT`; keep the bind loopback — see the
tunnel note below). A non-loopback bind serves reads but refuses every mutation
with a 403 (the Origin check accepts only loopback hosts) unless the operator
also sets **`PALWARDEN_WEBUI_ORIGIN_HOSTS`** — a comma-separated allowlist of
exact hostnames/IPs (compared case-insensitively against the Origin's host,
never scheme or port) whose pages are then trusted like localhost's. List only
names that resolve to this machine on a network you trust (a VPN/tailnet name,
a LAN address); Basic auth, the token, and the `Sec-Fetch-Site` check still
apply, and unlisted (including DNS-rebound) names are still refused. **Every path requires
HTTP Basic auth**, including the vendored editor, using credentials in
`/etc/palworld/webui.env` (`--init-credentials` generates them once, as root, and
never overwrites an existing file; `install.sh` and the container entrypoint call
it for you). With no arguments it prints help and exits — the service uses
`--serve`.

Read endpoints (Basic auth is enough): `/api/health`, `/api/fps`, `/api/events`,
`/api/service-events`, `/api/playtime` (the sampler's per-player presence
rollup, feeding the Players tab), `/api/player-stats` (the save-derived stats
snapshot, also feeding the Players tab; read codec-free via
`palworld-player-stats show`), `/api/engine`, `/api/config` (passwords redacted),
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

`GET /api/fps/graph?window=1h&theme=dark` renders the same two-panel PNG
`palworld-fps` posts to Discord and answers it as `image/png`
(`Cache-Control: no-store`). `window` is allowlisted to `1h | 4h | 12h | 24h |
7d` and `theme` to `light | dark` (anything else falls back to `1h` / `light`);
the dashboard sends its own `body[data-theme]` and re-renders on a theme flip.
Each request is a fresh `palworld-fps graph` subprocess, which is why
the dashboard refreshes this on demand rather than on its 15 s loop. A failed
render (typically "no successful FPS samples" on a fresh install) is answered in
the house JSON shape, and the dashboard shows the tool's message in place of the
image.

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
the telemetry DB). That `413` is the **HTTP request** cap and is not the only one
in the loop: root refuses to promote a staged file over `PALWARDEN_IMPORT_MAX_BYTES`
(default 8 GiB, compressed) when the `backup_import` job runs, and neither is the
decompression-bomb cap ([`palwarden_archive`](#libraries), on the *uncompressed*
size). The upload path uses its own socket timeout
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
`backup`, `mark`, `engine_save`, `settings_save`, `backup_import`,
`backup_schedule_save` (file-only) and `graceful_restart`, `graceful_stop`,
`update_check`, `update_apply`, `engine_rollback`, `api_save`,
`engine_save_apply_restart`, `settings_save_apply_restart`, `backup_restore`,
`backup_delete` (disruptive, `confirm: true` required).
Composite actions stop at the first failure — a failed save or apply never reaches
the restart. Output is captured combined and capped.

`settings_save` is the PalWorldSettings twin of `engine_save`: it validates every
requested key and value against the shapes actually present in the live
`PalWorldSettings.ini` (using `palworld-config-parser`'s own resolver and
renderer, so a value the apply would drop is refused at the form instead),
refuses `AdminPassword`/`ServerPassword` outright (those stay managed via
`settings.env`) and `RESTAPIEnabled`/`RESTAPIPort` too (the REST API is the
control plane's own lifeline — a saved `RESTAPIEnabled=False` would ride the
overrides file, win over `settings.env` on every boot, and permanently cut off
telemetry, graceful save-on-stop and updates; it stays managed via
`ADMIN_PASSWORD`/`PALWORLD_REST_PORT`), and merge-writes
`PALWORLD_SETTINGS_OVERRIDES`.
`settings_save_apply_restart` chains that write with a
`palworld-graceful-restart --apply-config`, which runs the apply after the
server has fully stopped (applying while it runs is lost work — the game
rewrites its config from memory on exit). `engine_save_apply_restart` uses
`--apply-engine` the same way.

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
| `sample [--retention-days N] [--presence-retention-days N]` | Pull one FPS/player sample from the REST API and store it (driven by the 15s timer). Also records **player presence**: an identity row per player (uid, SteamID, latest name/level, first/last seen, total playtime) and grace-window sessions (`PALWARDEN_PRESENCE_GRACE_MS`, default 60s). The two REST calls fail independently and never change the exit code — an outage is a gap in observation, not an error. Sessions are pruned after 90 days by default; identities and their playtime totals never are. `ip`/`ping`/`location` from the API are deliberately not stored. |
| `report [--window 24h] [--graph FILE.png]` | Text stats (avg / 1% low / 0.1% low, player avg/max) over a window; optional two-panel PNG (FPS + player count) with event markers. |
| `graph --output FILE.png [--window 1h] [--theme light\|dark]` | Render only the PNG — no stats, no live REST fetch. The window is any duration (`1h`, `4h`, `12h`, …), not just the report presets, and `--theme dark` draws on the web UI's dark card surface (Discord keeps the light default); this is what `GET /api/fps/graph` shells out to. |
| `playtime [--json]` | Per-player presence rollup: identity, session count, total playtime, last-7-days playtime (sessions clamped to the window), online-now. Playtime is observed by the sampler — time before the first observed login is not included. |
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

### `palworld-player-stats`
`/usr/local/sbin/palworld-player-stats <subcommand>` — Python 3, owns
`/var/lib/palworld/player-stats.json` (override:
`PALWARDEN_PLAYER_STATS_FILE`). Parses `Players/<uid>.sav` from the world
save (resolved via `PALWORLD_SAVED_DIR` / `PALWORLD_INSTALL_DIR`, same
precedence as the backup family) into per-player **save-derived stats**:
captures, paldeck, crafts, fish, towers/bosses/dungeons, camps, fast travels,
relics, notes. Spec:
`docs/superpowers/specs/2026-08-18-player-stats-board-design.md`.

| Subcommand | Purpose |
|------------|---------|
| `refresh [--snapshot FILE]` | Re-parse players whose `.sav` mtime changed (ns precision) and rewrite the snapshot atomically; unchanged players cost a `stat()`. Reads **copies**, never live files, retrying once on a torn read — a still-torn file degrades to `unreadable` and keeps its previous good stats. Always exits 0: no/multiple world dirs and a missing codec are snapshot `status`/`degraded_reason`, not failures. Driven every 60s by `palworld-player-stats.timer` / the `player-stats` s6 service. |
| `show [--json]` | Print the snapshot. Never touches the save codec, so it works (reporting the degraded state) even without pyooz. `GET /api/player-stats` shells out to this. |
| `dump FILE.sav` | Introspect one save: RecordData keys and shapes, plus parse errors. The tool that pins property names when a game update shifts the format. |

The snapshot keeps both `stats` (the aggregates the Players page renders) and
`records` (the raw per-key ledgers — boss flags, per-item craft counts —
retained for the future Discord milestone diffing, backlog item 10).

**Optional dependency:** the game compresses saves with Oodle (`PlM` magic)
since ~0.6; decompression needs **pyooz** (GPL-3.0-or-later, see
`CREDITS.md`). The Docker image installs it when built with
`WITH_PLAYER_STATS=true` (the default). On bare metal:
`pip install pyooz` (Debian/Ubuntu: `pip install --break-system-packages pyooz`,
or use a venv and point the timer's ExecStart at its python). Without it the
tool still runs and the Players page shows
`Save-derived stats unavailable: … pyooz is not installed …`. The parser
degrades per-field on unknown properties instead of crashing, so a game
update dulls the board rather than breaking it.

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
- **`palwarden_archive`** — Python module (`palwarden_archive.py`) holding the
  **one** copy of the world-save archive rules, imported by `palwarden-webui`,
  `palwarden-jobd`, `palworld-backups` and `palworld-restore` so the name the web
  process will stage and the name root will unpack cannot drift apart. Import is
  **round-trip only**: `ARCHIVE_RE` accepts nothing but
  `palworld-save-<8 digits>T<6 digits>Z.tar.gz`, and every member must be a plain
  file or directory under `SaveGames/` or `Config/` — no absolute paths, no `..`,
  no symlinks, hardlinks, devices or FIFOs; extraction additionally runs under
  tarfile's `filter="data"`. Archives are opened `O_NOFOLLOW|O_NONBLOCK` and must
  be regular files, so a symlink or a planted FIFO cannot choose what root reads
  or block it forever. The **decompression-bomb caps** live here and are checked
  while reading headers, before anything is written:
  `PALWARDEN_ARCHIVE_MAX_MEMBERS` (default 200000 members) and
  `PALWARDEN_ARCHIVE_MAX_BYTES` (default 20 GiB *uncompressed*) — distinct from
  the compressed-size caps in
  [Backup-family environment overrides](#backup-family-environment-overrides).
  `env_int` is its public reader for all of them: a malformed or non-positive
  override falls back to the default, so a typo can never lower a ceiling to zero.
- **`palwarden_gvas`** — Python module (`palwarden_gvas.py`): reads Palworld's
  `.sav` container (`PlZ` = zlib via stdlib; `PlM` = Oodle via the optional
  pyooz codec, lazily imported) and the GVAS property tree inside, with
  **per-field degradation** — unknown or corrupt properties are recorded and
  skipped by their known extents, siblings survive. Imported by
  `palworld-player-stats`; written against the wire format with
  palworld-save-tools (MIT) as reference (see `CREDITS.md`).
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
| `palworld-player-stats.timer` | timer | every 1m (after boot+2m) | `palworld-player-stats refresh` under a lock, as **palworld** (reads saves, writes only `/var/lib/palworld`). Idle passes are `stat()` calls; the snapshot tracks every autosave within a minute. |
| `palworld-1dot0-watch.timer` | timer | every 1m *(dated)* | `palworld-launch-watch`. Inert; do not enable. |

Each `*.timer` has a matching one-shot `*.service`. After changing any unit:
`sudo systemctl daemon-reload`.

---

## Test tiers

Three tiers, one runner. Lint is separate.

```bash
./tests/lint.sh                     # shellcheck + python py_compile
./tests/run.sh                      # tier 1: unit only (default)
./tests/run.sh --integration        # + tier 2: docker container scenarios
./tests/run.sh --live               # + tier 3: a REAL Palworld server
```

`RUN_INTEGRATION=1` and `RUN_LIVE=1` are equivalent to the two flags, for CI and
`make`-style callers. Both tiers are additive — `--live` runs unit *and* live, so
`--integration --live` runs all three.

| Tier | Gate | In CI | Server under test | Suites |
|------|------|-------|-------------------|--------|
| Unit | default | yes | stubs | `tests/unit/test_*.sh` |
| Integration | `--integration` / `RUN_INTEGRATION=1` | yes | `tests/fixtures/fake-server` (a shell script pretending to be the game) in a real container | `tests/integration/test_*.sh` |
| **Live** | `--live` / `RUN_LIVE=1` **and** a marker file | **no** | the real game, on a throwaway bind mount | `tests/live/test_*.sh` |

Integration and live both need `docker`; when it is missing the runner says so and
skips rather than failing. When the live tier is skipped it prints how to enable it,
because a tier nobody knows exists is a tier nobody runs.

### The live tier does not run in CI

Deliberately, and it is not a gap to be closed. There is no ~8–10 GB game install
on a runner, and the whole point is that **CI stays hermetic**: this project has
already had an integration suite write into a persistent bind-mounted fixture, so
each run pre-seeded the next — a fresh clone would have failed and one assertion was
passing over a *failed* backup. Persistence hid a real defect for two tasks. The
hermetic suites stay the merge gate; the live tier is a **local fidelity check** you
run before trusting something on a real host. See
[`docs/superpowers/specs/2026-07-28-live-test-tier-design.md`](superpowers/specs/2026-07-28-live-test-tier-design.md).

What it covers — the paths a stub server cannot exercise:

| Suite | What only a real game can answer |
|-------|----------------------------------|
| `tests/live/test_restore_roundtrip.sh` | `backup_restore` end to end: stop, extract, swap by rename, chown, start, REST readiness — and the world actually reopens. |
| `tests/live/test_stop_consistency.sh` | A graceful stop's `SIGINT` produces a world the game loads again; and `palworld-backups --if-due` against a real `Pal/Saved` produces an archive that really unpacks. |
| `tests/live/test_config_drift.sh` | The **semantic** drift comparison (`True` == `1`, `60.000000` == `60`) surviving the game's own rewrite of `Engine.ini`, applied `PalWorldSettings.ini` values surviving it too (with secrets still redacted), and `update_check` against real Steam. |

### One-time setup

The testbed is a disposable directory **outside the repository tree**, holding the
game install and the world. It persists between runs, so the multi-GB download
happens once.

```bash
# 1. Create it and declare it disposable. The marker is not optional: the live tier
#    stops the server, deletes worlds and restarts it, so it refuses to touch any
#    directory that is not marked. A mistyped path is the one accident that would
#    actually hurt, and a real deployment will not have this file.
export PALWARDEN_LIVE_TESTBED="$HOME/palworld-testbed"   # also the built-in default
mkdir -p "$PALWARDEN_LIVE_TESTBED/server/Pal/Saved"
touch "$PALWARDEN_LIVE_TESTBED/.palwarden-live-testbed"

# 2. Give the stack an admin password (docker/.env or the environment). The live
#    tier drives the server through its REST API, which the game only enables when
#    ADMIN_PASSWORD is set — without one, readiness could never be reached.
grep -q '^ADMIN_PASSWORD=.' docker/.env 2>/dev/null \
  || echo "ADMIN_PASSWORD=pick-something" >> docker/.env

# 3. Install the game — ONCE. The overlay pins UPDATE_ON_START=false so ordinary
#    runs start in seconds; this is the only invocation that sets it true. ~8-10 GB
#    via SteamCMD; no suite ever does this for you.
UPDATE_ON_START=true COMPOSE_PROFILES=embedded \
  PALWARDEN_LIVE_TESTBED="$PALWARDEN_LIVE_TESTBED" \
  docker compose -p palwarden-live --project-directory docker \
    -f docker/compose.yaml -f docker/compose.live.yaml up -d --build

# ...watch it install and boot, which takes a while:
docker compose -p palwarden-live --project-directory docker \
  -f docker/compose.yaml -f docker/compose.live.yaml logs -f palwarden

# 4. Then run the tier. The suites bring the stack up and down themselves.
./tests/run.sh --live
```

The `-f docker/compose.yaml -f docker/compose.live.yaml` overlay is what swaps the
`palworld-server` and `palworld-saved` **named volumes** for bind mounts into the
testbed; `docker/compose.yaml` is left untouched, so nothing about a real deployment
changes. The `-p palwarden-live --project-directory docker` pair is exactly what
`tests/live/lib/testbed.sh` passes, and it is worth copying rather than relying on
the overlay's `name:` — `COMPOSE_PROJECT_NAME`, from the environment *or* from
`docker/.env`, overrides `name:`, and `-p` is the only reliable pin. Ports come from
`compose.yaml`, so a real deployment already listening on 8088/8211 makes the live
`up` fail loudly instead of quietly sharing state.

Web UI credentials need no setup: the suites read the generated ones out of
`/etc/palworld/webui.env` in the running container, and honour pinned
`WEBUI_USER`/`WEBUI_PASSWORD`/`WEBUI_TOKEN` if you have set them.

### Refusals

Every mutating helper in `tests/live/lib/testbed.sh` checks the testbed first, and
each refusal carries a stable code plus the command that fixes it:

| Code | Meaning |
|------|---------|
| `LIVE_E_NO_TESTBED` | `$PALWARDEN_LIVE_TESTBED` does not exist. |
| `LIVE_E_UNMARKED` | It exists but has no `.palwarden-live-testbed` marker. |
| `LIVE_E_OWNER_UID` | The testbed, `server/`, or `server/Pal/Saved` is owned by the wrong uid — the container's `steam` account is uid **1000**, and a testbed it cannot write to surfaces later as a corrupt-looking save. `sudo chown -R 1000 "$PALWARDEN_LIVE_TESTBED"`, or set `PALWARDEN_LIVE_EXPECT_UID`. |
| `LIVE_E_NOT_INSTALLED` | No `server/PalServer.sh` — step 3 above has not been done. |
| `LIVE_E_NOT_EXECUTABLE` | `PalServer.sh` lost its exec bit (a restore from a tar that dropped modes). `chmod +x` it. |
| `LIVE_E_NO_ADMIN_PASSWORD` | Step 2 above. Set-but-empty in the environment counts, and beats `docker/.env`. |
| `LIVE_E_COMPOSE_UP` | `docker compose up` itself failed; its output is above the refusal. |

The guard is exercised by `tests/unit/test_live_guard.sh`, which runs in ordinary CI
with neither a game nor Docker: a destructive suite's safety check cannot be verified
only by a tier nobody runs automatically.

### Knobs

All optional; the defaults are what the suites use.

| Variable | Default | What |
|----------|---------|------|
| `PALWARDEN_LIVE_TESTBED` | `$HOME/palworld-testbed` | The testbed directory. |
| `PALWARDEN_LIVE_EXPECT_UID` | `1000` | The uid the testbed must be owned by. |
| `PALWARDEN_LIVE_PROJECT` | `palwarden-live` | Compose project name. |
| `PALWARDEN_LIVE_REPO` | derived from the suite's path | Repo root, so the helpers can be sourced from anywhere. |
| `PALWARDEN_LIVE_WEBUI_PORT` | asked of compose after `up` | Published host port for the web UI. |
| `PALWARDEN_LIVE_WEBUI_USER` | `$WEBUI_USER`, else `admin` | Web UI username. |
| `PALWARDEN_LIVE_WEBUI_PASSWORD` / `_TOKEN` | `$WEBUI_PASSWORD` / `$WEBUI_TOKEN`, else read from `/etc/palworld/webui.env` in the container | Web UI password and CSRF token. |
| `PALWARDEN_LIVE_UP_TIMEOUT` | `420` | Seconds to wait for REST readiness. |
| `PALWARDEN_LIVE_JOB_TIMEOUT` | `300` | Seconds for an ordinary job to settle. |
| `PALWARDEN_LIVE_RESTORE_TIMEOUT` | `900` | The restore job (stop + extract + cold start + readiness poll). |
| `PALWARDEN_LIVE_STOP_TIMEOUT` | `420` | The graceful stop in `test_stop_consistency.sh`. |
| `PALWARDEN_LIVE_RESTART_TIMEOUT` | `420` | The graceful restart in `test_config_drift.sh`. |
| `PALWARDEN_LIVE_UPDATE_TIMEOUT` | `600` | `update_check` against real Steam. |

Every wait in the tier is bounded: a live suite that hangs is worse than one that
fails, because nobody watches it long enough to notice.

### World drift, and the escape hatch

There is **no** pristine-world snapshot and no reset between runs. The world
accumulates play state, and a suite that failed halfway leaves it drifted — both are
expected and harmless, because every live assertion is written against an artefact
the same run created (a marker carrying a fresh nonce, a private backups directory,
a config value the run chose to differ from what was on disk), never against an
assumed world state or file list.

When a half-finished run leaves the testbed in a state not worth reasoning about,
throw the world away and keep the expensive install:

```bash
cd /path/to/palwarden
source tests/live/lib/testbed.sh
live_down          # stop the stack first — the game holds the save open and would
                   # write it back out on shutdown
live_reset_world   # deletes $PALWARDEN_LIVE_TESTBED/server/Pal/Saved, recreates it
                   # empty; the server generates a fresh world on the next start
```

Both are guarded, so neither can run against an unmarked directory. See the runbook,
[§16](palworld-service-runbook.md#16-the-live-test-testbed), for the operator-facing
version of this.
