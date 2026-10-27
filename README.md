# palwarden

[![CI](https://github.com/RumenBlack84/palwarden/actions/workflows/ci.yml/badge.svg)](https://github.com/RumenBlack84/palwarden/actions/workflows/ci.yml)  
[![Release](https://github.com/RumenBlack84/palwarden/actions/workflows/release.yml/badge.svg)](https://github.com/RumenBlack84/palwarden/actions/workflows/release.yml)  
[![Latest release](https://img.shields.io/github/v/release/RumenBlack84/palwarden?sort=semver)](https://github.com/RumenBlack84/palwarden/releases)  
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)

> [!WARNING]
> **Under active development — not complete or stable.**
> `palwarden` is still being built and its interfaces, file layouts and defaults
> can change without notice. It has not been proven across a wide range of hosts
> or Palworld versions. Test it against a server you can afford to break — take
> backups first, and use it at your own risk. This notice will be removed once the
> project is closer to done.

Operational tooling for a self-hosted **Palworld dedicated server** on Linux.

`palwarden` is the collection of scripts, systemd units, config helpers, and a
local web control plane that run and babysit a Palworld server: graceful
save/restart via the REST API, Steam update checks, FPS/player telemetry with
Discord reports, a per-player stats board (presence-tracked playtime plus
stats parsed from the save files), memory watchdog, config
apply/snapshot/rollback, and public join-info publishing.

> **Status:** extracted from a live Ubuntu VM and reorganized into a clean,
> installable repository. The long-term goal is to fold this together with the
> Palworld server binary into a single all-in-one Docker image — see
> [`docs/docker-roadmap.md`](docs/docker-roadmap.md).

---

## Repository layout

| Path | Contents |
|------|----------|
| `sbin/` | Operational admin commands (installed to `/usr/local/sbin`). The main entry points operators run. |
| `bin/` | `palworld-config-parser` — applies env vars to `PalWorldSettings.ini` (installed to `/usr/local/bin`). |
| `lib/` | Shared helpers sourced/called by the scripts: Discord notify, config diff/summary (installed to `/usr/local/lib`). |
| `systemd/` | `*.service` / `*.timer` units for the server and its background jobs (installed to `/etc/systemd/system`). |
| `needrestart/` | Hooks so unattended `apt` upgrades don't hard-restart the server outside the graceful flow. |
| `config/` | `settings.env.example` (config template), `engine.env` (Engine.ini tuning state) and `backup.env` (world-save backup schedule). |
| `webui/` | The control-plane dashboard plus HTML editors for server settings and Engine.ini, both wired live to the server through the control plane. |
| `docs/` | Architecture, per-tool reference, config guide, backlog, Docker roadmap, and the original export artifacts. |
| `docker/` | All-in-one container image, compose stack, and s6 service definitions. |
| `tests/` | Three test tiers, one runner: unit (`./tests/run.sh`), docker integration (`--integration`), and a **live** tier that drives a real throwaway Palworld server (`--live`, off by default and never in CI) — see [Test tiers](docs/tools.md#test-tiers). |
| `install.sh` | Deploys everything to the real filesystem paths and reloads systemd. |

Start with **[`docs/architecture.md`](docs/architecture.md)** for how the pieces
fit together, and **[`docs/tools.md`](docs/tools.md)** for a reference on every
command.

---

## How it works (in one paragraph)

`palworld.service` runs `PalServer.sh` under a dedicated `palworld` user. A set
of systemd timers drive background jobs: an FPS/player sampler every 15s writes
to a SQLite telemetry DB, an update checker polls Steam every 30 min and applies
updates through a graceful save/shutdown, a memory watchdog restarts the server
if RAM crosses a threshold, and a public-info watcher republishes join details
(IP/port/password) to Discord when they change. Operators drive lifecycle
actions (`graceful-restart`, `backup`, `config-apply-env`, `engine-config`)
manually; each records an event marker in the telemetry DB and posts a Discord
notification. A daily 09:00 ET timer posts a full health report with an FPS +
player-count graph. The same actions are reachable from a loopback web UI split
in two halves: `palwarden-webui` (unprivileged, parses HTTP, only ever *queues* a
job) and `palwarden-jobd` (root, re-validates each job against its own allowlist
and runs it). World saves get the same treatment on their own page: archives are
taken on a schedule (`palworld-backup-auto.timer`, whose interval and retention
live in `/etc/palworld/backup.env` — `/var/lib/palworld/backup.env` in the
container — and are editable from the browser), and can be
downloaded, uploaded back, restored over the live world and deleted from there —
each of those a job root runs, never something the web process does itself.

See [`docs/architecture.md`](docs/architecture.md) for the full data-flow
diagram and file/directory map.

---

## Two ways to run it

- **Bare metal / VM** (systemd) — the original deployment; use `install.sh`. See
  [Quick start](#quick-start) below.
- **Docker (all-in-one)** — a single image that either **runs the server
  itself** (self-contained) or **manages an existing server** elsewhere, chosen
  by the `PALWARDEN_MODE` toggle. The server/embedded half is working today;
  the tooling side is being containerized incrementally. See
  [`docker/README.md`](docker/README.md).

  ```bash
  cd docker && cp .env.example .env
  COMPOSE_PROFILES=embedded docker compose up -d --build
  ```

  > [!WARNING]
  > **Already running a stack from before the backups volume? Do not run that
  > `up` yet.** World-save archives, config snapshots and config backups used to
  > live in the container's writable layer; the first `up` on the new image
  > deletes that layer and mounts empty volumes over those paths, so **every
  > existing archive is lost**. Copy them out of the old container first —
  > [`docker/README.md`](docker/README.md#upgrading-from-a-pre-volume-image-do-this-before-the-first-up)
  > has the recipe. Fresh installs are unaffected.

---

## Requirements (bare-metal install)

- Linux with **systemd** (developed on Ubuntu).
- **Python 3** (standard library only — used for the REST API client, telemetry,
  graphs, and config parsing). `matplotlib` is required for FPS/health **graphs**;
  text reports work without it.
- A `palworld` system user/group that owns the server install and runtime dirs.
- The Palworld dedicated server installed at `/opt/palworld/server` (via SteamCMD,
  app id `2394010`). **This repo does not install the game itself.**
- `steamcmd`, `curl`, `flock`, `ss`, and standard coreutils on `PATH`.

---

## Quick start

```bash
# 1. Preview what will be installed and where.
sudo ./install.sh --dry-run

# 2. Install the tooling (scripts, units, webui, docs, runtime dirs).
sudo ./install.sh

# 3. Create your live config from the template and edit it. Group-readable by
#    the service account: the web UI reads the REST password from it (a re-run
#    of install.sh fixes these perms up too).
sudo cp /etc/palworld/settings.env.example /etc/palworld/settings.env
sudo chown root:palworld /etc/palworld/settings.env
sudo chmod 640 /etc/palworld/settings.env
sudo $EDITOR /etc/palworld/settings.env

# 4. (Optional) Enable Discord notifications.
echo 'PALWORLD_DISCORD_WEBHOOK=https://discord.com/api/webhooks/...' \
  | sudo tee /etc/palworld/notify.env >/dev/null
sudo chmod 600 /etc/palworld/notify.env

# 5. Apply settings to the live PalWorldSettings.ini and (re)start.
sudo /usr/local/sbin/palworld-config-apply-env
sudo systemctl enable --now palworld.service

# 6. Turn on the background jobs you want.
sudo systemctl enable --now \
  palworld-fps-sample.timer \
  palworld-update-check.timer \
  palworld-memory-watch.timer \
  palworld-public-info-watch.timer \
  palworld-fps-daily-report.timer \
  palworld-backup-auto.timer

# 7. (Optional) The web control plane — both halves, or queued actions never run.
sudo systemctl enable --now \
  palworld-config-webui.service \
  palwarden-jobd.service
```

`install.sh` generates `/etc/palworld/webui.env` and **prints the credentials
once**; they are not recoverable afterwards (see
[Security notes](#security-notes)). Reach the UI with
`ssh -L 8088:127.0.0.1:8088 <host>`.

Check on it any time:

```bash
sudo /usr/local/sbin/palworld-status
sudo /usr/local/sbin/palworld-health-report report
```

---

## Configuration files (live, not in git)

These hold secrets or generated state and are **intentionally excluded** from
the repository (see `.gitignore`). Create them on the host:

| File | Purpose |
|------|---------|
| `/etc/palworld/settings.env` | Server settings + `ADMIN_PASSWORD`/`SERVER_PASSWORD`, consumed by `palworld-config-apply-env`. Template: `config/settings.env.example`. |
| `/etc/palworld/notify.env` | `PALWORLD_DISCORD_WEBHOOK` (and optional `PALWORLD_NOTIFY_NAME`) for alerts. |
| `/etc/palworld/engine.env` | Engine.ini performance levers applied by `palworld-engine-config`. A commented template ships in `config/engine.env`. |
| `/etc/palworld/webui.env` | `WEBUI_USER`/`WEBUI_PASSWORD`/`WEBUI_TOKEN` for the web control plane. Generated by `palwarden-webui --init-credentials`; root-owned, readable by the service group. |
| `/var/lib/palworld/public-info.env` | Generated public join info (IP/port/password state). |
| `/var/lib/palworld/metrics.sqlite3` | FPS/player telemetry + event markers. |
| `/var/lib/palworld/player-stats.json` | Save-derived per-player stats snapshot (`palworld-player-stats refresh`, 60s timer), feeding the web UI's Players tab. Parsing the game's Oodle-compressed saves needs the optional `pyooz` codec — see `docs/tools.md#palworld-player-stats`. |
| `/var/lib/palworld/jobs/` | The control plane's job queue (mode 0700). Owned by the **service account**, not root, by design: the unprivileged web UI writes job files here and `palwarden-jobd` only reads and updates them. |
| `/var/lib/palworld/uploads/` | Upload staging for the Backups page (mode 0700). Service-account-owned for the same reason the queue is — the web UI is its only writer. |
| `/etc/palworld/backup.env` | Scheduled-backup settings (enabled, interval, retention, minimum kept). Live state, not just a template: the Backups page rewrites it, so `install.sh` never overwrites an existing copy. A commented template ships in `config/backup.env`. The **container** keeps this at `/var/lib/palworld/backup.env` instead (`PALWORLD_BACKUP_SCHEDULE`), because `/etc/palworld` is not persisted there. |

The Palworld REST API authenticates with **`ADMIN_PASSWORD`**, not
`SERVER_PASSWORD`. If `ADMIN_PASSWORD` is blank in the live config, the API
helpers cannot authenticate.

---

## Security notes

- **Never expose the REST API (`8212`) or RCON directly to the Internet.** They
  are meant to be reached over localhost / an SSH tunnel only.
- The web UI (`palworld-config-webui.service`) binds to `127.0.0.1:8088`. Reach it
  with a tunnel: `ssh -L 8088:127.0.0.1:8088 <host>`. HTTP Basic auth is required
  on **every** path; it is acceptable over plain HTTP only because the listener is
  loopback-bound and the tunnel supplies the encryption.
- **`/opt/palworld/restore-scratch` must stay `root:root` 0700, under the
  root-owned `/opt/palworld`.** `palworld-restore` copies an archive there and
  validates the copy, because archives in `/opt/palworld/backups` are chowned to
  the service account and are therefore writable by the unprivileged web process.
  Moving it under `/var/lib/palworld` (which that account owns) would let a
  substituted archive be restored while reporting success. Both installers create
  it correctly; the tool checks the directory **and every ancestor** and refuses
  otherwise — which is why `/opt/palworld` itself must stay `root:root`, and why a
  `chown -R` over it breaks every restore
  ([runbook](docs/palworld-service-runbook.md) §3 and §15).
- **`WEBUI_PASSWORD` is printed once, at generation, and is not recoverable.**
  To rotate it (or `WEBUI_TOKEN`), edit `/etc/palworld/webui.env` as root,
  `systemctl restart palworld-config-webui.service`, and reload the browser tab —
  the token is cached in `sessionStorage`, so an open tab keeps using the old one.
  Rotate both values together: see
  [`docs/palworld-service-runbook.md`](docs/palworld-service-runbook.md) §14.
- Mutating API requests need `WEBUI_TOKEN` in the **`X-Palwarden-Token`** header
  in addition to Basic auth; Basic alone in the header is refused with `403` by
  design. That header is a **CSRF defence, not a second factor**: any
  Basic-authenticated caller — the UI, or your script — can fetch the value from
  `GET /api/token`, so whoever holds `WEBUI_PASSWORD` can mutate. Nobody is ever
  prompted to type a token. See
  [`docs/tools.md`](docs/tools.md#web-ui-control-plane).
- **Web UI access is not a boundary against the server's own secrets.** The
  editors preload the live config, so anyone who can log in can read
  `AdminPassword` in cleartext. The separate `webui.env` credentials limit blast
  radius in the *other* direction: an in-game admin does not get shell-level
  control.
- Secrets live only in the `/etc/palworld/*.env` files above and are redacted
  from Discord diffs, config snapshots, and status output.
- `notes/` (now under `docs/original-export/`) contains the secret-scan results
  from the original export; review before publishing anywhere new.

---

## Credits & inspiration

`palwarden` builds on two upstream projects; full attribution and license
mapping is in [`CREDITS.md`](CREDITS.md):

- **pelican-eggs/Palworld-Config-Parser-Tool** (AGPL-3.0) — established the
  interface for our config-apply flow. Its prebuilt binary has since been
  replaced by our own Python implementation, so no third-party executable ships
  here.
- **BlinkZer0/Palworld-Dedicated-Server-Config-Creator** (MIT) — forked as
  `webui/PalWorldSettingsEditor.html` with the palwarden live control plane
  integrated (see `CREDITS.md`); its MIT notice is retained at
  `webui/LICENSE.upstream-mit`. The Engine.ini editor and the dashboard are
  first-party AGPL, with only the page shell and form idiom of the former
  derived from that upstream.

Palworld is a trademark of Pocketpair. This tooling is unofficial and not
affiliated with or endorsed by Pocketpair.

---

## License

`palwarden` is licensed under the **GNU Affero General Public License v3.0 or
later** (`AGPL-3.0-or-later`) — see [`LICENSE`](LICENSE). In short: it's free and
open source, you may use, study, modify, and share it, and any distributed or
network-served derivative must stay open under the same license with notices
intact. Bundled upstream components keep their own licenses as noted in
[`CREDITS.md`](CREDITS.md).

Copyright (C) 2026 Brian Grant

---

## Roadmap

- Crash/restart watchdog summary and alert-only notifications (see
  [`docs/backlog.md`](docs/backlog.md)).
- All-in-one Docker image bundling the server + tooling (see
  [`docs/docker-roadmap.md`](docs/docker-roadmap.md)).
- A donation link once the project is public (fully compatible with AGPL).
