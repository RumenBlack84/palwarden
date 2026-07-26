# palwarden

Operational tooling for a self-hosted **Palworld dedicated server** on Linux.

`palwarden` is the collection of scripts, systemd units, config helpers, and a
static web UI that run and babysit a Palworld server: graceful save/restart via
the REST API, Steam update checks, FPS/player telemetry with Discord reports,
memory watchdog, config apply/snapshot/rollback, and public join-info
publishing.

> **Status:** extracted from a live Ubuntu VM and reorganized into a clean,
> installable repository. The long-term goal is to fold this together with the
> Palworld server binary into a single all-in-one Docker image — see
> [`docs/docker-roadmap.md`](docs/docker-roadmap.md).

---

## Repository layout

| Path | Contents |
|------|----------|
| `sbin/` | Operational admin commands (installed to `/usr/local/sbin`). The main entry points operators run. |
| `bin/` | `palworld-config-parser` — prebuilt helper binary that edits `PalWorldSettings.ini` from env vars (installed to `/usr/local/bin`). See [attribution](#third-party-components). |
| `lib/` | Shared helpers sourced/called by the scripts: Discord notify, config diff/summary (installed to `/usr/local/lib`). |
| `systemd/` | `*.service` / `*.timer` units for the server and its background jobs (installed to `/etc/systemd/system`). |
| `needrestart/` | Hooks so unattended `apt` upgrades don't hard-restart the server outside the graceful flow. |
| `config/` | `settings.env.example` (config template) and `engine.env` (Engine.ini tuning state). |
| `webui/` | Standalone client-side HTML editors for server settings and Engine.ini. |
| `docs/` | Architecture, per-tool reference, config guide, backlog, Docker roadmap, and the original export artifacts. |
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
player-count graph.

See [`docs/architecture.md`](docs/architecture.md) for the full data-flow
diagram and file/directory map.

---

## Requirements

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

# 3. Create your live config from the template and edit it.
sudo cp /etc/palworld/settings.env.example /etc/palworld/settings.env
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
  palworld-fps-daily-report.timer
```

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
| `/var/lib/palworld/public-info.env` | Generated public join info (IP/port/password state). |
| `/var/lib/palworld/metrics.sqlite3` | FPS/player telemetry + event markers. |

The Palworld REST API authenticates with **`ADMIN_PASSWORD`**, not
`SERVER_PASSWORD`. If `ADMIN_PASSWORD` is blank in the live config, the API
helpers cannot authenticate.

---

## Security notes

- **Never expose the REST API (`8212`) or RCON directly to the Internet.** They
  are meant to be reached over localhost / an SSH tunnel only.
- The config web UI (`palworld-config-webui.service`) binds to `127.0.0.1:8088`.
  Reach it with a tunnel: `ssh -L 8088:127.0.0.1:8088 <host>`.
- Secrets live only in the `/etc/palworld/*.env` files above and are redacted
  from Discord diffs, config snapshots, and status output.
- `notes/` (now under `docs/original-export/`) contains the secret-scan results
  from the original export; review before publishing anywhere new.

---

## Credits & inspiration

`palwarden` builds on two upstream projects; full attribution and license
mapping is in [`CREDITS.md`](CREDITS.md):

- **pelican-eggs/Palworld-Config-Parser-Tool** (AGPL-3.0) — the starting point
  for our config-apply flow (`bin/palworld-config-parser`).
- **BlinkZer0/Palworld-Dedicated-Server-Config-Creator** (MIT) — the basis for
  our in-browser config editors (`webui/`); its MIT notice is retained at
  `webui/LICENSE.upstream-mit`.

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
