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
2. **Mutating endpoints additionally require the token in `X-Palwarden-Token`.**
   This is the CSRF defence: with Basic alone the browser would attach
   credentials to a cross-origin POST, but a cross-origin page cannot set a
   custom header without a CORS preflight, which we never grant.

   The token travels in its own header rather than `Authorization: Bearer`
   because Basic auth already occupies `Authorization` on every request — the two
   schemes cannot share one header. A custom header is exactly as CSRF-safe: the
   preflight requirement, not the scheme name, is what an attacker cannot satisfy.

   **Our pages fetch the token from `GET /api/token`; the operator is never
   prompted for it.** The pages are static files served from disk with no
   templating step, so the original design had the Engine editor ask for the
   token with `window.prompt` and cache it in `sessionStorage`. That friction is
   not worth paying: the endpoint requires the same Basic session that served the
   page, is Origin-checked, and answers `no-store`. A `window.prompt` fallback
   remains for a server that does not offer the endpoint.

   **The CSRF property is unchanged.** It never came from the operator's
   knowledge of the token; it comes from the *custom header*, which a cross-site
   page cannot set without a preflight we never answer, and from same-origin
   policy, which stops an attacker's page reading our HTML or our JSON. How our
   own page obtains the value does not touch either mechanism.

   **What does change: Basic auth alone is now sufficient to mutate**, since
   anyone who can load the page can also fetch the token. That is the accepted
   trade-off. The token was never a second human factor — it lives in the same
   0600 `webui.env` as the password and is handed to the same operator — so
   requiring it separately bought no additional authorisation, only friction.
   Blast radius is unchanged: web UI access already implies reading
   `AdminPassword` from `GET /current/PalWorldSettings.ini`.
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

`WEBUI_TOKEN` is a **CSRF token, not a second factor.** It is not an independent
credential: it sits in this same file, is issued to the same operator, and any
authenticated caller can read it back from `GET /api/token`. Treat the pair as one
secret — rotate both together, and do not grant `WEBUI_PASSWORD` to anyone who
should not be able to mutate.

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
| `/api/token` | `WEBUI_TOKEN`, as `{"ok": true, "token": "..."}`, so our own pages need not prompt for it |

There is deliberately no `/api/status` endpoint: `palworld-status` is a bash
script that prints a human-readable dashboard with no `--json` mode, and
`/api/health` already returns the same information as structured JSON (service
state, live players, FPS windows, engine drift, buildid, disk, detected
restarts). Wrapping the text output would duplicate that for no gain.

`/api/token` is the one read that is **also** Origin-checked (`403` on a
`Sec-Fetch-Site` that is not `same-origin`, or a non-loopback `Origin`), and it
answers `Cache-Control: no-store` plus `Pragma: no-cache`. The other reads need
neither: a cross-site page cannot read *any* of these responses, but this one *is*
a secret rather than merely being protected by one, so it refuses to put the value
on the wire at all instead of relying on the browser to withhold it. It is
implemented as its own branch rather than a `READ_ENDPOINTS` entry — those are
uniform `(query) -> dict` tool wrappers, and expressing two per-endpoint
exceptions in that table costs more than a branch. The token appears in no log
line (the request line is just `GET /api/token`) and in no error string.

Anything scripting the API can use the endpoint the same way: Basic auth is
enough to obtain the token, so no separate secret has to be provisioned.

Mutating: `POST /api/jobs` with `{"action": "...", "params": {...}}` (Basic +
`X-Palwarden-Token` + Origin checks) → `202 {"id": "..."}`.

Status codes: `401` missing/bad Basic · `403` missing/bad token or bad Origin ·
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
| `engine_save` | writes `/etc/palworld/engine.env` from validated key/value pairs | `settings: {<ENGINE_ENV_KEY>: <value>}` — each key must be one of `palworld-engine-config`'s 15 known settings; each value is normalised and range-checked by that tool's own rules (`normalize_value`). Unknown keys and out-of-range values are rejected. |
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
| `engine_save_apply_restart` | `engine_save`, then `palworld-engine-config apply`, then `palworld-graceful-restart` | same `settings` as `engine_save`, plus `wait: int 0-1800`. Stops at the first failure — a failed save or apply never reaches the restart. |
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
* Token fetched from `GET /api/token` on first need and kept in `sessionStorage`
  for the tab; never entered by hand except through the fallback prompt.

### Component vocabulary

The page ships no framework, so the "design system" is a fixed set of documented
class names plus CSS custom properties. This exists so that anyone editing the
page later — human or agent — has a closed vocabulary to reach for instead of
inventing a new markup shape per widget. Treat additions to this table as spec
changes, not incidental edits.

Tokens (declared once on `:root`, both themes):

| Token | Use |
|-------|-----|
| `--pw-bg`, `--pw-surface`, `--pw-border` | page, card, hairline |
| `--pw-fg`, `--pw-fg-muted` | body text, secondary text |
| `--pw-ok`, `--pw-warn`, `--pw-bad`, `--pw-idle` | the only four state colors |
| `--pw-accent` | interactive affordance (links, focus ring) |
| `--pw-space-1..4` | 4/8/16/24 px spacing scale |
| `--pw-mono` | monospace stack for values, logs, argv |

Components:

| Class | What it is | Rules |
|-------|------------|-------|
| `pw-card` | Titled section box | Every top-level region is one. Title is an `<h2>`. |
| `pw-stats` | Label/value grid (`<dl>` of `dt`/`dd`) | Labels prose, values `--pw-mono`. |
| `pw-pill` | State badge | Exactly one of `pw-pill--ok/warn/bad/idle`. Text label always present — never color alone. |
| `pw-btn` | Action button | `pw-btn--danger` marks disruptive actions; those require `pw-confirm`. Disabled while a job is `running`. |
| `pw-confirm` | Modal confirmation | Names the action and the player-warning window. Focus-trapped, Esc cancels. |
| `pw-log` | Monospace scroll region | `aria-live="polite"`, autoscrolls only when already at the bottom. |
| `pw-toast` | Transient result | One at a time; errors persist until dismissed, successes auto-clear. |
| `pw-empty` | No-data placeholder | Used instead of a blank region when a read returns `ok: false`. |

Rules that apply everywhere:

* **State is conveyed by text plus color, never color alone** (accessibility, and
  it survives the terminal-ish themes people run).
* **Values are monospace, labels are not.** Keeps drift/FPS/buildid scannable.
* No inline styles and no per-widget one-off classes; extend a token or add a row
  above.

### Growing past one page

Later pages (historical performance graphs, event history, per-restart drilldown)
are planned. They stay separate static files under `webui/` — `palwarden.html`
remains the control plane — and reuse the tokens and components above via one
shared `webui/palwarden.css`, extracted at the point the second page lands. A
shared `webui/palwarden.js` for auth-header handling and fetch/error plumbing
follows the same rule: extracted when there is a second consumer, not before.

Charts are the one place this vocabulary is likely to be insufficient. When
historical graphs arrive, revisit the no-dependency constraint deliberately
rather than by default: a small vendored chart library (or hand-rolled SVG, which
is viable for time-series of this size) is preferable to a build step, but a
React design system such as Meta's Astryx becomes a reasonable trade *if* the
dashboard has by then grown enough pages to amortise adding a Node build stage to
the image. That decision belongs in its own spec.

The existing editors gain (increment 3, optional) a single "Apply via palwarden"
hook that POSTs `config_apply`/`engine_apply`. If that turns out to require
non-trivial edits to the vendored files, it moves into our page instead rather
than forking them.

### Editing Engine.ini from the browser

`webui/EngineIniPerformanceEditor.html` is **first-party**, not vendored: it is
13.5 KB against the upstream settings editor's 136 KB, and it references
`engine.env`, `NET_SERVER_MAX_TICK_RATE`, `palworld-engine-config` and
`current/Engine.ini` — none of which exist upstream. Only
`webui/PalWorldSettingsEditor.html` is the genuine MIT-vendored file and must stay
byte-identical. The Engine editor may therefore gain controls directly, and gets a
header noting AGPL plus its partial derivation from the MIT upstream (see
`CREDITS.md`).

It gains exactly two controls:

* **Save** — enqueues `engine_save`. Writes `engine.env` only; nothing is applied
  and the server is untouched, so it is safe at any time. This is the "not right
  now" path the operator needs.
* **Save and apply** — enqueues `engine_save_apply_restart`. Disruptive, so it
  requires `confirm: true` and a `pw-confirm` dialog naming the player-warning
  window before it is sent.

Engine.ini changes only take effect after a restart, which is why applying without
restarting is not offered as a third button: it would leave the file and the running
server disagreeing with no indication in the UI.

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
  200; mutation without the token header → 403; with it → 202; cross-site `Origin` →
  403.
* `GET /api/token`: unauthenticated → 401; Basic → 200 with the value and
  `no-store`; cross-site or foreign `Origin` → 403; the token never in the log;
  and the round trip (fetch the token, then use it to enqueue → 202).
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
