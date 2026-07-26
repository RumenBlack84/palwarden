# Palworld config tools on this VM

## Static web UI

The static editor from BlinkZer0/Palworld-Dedicated-Server-Config-Creator is installed at:

- /opt/palworld/tools/config-webui/PalWorldSettingsEditor.html

It is served local-only on the VM:

- http://127.0.0.1:8088/PalWorldSettingsEditor.html

Use an SSH tunnel from your workstation:

ssh -L 8088:127.0.0.1:8088 Palworld

Then browse to:

http://127.0.0.1:8088/PalWorldSettingsEditor.html

Current config files are exposed read-only via the same local-only server:

- http://127.0.0.1:8088/current/PalWorldSettings.ini
- http://127.0.0.1:8088/current/PalWorldSettings.pretty.ini

The web UI is client-side only. It can load, edit, and generate INI text in your browser, but it does not directly write back to the server.

## Parser CLI

The parser from pelican-eggs/Palworld-Config-Parser-Tool v1.0.23 is installed at:

- /usr/local/bin/palworld-config-parser

It edits Pal/Saved/Config/LinuxServer/PalWorldSettings.ini in the current working directory based on environment variables.

Wrapper for this server:

- /usr/local/sbin/palworld-config-apply-env

Put desired environment overrides in:

- /etc/palworld/settings.env

Then run:

sudo /usr/local/sbin/palworld-config-apply-env
sudo systemctl restart palworld.service

Note: after a successful apply the tooling leaves PalWorldSettings.ini immutable
(chattr +i) so the server cannot revert your settings when it shuts down. Use
`sudo palworld-config-protect unlock` before editing the file by hand, or pass
`--no-protect` to apply-env to leave it mutable. See docs/tools.md.

The wrapper backs up the current config to:

- /opt/palworld/config-backups/

Common variables:

SERVER_NAME="Yggdrasil Palworld"
SERVER_DESCRIPTION="Yggdrasil dedicated Palworld server"
MAX_PLAYERS=32
PUBLIC_IP=""
SERVER_PORT=8211
REST_API_ENABLED=True
REST_API_PORT=8212
ADMIN_PASSWORD="set-this-before-enabling-api"
RCON_ENABLE=False

Do not expose REST API or RCON directly to the Internet.

## REST API helpers

These helpers use /etc/palworld/settings.env and HTTP Basic Auth username `admin` with ADMIN_PASSWORD.
They do not use SERVER_PASSWORD; that is only the player join password.

Save world:

sudo /usr/local/sbin/palworld-api-save

Give players notice and request graceful stop, default 300 seconds:

sudo /usr/local/sbin/palworld-api-stop

Custom notice:

sudo /usr/local/sbin/palworld-api-stop 300 "Server maintenance: saving and stopping in 5 minutes."

Graceful service stop wrapper. This calls save, calls the API stop endpoint, then waits for palworld.service to become inactive:

sudo /usr/local/sbin/palworld-graceful-stop

Graceful restart wrapper. Prefer this over direct `systemctl restart palworld.service` once REST API is active and ADMIN_PASSWORD is set in the live Palworld config:

sudo /usr/local/sbin/palworld-graceful-restart

Important: Palworld REST API authentication uses ADMIN_PASSWORD, not SERVER_PASSWORD. If ADMIN_PASSWORD is blank in the live PalWorldSettings.ini, API helpers cannot authenticate.

## Update helper behavior

/usr/local/sbin/palworld-update now checks Steam public branch buildid before stopping the server.

Default behavior:

sudo /usr/local/sbin/palworld-update

- If local buildid matches remote buildid, it prints "no Palworld update available" and exits 0.
- It does not stop or restart palworld.service when no update is available.
- It does not post Discord no-op messages by default, which makes it safe for recurring scheduled checks.

Check-only mode:

sudo /usr/local/sbin/palworld-update --check

- Exits 0 if no update is available.
- Exits 10 if an update is available.
- Does not stop or update the server.

Optional no-op notification:

sudo /usr/local/sbin/palworld-update --notify-no-update

Update path when a new build exists:

- Posts Discord update-detected notification.
- Uses REST API graceful stop with player notice when REST API is available.
- Runs SteamCMD app_update 2394010 validate.
- Starts palworld.service again if it was active before update.
- Waits for service/API readiness and posts completion/failure notifications.

## Engine.ini performance tuning helper

A curated Engine.ini performance editor is installed next to the server-settings editor:

- /opt/palworld/tools/config-webui/EngineIniPerformanceEditor.html

Open it through the same SSH tunnel / web UI service:

- http://127.0.0.1:8088/EngineIniPerformanceEditor.html

Read-only current Engine.ini references are exposed at:

- http://127.0.0.1:8088/current/Engine.ini
- http://127.0.0.1:8088/current/Engine.pretty.ini

The web UI is client-side only. It generates an `engine.env` file for curated performance levers such as NetServerMaxTickRate, client bandwidth limits, GameNetworkManager bandwidth, and selected streaming/tick options. It does not directly write server config.

Apply flow:

```bash
sudo install -m 0644 -o root -g root engine.env /etc/palworld/engine.env
sudo /usr/local/sbin/palworld-engine-config apply --dry-run
sudo /usr/local/sbin/palworld-engine-config apply
sudo /usr/local/sbin/palworld-graceful-restart
```

Wrapper:

- /usr/local/sbin/palworld-engine-config

State/template file:

- /etc/palworld/engine.env

Backups are written to:

- /opt/palworld/config-backups/Engine.ini.<timestamp>

A readable copy is written to:

- /opt/palworld/server/Pal/Saved/Config/LinuxServer/Engine.pretty.ini

Notes:

- The default `/etc/palworld/engine.env` is a commented template and applies no changes until values are uncommented.
- Engine.ini changes require a Palworld service restart to take effect.
- Prefer `palworld-graceful-restart` over a direct systemctl restart so players receive the normal save/shutdown flow.
- Treat high tick-rate presets as experimental; use the FPS history/graph tooling to verify impact.


Engine.ini status and rollback:

```bash
sudo /usr/local/sbin/palworld-engine-config status
sudo /usr/local/sbin/palworld-engine-config status --check
sudo /usr/local/sbin/palworld-engine-config rollback --list
sudo /usr/local/sbin/palworld-engine-config rollback --dry-run Engine.ini.20260710T182037Z
sudo /usr/local/sbin/palworld-engine-config rollback Engine.ini.20260710T182037Z
```

Status prints managed Engine.ini values, nearest/exact profile match, and the latest backup. `status --check` compares live Engine.ini managed values against `/etc/palworld/engine.env` and exits nonzero if values are missing or drifted. Rollback restores a selected backup, saves the current Engine.ini as a pre-rollback backup, regenerates Engine.pretty.ini, records an FPS event marker, and reminds the operator to run a graceful restart. Rollback does not restart the server automatically.

## FPS event markers

The FPS telemetry database supports event markers for graph/report context.

Manual marker:

```bash
sudo /usr/local/sbin/palworld-fps mark "Applied Balanced 60 TPS Engine.ini profile" --category config --details "optional details"
```

List markers:

```bash
sudo /usr/local/sbin/palworld-fps events --window 24h
sudo /usr/local/sbin/palworld-fps events --window 7d --json
```

Reports and graphs include recent markers:

```bash
sudo /usr/local/sbin/palworld-fps report --window 24h --graph /tmp/palworld-fps.png
sudo /usr/local/sbin/palworld-fps discord --window 24h --dry-run
```

Integrated automatic markers are currently added for:

- Engine.ini performance config apply
- PalWorldSettings.ini config apply
- graceful restart requested/completed
- Palworld update detected/completed

Markers are stored in `/var/lib/palworld/metrics.sqlite3` table `fps_events` and are not posted to Discord by themselves. They appear in reports/graphs when those reports are generated.


Compare FPS around an event marker:

```bash
sudo /usr/local/sbin/palworld-fps compare --mark "Balanced 60 TPS" --before 1h --after 1h
sudo /usr/local/sbin/palworld-fps compare --mark "graceful restart completed" --before 30m --after 30m --json
```

FPS graphs now include a second player-count panel below the FPS panel. This helps distinguish server-performance dips from player-load effects.

## Config snapshots

Create a labeled snapshot of current Palworld config and operational state:

```bash
sudo /usr/local/sbin/palworld-config-snapshot create "balanced-60-tps-post-restart"
sudo /usr/local/sbin/palworld-config-snapshot list
```

Snapshots are written under:

- `/opt/palworld/config-snapshots/`

Each snapshot includes:

- `Engine.ini`
- `Engine.pretty.ini`
- `PalWorldSettings.ini`
- `PalWorldSettings.pretty.ini`
- `engine.env`
- `settings.env.redacted` with passwords/tokens/webhooks redacted
- `engine-status.txt`
- `fps-report.txt`
- `fps-report.json`
- `events-24h.txt`
- `service-status.txt`
- `api-metrics.json`
- `buildid.txt`
- `manifest.json`

Snapshot creation records a quiet FPS event marker by default. Use `--no-mark` for test snapshots.

## Daily health report

Read-only health report helper:

```bash
sudo /usr/local/sbin/palworld-health-report report
sudo /usr/local/sbin/palworld-health-report report --json
sudo /usr/local/sbin/palworld-health-report report --graph /tmp/palworld-health-fps.png --window 24h
sudo /usr/local/sbin/palworld-health-report discord --dry-run --window 24h
sudo /usr/local/sbin/palworld-health-report discord --window 24h
```

The report includes service state, API/live player state, all FPS windows from the FPS report, player averages/max, Engine.ini profile and drift status, latest backup, latest snapshot, Steam buildid, disk usage, and recent event markers. The Discord mode attaches the same FPS/player-count graph generated by `palworld-fps`.

The 09:00 ET daily timer now uses the health report instead of the FPS-only report:

```bash
systemctl cat palworld-fps-daily-report.service
systemctl list-timers palworld-fps-daily-report.timer --no-pager
```

The report is read-only. It does not apply config, restart services, write snapshots, or mutate telemetry beyond reading the existing FPS database.

