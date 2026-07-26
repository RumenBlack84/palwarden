# Web UI control plane — design

**Date:** 2026-07-26
**Status:** approved, not yet implemented
**Goal:** let the browser UI drive the palwarden tooling — read state *and* run
operations, up to and including restarts and Steam updates — without handing a
browser-facing process root, and without leaving the UI open to anyone who can
reach loopback.

## Background: what exists today

The web UI is static only. `palworld-config-webui.service` (bare metal) and the
`config-webui` s6 service (container) run `python3 -m http.server 8088`, serving
two vendored MIT editors plus a read-only `current/` symlink to the live config
directory. The only integration is one line in
`EngineIniPerformanceEditor.html`: `fetch('current/Engine.ini')` to preload
values. There is no API, no write-back, and no way to invoke any of the ~20
`sbin/` commands. The docs state this in three places.

So this is a new subsystem, not an extension of prior work.

## Constraints that shape the design

1. **A browser-facing HTTP server must not have privilege.** Restarting the
   server needs root in the container (`s6-svc`) or `sudo` on bare metal.
2. **An unauthenticated localhost API is reachable by any site you visit.**
   CSRF, and DNS rebinding defeats naive `Host` checks. Harmless for today's
   read-only static GETs; unacceptable once `update` or `graceful-restart` are
   reachable.
3. **Basic auth over plain HTTP is acceptable here, and only here**, because
   traffic never leaves the host: the listener is loopback-bound and remote
   access is via SSH tunnel, which provides the encryption. This is a documented
   constraint, not a claim of transport security.
4. **Both platforms run the same code** (repo convention): paths and behaviour
   differ only through environment overrides.

## Architecture

Two new processes with a one-way, non-network boundary between them:

| Component | Privilege | Responsibility |
|---|---|---|
| `sbin/palwarden-webui` | unprivileged (`palworld` / `steam`) | Serves static files **and** `/api/*`. Executes read-only tools directly. Mutations are only *validated and enqueued*. |
| `sbin/palwarden-jobd` | **root** | Watches the job queue, re-validates each job against a hardcoded allowlist, executes it, records status and output. Parses no network input. |
| `webui/palwarden.html` | — | First-party (AGPL) dashboard and controls. |

**The security property:** the process that parses HTTP has no privilege; the
process with privilege has no network input. Its only input is a JSON file whose
contents it re-validates against a fixed allowlist.

The vendored MIT editors are left byte-identical (upstream syncs stay trivial,
attribution stays clean). The new control panel is a separate first-party page.

Single port (8088) so there is still exactly one thing to tunnel.

## Authentication and hardening

Layered, because page loads and API calls need different mechanisms.

1. **HTTP Basic auth on every path**, static pages included. Nothing is viewable
   without credentials; the browser prompts once. Compared with constant-time
   digests (`hmac.compare_digest`) to avoid timing leaks.
2. **Mutating endpoints additionally require `Authorization: Bearer <token>`.**
   This is the CSRF defence: with Basic alone the browser would attach
   credentials to a cross-origin POST, but a cross-origin page cannot set a
   custom header without a CORS preflight, which we never grant. The control
   panel supplies the token from `sessionStorage` (same-origin JS can; an
   attacker's page cannot read it).
3. **Origin / `Sec-Fetch-Site` validation on mutations.** Reject anything whose
   `Origin` is present and not our own; reject `Sec-Fetch-Site: cross-site`.
   Defeats DNS rebinding.
4. **Loopback binding**; compose publishes to `127.0.0.1` only; no CORS headers.
5. **Fail closed:** the server exits with a clear error if credentials are
   missing, and refuses to run as root (`euid == 0`).

### Credentials

`/etc/palworld/webui.env`, mode 0600, owned by the service user:

```
WEBUI_USER=admin
WEBUI_PASSWORD=<generated>
WEBUI_TOKEN=<generated>
```

Generated with `secrets.token_urlsafe(32)` by `palwarden-webui
--init-credentials` (must run as root, since `/etc/palworld` is root-owned).
Called automatically by `install.sh` (bare metal) and by `docker/entrypoint.sh`
(container, alongside the existing `settings.env`/`notify.env` rendering).
Credentials are printed **once** at generation so they can be retrieved, never on
subsequent starts. Deliberately separate from `ADMIN_PASSWORD`: distinct blast
radius, independently rotatable, and in-game admins do not get shell-level
control. Gitignored; never baked into an image.

## API

Read endpoints (Basic auth only, `GET`, JSON, each with a subprocess timeout):

| Endpoint | Backed by |
|---|---|
| `/api/health` | `palworld-health-report report --json` |
| `/api/fps?window=24h` | `palworld-fps report --json` |
| `/api/events?window=24h` | `palworld-fps events --json` |
| `/api/service-events?since=24h` | `palworld-service-events summary --json` |
| `/api/engine` | `palworld-engine-config status --check` |
| `/api/config` | live `PalWorldSettings.ini`, parsed to key/value JSON with `AdminPassword`/`ServerPassword` replaced by `"<redacted>"` (the same `SECRET_KEYS` set `palworld-config-diff`/`-summary` already use) |
| `/api/backups`, `/api/snapshots` | directory listings |
| `/api/jobs`, `/api/jobs/<id>` | queue state |

There is deliberately no `/api/status` endpoint: `palworld-status` is a bash
script that prints a human-readable dashboard with no `--json` mode, and
`/api/health` already returns the same information as structured JSON (service
state, live players, FPS windows, engine drift, buildid, disk, detected
restarts). Wrapping the text output would duplicate that for no gain.

Mutating: `POST /api/jobs` with `{"action": "...", "params": {...}}` (Basic +
Bearer + Origin checks) → `202 {"id": "..."}`.

Status codes: `401` missing/bad Basic · `403` missing Bearer or bad Origin ·
`400` validation failure · `404` unknown path/job · `409` a disruptive job is
already pending · `500` internal. `/api/*` errors are JSON.

## Job queue

* Job file: `/var/lib/palworld/jobs/<id>.json`, id `^[0-9a-f]{32}$` (validated on
  read, so a crafted id cannot traverse paths).
* Fields: `id, action, params, state, created_at, started_at, finished_at,
  exit_code, output`. States: `queued → running → succeeded|failed`.
* `palwarden-jobd` holds a `flock` and runs **one job at a time**, oldest first,
  so a restart cannot race an update.
* Output captured combined, capped at 256 KiB with a truncation marker.
* Finished jobs pruned after 7 days (matches the telemetry retention pattern).
* **`jobd` re-validates action and params.** The queue file comes from another
  process; it is treated as untrusted input.

### Actions

Every action is a **fixed argv template with typed, validated slots**. No string
is ever passed to a shell.

*File-only (no player impact):*

| Action | Command | Params |
|---|---|---|
| `config_apply` | `palworld-config-apply-env` | — |
| `engine_apply` | `palworld-engine-config apply` | `dry_run: bool` |
| `config_pretty` | `palworld-config-pretty` | — |
| `snapshot_create` | `palworld-config-snapshot create <label>` | `label: ^[A-Za-z0-9._-]{1,64}$` |
| `backup` | `palworld-backup` | — |
| `mark` | `palworld-fps mark <text> --category manual` | `text`: ≤200 printable chars |

*Disruptive (require `"confirm": true` in the request body, in addition to UI confirmation):*

| Action | Command | Params |
|---|---|---|
| `graceful_restart` | `palworld-graceful-restart` | `wait: int 0–1800`, `message`: ≤200 printable |
| `graceful_stop` | `palworld-graceful-stop` | same |
| `update_check` | `palworld-update --check` | — |
| `update_apply` | `palworld-update` | `wait: int 0–1800` |
| `engine_rollback` | `palworld-engine-config rollback <backup>` | `backup`: must match an existing backup filename |
| `api_save` | `palworld-api-save` | — |

`message` is validated tightly because it reaches players through the REST API.

## UI

`webui/palwarden.html` — one page, no build step, no dependencies (consistent
with the vendored editors being single files):

* **Status strip:** service state, players, FPS, buildid, drift, detected
  restarts/outages.
* **Telemetry:** FPS windows and recent event markers.
* **Actions:** buttons grouped file-only vs disruptive. Disruptive ones open a
  confirmation dialog naming the action and the player-warning window.
* **Job log:** live view of the current/last job, polled while `running`.
* Token entered once, kept in `sessionStorage`.

The existing editors gain (increment 3, optional) a single "Apply via palwarden"
hook that POSTs `config_apply`/`engine_apply`. If that turns out to require
non-trivial edits to the vendored files, it moves into our page instead rather
than forking them.

## Platform wiring

* **Bare metal:** repoint `palworld-config-webui.service` ExecStart at
  `palwarden-webui`; add `palwarden-jobd.service` (root, `Restart=on-failure`).
  `install.sh` picks both up automatically (it globs `sbin/` and `systemd/`).
* **Container:** the existing `config-webui` s6 service runs `palwarden-webui`
  as `steam`; a new `jobd` s6 service runs `palwarden-jobd` as root (same
  pattern as `memory-watch`/`update-check`). Enabled in embedded mode.
* Overrides for tests/portability: `PALWARDEN_WEBUI_ENV`, `PALWARDEN_JOBS_DIR`,
  `PALWARDEN_WEBUI_ROOT`, `PALWARDEN_WEBUI_BIND`, `PALWARDEN_WEBUI_PORT`.
* Notifications follow the repo convention: disruptive jobs post through
  `palworld_notify`, which no-ops when the helper is absent.

## Error handling

* Read endpoints: a failing tool yields `{"ok": false, "error": ...}` with the
  tool's stderr, not a 500 — one broken tool must not blank the dashboard.
* Subprocess timeouts on every read (default 30 s; `health` 60 s).
* `jobd` records non-zero exits as `failed` with output retained; a crash mid-job
  leaves the job `running`, and on start `jobd` marks orphaned `running` jobs
  `failed` with an explanatory note.
* A missing tool (`FileNotFoundError`) is reported, never a traceback.

## Testing

**Unit** (no docker, per repo convention):
* Auth: no credentials → 401; wrong password → 401; correct Basic on a read →
  200; mutation without Bearer → 403; with Bearer → 202; cross-site `Origin` →
  403.
* Refusal to start as root; refusal to start without credentials.
* Param validation: label/message/wait/backup rejection, including shell
  metacharacters and path traversal (`../`), asserting argv is never shell-joined.
* Job lifecycle: enqueue → `jobd` runs a stubbed action → `succeeded`; failing
  action → `failed` + exit code; unknown action rejected by *both* processes;
  malformed/hand-crafted job file rejected by `jobd`; orphaned `running` job
  marked failed on restart.
* Job id validation blocks traversal.

**Integration** (container): unauthenticated page load → 401; authenticated →
200; `/api/status` returns real JSON; enqueue `snapshot_create` and observe
`succeeded`; enqueue `graceful_restart` and confirm the server's s6 pid changes;
confirm `palwarden-webui` is not running as root.

## Increments

1. `palwarden-webui`: static serving, Basic auth, read endpoints, dashboard.
   Deliverable: a useful read-only panel behind auth.
2. Job queue + `palwarden-jobd` + file-only actions, with UI buttons and the job
   log.
3. Disruptive actions with `confirm`, UI confirmation dialogs, and the optional
   editor "apply" hooks.

## Out of scope

TLS termination (use the SSH tunnel), multi-user accounts or roles, remote
exposure, log streaming beyond job output, and editing arbitrary config keys from
the panel (the vendored editors already do that).
