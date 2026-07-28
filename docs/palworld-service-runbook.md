# Palwarden core Palworld service runbook

This runbook covers only the core Palworld dedicated server service setup: game server install, runtime user, config file, service execution, update model, ports, and verification.

It intentionally excludes surrounding tooling such as Discord notifications, FPS telemetry, update timers, memory watchdogs, config web UI, REST helper wrappers, event markers, and health-report automation.

## Goal

Deploy a Palworld dedicated server in a way that can later map cleanly to Docker or Podman.

Current bare-metal/VM layout:

- Host/VM: `Palworld`
- OS used at setup time: Ubuntu 24.04
- Install root: `/opt/palworld`
- Server files: `/opt/palworld/server`
- Runtime user: `palworld`
- Live config: `/opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini`
- Default config template: `/opt/palworld/server/DefaultPalWorldSettings.ini`
- Main launcher: `/opt/palworld/server/PalServer.sh`
- Systemd unit: `/etc/systemd/system/palworld.service`
- Main game port: `8211/udp`
- Steam app id: `2394010`

## 1. Preflight

On a fresh VM, confirm baseline state:

```bash
hostname
. /etc/os-release && echo "$PRETTY_NAME"
df -h /
free -h
sudo -n true && echo "passwordless sudo ok"
systemctl list-unit-files '*palworld*' --no-pager
```

For the original install, the VM had:

```text
Ubuntu 24.04.x
~97G root volume
~62G RAM
passwordless sudo for the admin user
UFW initially inactive
```

## 2. Install SteamCMD/runtime dependencies

Palworld dedicated server was installed through SteamCMD.

On Ubuntu/Debian, enable i386 and install SteamCMD/runtime packages:

```bash
export DEBIAN_FRONTEND=noninteractive

sudo dpkg --add-architecture i386
sudo apt-get update

printf "steam steam/question select I AGREE\nsteam steam/license note \n" \
  | sudo debconf-set-selections || true

sudo apt-get install -y \
  steamcmd \
  lib32gcc-s1 \
  ca-certificates \
  curl \
  tar \
  gzip \
  screen
```

Verify SteamCMD path:

```bash
command -v steamcmd || command -v /usr/games/steamcmd
```

On the current VM this resolved to:

```text
/usr/games/steamcmd
```

### Docker/Podman note

In a container image, this maps to installing SteamCMD and 32-bit runtime libraries in the image, or using a SteamCMD-capable base image. The same app id and install command still apply.

## 3. Create the service user and directories

The VM uses an unprivileged service account:

```bash
sudo id -u palworld >/dev/null 2>&1 || \
  sudo useradd \
    --system \
    --create-home \
    --home-dir /opt/palworld \
    --shell /usr/sbin/nologin \
    palworld

sudo mkdir -p /opt/palworld /opt/palworld/Steam /var/log/palworld
sudo chown -R palworld:palworld /opt/palworld/Steam /var/log/palworld
```

`/opt/palworld` itself stays **`root:root`**, and the `chown -R` is deliberately
narrowed to `Steam` (SteamCMD's own state) rather than the whole tree. Several
directories under it are root-owned on purpose — `backups`, `config-snapshots`,
and above all `restore-scratch`, whose *parent chain* `palworld-restore` verifies.
Handing `/opt/palworld` to the service account makes **every restore refuse** with
`the restore scratch parent /opt/palworld is owned by uid <n> ... refusing`.
`install.sh` repairs it on its next run (`install -d` re-applies owner and mode),
but do not create the problem. Ownership per directory is in
[`architecture.md`](architecture.md#data--state-directories).

### Docker/Podman note

In a container, mirror this with a non-root user such as:

```Dockerfile
RUN useradd --system --create-home --home-dir /opt/palworld --shell /usr/sbin/nologin palworld
USER palworld
WORKDIR /opt/palworld/server
```

Use stable UID/GID if the host bind mount requires predictable ownership.

## 4. Install the Palworld dedicated server

Install app `2394010` under `/opt/palworld/server`:

```bash
sudo -u palworld /usr/games/steamcmd \
  +force_install_dir /opt/palworld/server \
  +login anonymous \
  +app_update 2394010 validate \
  +quit
```

Verify core files:

```bash
sudo find /opt/palworld/server -maxdepth 2 -type f \
  \( -name PalServer.sh -o -name DefaultPalWorldSettings.ini \) \
  -printf "%p %s bytes\n"
```

Expected files:

```text
/opt/palworld/server/PalServer.sh
/opt/palworld/server/DefaultPalWorldSettings.ini
```

### Docker/Podman note

You have two reasonable patterns.

#### A. Mutable game-volume pattern

- Container entrypoint runs SteamCMD update into a mounted volume.
- Then runs `PalServer.sh`.
- Simple and close to the current VM model.
- Less immutable, but practical for Steam games.

#### B. Baked-image pattern

- Build image runs SteamCMD during image build.
- Runtime only starts `PalServer.sh`.
- More reproducible, but image rebuild is needed for updates and the image may become large.

For Palwarden, start with the mutable game-volume pattern unless there is a strong reason to make the game server image fully immutable.

## 5. Create the live `PalWorldSettings.ini`

Palworld’s default settings file says not to edit `DefaultPalWorldSettings.ini` directly. The live config path is:

```text
/opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
```

Create it from the default template if missing:

```bash
sudo install -d -o palworld -g palworld -m 0755 \
  /opt/palworld/server/Pal/Saved/Config/LinuxServer

if ! sudo test -s /opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini; then
  sudo cp \
    /opt/palworld/server/DefaultPalWorldSettings.ini \
    /opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini

  sudo chown palworld:palworld \
    /opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
fi
```

Initial core config edits made during setup:

```text
ServerName="Yggdrasil Palworld"
ServerDescription="Yggdrasil dedicated Palworld server"
bIsMultiplay=True
ServerPlayerMaxNum=32
PublicPort=8211
PublicIP=""
```

`PublicIP` was intentionally left blank because the home WAN IP is dynamic.

Important: do not put real passwords into docs, repos, or images. Treat these as secrets:

```text
AdminPassword
ServerPassword
```

### Docker/Podman note

The config directory should be a persistent volume or bind mount:

```text
/opt/palworld/server/Pal/Saved
```

At minimum, persist:

```text
/opt/palworld/server/Pal/Saved/Config
/opt/palworld/server/Pal/Saved/SaveGames
```

For a container layout, keep the in-container path identical to the VM path if possible, because Palworld expects its own relative tree.

## 6. Launcher behavior

The Steam-provided launcher is:

```text
/opt/palworld/server/PalServer.sh
```

It does a few important things:

- Resolves the project root.
- Copies `linux64/steamclient.so` into `Pal/Binaries/Linux/steamclient.so` if needed.
- Marks `PalServer-Linux-Shipping` executable.
- Executes `Pal/Binaries/Linux/PalServer-Linux-Shipping Pal "$@"`.

The actual service uses these launch flags:

```text
-useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS
```

Final command:

```bash
/opt/palworld/server/PalServer.sh \
  -useperfthreads \
  -NoAsyncLoadingThread \
  -UseMultithreadForDS
```

### Docker/Podman note

This should become the container `CMD` or `ENTRYPOINT` after any optional update/config-render step. Do not use systemd inside the container unless there is a very specific reason.

Example conceptual container command:

```bash
exec /opt/palworld/server/PalServer.sh \
  -useperfthreads \
  -NoAsyncLoadingThread \
  -UseMultithreadForDS
```

## 7. Systemd service used on the VM

The current core systemd unit is:

```ini
[Unit]
Description=Palworld Dedicated Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=palworld
Group=palworld
WorkingDirectory=/opt/palworld/server
ExecStart=/opt/palworld/server/PalServer.sh -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS
Restart=on-failure
RestartSec=15
TimeoutStartSec=180
KillSignal=SIGINT
TimeoutStopSec=120
LimitNOFILE=100000
Environment=SteamAppId=2394010
Environment=LD_LIBRARY_PATH=/opt/palworld/server/linux64:/opt/palworld/server/Pal/Binaries/Linux
StandardOutput=append:/var/log/palworld/server.log
StandardError=append:/var/log/palworld/server.log

[Install]
WantedBy=multi-user.target
```

Install/enable/start on the VM:

```bash
sudo systemctl daemon-reload
sudo systemctl enable palworld.service
sudo systemctl restart palworld.service
```

Key details to carry forward to Docker/Podman:

```text
WorkingDirectory=/opt/palworld/server
SteamAppId=2394010
LD_LIBRARY_PATH=/opt/palworld/server/linux64:/opt/palworld/server/Pal/Binaries/Linux
Launch flags: -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS
Stop signal: SIGINT
Stop grace: about 120 seconds
Restart policy: on failure
NOFILE limit: 100000
```

Container mapping:

```text
systemd User=palworld              -> container USER palworld
WorkingDirectory                   -> WORKDIR /opt/palworld/server
ExecStart                          -> ENTRYPOINT/CMD
Environment=SteamAppId             -> ENV SteamAppId=2394010
Environment=LD_LIBRARY_PATH        -> ENV LD_LIBRARY_PATH=...
KillSignal=SIGINT                  -> STOPSIGNAL SIGINT
TimeoutStopSec=120                 -> podman/docker stop timeout 120
LimitNOFILE=100000                 -> --ulimit nofile=100000:100000
Restart=on-failure                 -> --restart=on-failure
```

## 8. Ports

Core game port:

```text
8211/udp
```

Later/current surrounding tooling also used or discussed:

```text
27015/udp   Steam/query, if configured/needed
8212/tcp    Palworld REST API, if enabled
8088/tcp    config web UI, surrounding tool only
```

For the core service, the important player-facing port is:

```text
8211/udp
```

VM verification showed:

```text
udp 0.0.0.0:8211 owned by PalServer-Linux
```

Docker/Podman port example:

```bash
-p 8211:8211/udp
```

If using query port:

```bash
-p 27015:27015/udp
```

If enabling REST API locally for sidecars/tools, do not expose it publicly by default.

## 9. Verification

After starting:

```bash
systemctl is-active palworld.service
systemctl is-enabled palworld.service
systemctl status palworld.service --no-pager -l
sudo ss -H -lunpt | grep -E ':(8211|27015)\b' || true
pgrep -af 'PalServer-Linux|PalServer.sh'
sudo tail -120 /var/log/palworld/server.log
```

Known-good VM output included:

```text
ACTIVE=active
ENABLED=enabled
Main PID: PalServer.sh
PalServer-Linux-Shipping running
udp 0.0.0.0:8211
Game version is v0.7.3.90464
Running Palworld dedicated server on :8211
```

The Steam API warning lines seen at boot were present but did not prevent the server from running:

```text
[S_API FAIL] Tried to access Steam interface ...
```

The important success line was:

```text
Running Palworld dedicated server on :8211
```

## 10. Stop/restart behavior

Systemd sends SIGINT:

```ini
KillSignal=SIGINT
TimeoutStopSec=120
```

For Docker/Podman, preserve that.

Dockerfile:

```Dockerfile
STOPSIGNAL SIGINT
```

Runtime:

```bash
docker stop --time 120 palworld
```

or:

```bash
podman stop --time 120 palworld
```

## 11. Update model

The core manual update command is the same SteamCMD command used for installation:

```bash
sudo systemctl stop palworld.service

sudo -u palworld /usr/games/steamcmd \
  +force_install_dir /opt/palworld/server \
  +login anonymous \
  +app_update 2394010 validate \
  +quit

sudo chmod +x /opt/palworld/server/PalServer.sh
sudo systemctl start palworld.service
```

Important later lesson:
Avoid blanket recursive ownership changes like this in mature deployments:

```bash
chown -R palworld:palworld /opt/palworld
```

That caused trouble later once managed config files such as `Engine.ini` became protected/immutable. For a clean containerized layout, prefer designing ownership correctly from the start rather than fixing it with broad `chown` after every update.

Container recommendation:
If the container updates on start, keep the update step targeted:

```bash
steamcmd +force_install_dir /opt/palworld/server +login anonymous +app_update 2394010 validate +quit
chmod +x /opt/palworld/server/PalServer.sh
exec /opt/palworld/server/PalServer.sh ...
```

Do not blindly `chown` the whole mounted volume every start.

## 12. Suggested Podman/Docker target shape

A future Palwarden container should probably separate these concerns.

Persistent volumes:

```text
palworld-server:/opt/palworld/server
or bind mount: /srv/palwarden/server:/opt/palworld/server

palworld-saved:/opt/palworld/server/Pal/Saved
or bind mount: /srv/palwarden/saved:/opt/palworld/server/Pal/Saved
```

Environment:

```text
SteamAppId=2394010
LD_LIBRARY_PATH=/opt/palworld/server/linux64:/opt/palworld/server/Pal/Binaries/Linux
```

Runtime:

```bash
--user palworld
--workdir /opt/palworld/server
--stop-signal SIGINT
--stop-timeout 120
--ulimit nofile=100000:100000
--restart on-failure
-p 8211:8211/udp
```

Entry sequence:

```text
1. Ensure /opt/palworld/server exists.
2. Run SteamCMD app_update 2394010 validate if update-on-start is enabled.
3. Ensure PalWorldSettings.ini exists from DefaultPalWorldSettings.ini.
4. Optionally render config from env/template.
5. exec PalServer.sh -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS.
```

Minimal conceptual entrypoint:

```bash
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=/opt/palworld/server

/usr/games/steamcmd \
  +force_install_dir "$INSTALL_DIR" \
  +login anonymous \
  +app_update 2394010 validate \
  +quit

install -d "$INSTALL_DIR/Pal/Saved/Config/LinuxServer"

if [ ! -s "$INSTALL_DIR/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini" ]; then
  cp "$INSTALL_DIR/DefaultPalWorldSettings.ini" \
     "$INSTALL_DIR/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini"
fi

chmod +x "$INSTALL_DIR/PalServer.sh"

cd "$INSTALL_DIR"

exec "$INSTALL_DIR/PalServer.sh" \
  -useperfthreads \
  -NoAsyncLoadingThread \
  -UseMultithreadForDS
```

## 13. Things not included in this core runbook

Excluded by request:

```text
Discord webhooks/notifications
palworld-api wrapper
palworld-status helper
palworld-update-check timer
memory watchdog
FPS SQLite telemetry
daily FPS reports
config web UI
Engine.ini profile manager
event markers
public-info watcher
1.0 launch watcher
backup helper/timers beyond the core note
```

Those are operational tooling around the service, not the core Palworld service itself.

## 14. Recovering the web UI control plane

The one exception to section 13: this is a recovery procedure, and it is needed at
a bad moment. Reference for the commands themselves is in
[`tools.md`](tools.md#web-ui-control-plane); the privilege split is in
[`architecture.md`](architecture.md).

The control plane is two units. `palworld-config-webui.service` runs
`palwarden-webui --serve` unprivileged and can only *queue* jobs;
`palwarden-jobd.service` runs as root and executes them. If either is down the UI
looks healthy and nothing happens.

Status and logs:

```bash
systemctl status palworld-config-webui.service palwarden-jobd.service --no-pager -l
journalctl -u palwarden-jobd.service -n 100 --no-pager
systemctl restart palwarden-jobd.service
```

In the container, the same two are s6 services (`config-webui`, `jobd`):

```bash
docker compose exec palwarden s6-svstat /run/service/jobd
docker compose exec palwarden s6-svc -r /run/service/jobd
docker compose logs palwarden
```

### A job the UI still shows as `running`

Only a worker that died mid-job leaves a job in `running`. `palwarden-jobd` reaps
those when it *starts*, so the normal fix is simply to restart it:

```bash
sudo systemctl restart palwarden-jobd.service
```

If the service is stopped and you want the queue cleared without starting the
loop:

```bash
sudo palwarden-jobd --reap    # mark orphaned running jobs failed, then exit
sudo palwarden-jobd --once    # reap, run one queued job, prune, exit
```

Both must run as root, and both take the **same exclusive lock**
(`/run/palwarden-jobd.lock`) the service holds. So while the service is up they
refuse rather than race:

```text
another palwarden-jobd holds /run/palwarden-jobd.lock; exiting
```

That refusal is the correct outcome — `--reap` cannot tell a live worker's job
from a crashed one, and marking a running 20-minute `update_apply` as failed would
be worse than doing nothing. Stop the service first if you really mean to reap by
hand.

A stuck disruptive job also blocks new ones: `POST /api/jobs` answers `409` with a
`blocked_by` object naming the offending job's `id`, `action` and `state`. Inspect
it with `GET /api/jobs/<id>` (or read
`/var/lib/palworld/jobs/<id>.json`) before clearing it.

### Lost or rotating web UI credentials

`palwarden-webui --init-credentials` prints `WEBUI_USER`, `WEBUI_PASSWORD` and
`WEBUI_TOKEN` **once**, at creation, and never again; it also refuses to overwrite
an existing `/etc/palworld/webui.env`. There is no recovery — read the file, or
replace the values:

```bash
sudo cat /etc/palworld/webui.env                 # they are stored in cleartext here
sudo $EDITOR /etc/palworld/webui.env             # or rotate: new password/token
sudo systemctl restart palworld-config-webui.service
```

Then **reload the browser tab**. The token is cached in `sessionStorage` for the
life of the tab, so an open tab keeps sending the old one — the first Save answers
`403`, discards the cached value, and a second click re-fetches from
`GET /api/token`, so a retry usually recovers without a reload.

Rotate the password and the token **together**. `WEBUI_TOKEN` is a CSRF token, not
a second factor: any caller with Basic auth can fetch it from `GET /api/token`
(that is how the editor gets it), so rotating the token alone protects nothing if
the password leaked, and rotating the password alone is what actually revokes
access.

If you are scripting the API rather than clicking, you never need to read the
token out of the file:

```bash
curl -sS -u admin:"$WEBUI_PASSWORD" http://127.0.0.1:8088/api/token
```

To regenerate from scratch, remove the file and re-run
`palwarden-webui --init-credentials` as root, then restore its ownership and mode
(`root:<service group>`, `0640`) as `install.sh` does. In the container, set
`WEBUI_USER`/`WEBUI_PASSWORD`/`WEBUI_TOKEN` in `.env` and recreate the container —
`/etc/palworld` is not a volume, so unset values are regenerated on every
recreate.

### Every button returns 403 / no job is ever queued

Three usual causes, in order of likelihood:

```text
missing or invalid X-Palwarden-Token   -> WEBUI_TOKEN changed under a stale tab; click
                                          again (the page re-fetches) or reload
cross-origin request refused           -> the UI was reached on a non-loopback address
job queue directory ... not writable   -> /var/lib/palworld/jobs is not owned by the
                                          web UI's service account (it must be, 0700)
```

A `403` from `GET /api/token` itself is always the second of these: the endpoint
refuses any request whose `Sec-Fetch-Site` is not `same-origin` or whose `Origin`
is not loopback, because that response carries the token. Reach the UI through the
SSH tunnel (`http://127.0.0.1:<port>/`), not a routable address or hostname.

The queue directory being owned by the service account rather than root is
deliberate: the unprivileged server is the process that writes job files. The
writability check runs once at startup, so fix the ownership *and* restart
`palworld-config-webui.service`.

## 15. World-save backups: schedule, retention, and recovering a bad restore

Command reference is in [`tools.md`](tools.md) (`palworld-backup`,
`palworld-backups`, `palworld-restore`); the directory ownership and why it differs
is in [`architecture.md`](architecture.md). This section is only the procedures.

### Container upgrade: move the archives onto the volume first

**Do this before the first `up` on the new image.** Releases before the
`palwarden-backups` volume kept `/opt/palworld/backups` in the container's
writable layer. `git pull && docker compose up -d` recreates the container, that
layer is deleted with it, and the new — empty — volume takes its place. Every
existing archive is gone, and once the old container is removed there is nothing
to recover from. `/opt/palworld/config-snapshots` and
`/opt/palworld/config-backups` moved onto volumes in the same release and have the
same exposure.

```bash
cd docker
# 1. while the OLD container still exists:
docker compose cp palwarden:/opt/palworld/backups ./backups-migrate
docker compose cp palwarden:/opt/palworld/config-snapshots ./snapshots-migrate
docker compose cp palwarden:/opt/palworld/config-backups ./config-backups-migrate
# 2. bring the new image up, then copy back into the volumes:
COMPOSE_PROFILES=embedded docker compose up -d --build
docker compose cp ./backups-migrate/. palwarden:/opt/palworld/backups
docker compose cp ./snapshots-migrate/. palwarden:/opt/palworld/config-snapshots
docker compose cp ./config-backups-migrate/. palwarden:/opt/palworld/config-backups
docker compose exec palwarden chown root:root /opt/palworld/backups
docker compose exec palwarden chmod 0755 /opt/palworld/backups
docker compose exec palwarden stat -c '%U %G %a %n' /opt/palworld/backups   # root root 755
```

The **directory** must end up root-owned `0755` — that is what stops the
unprivileged web process substituting an archive, and `palworld-restore` refuses
outright when it is wrong. Do not check the archives against a single owner: ones
`palworld-backup` wrote are `steam`-owned, ones `palworld-restore --import`
promoted are `root:root 0644`, and both restore fine.

If the upgrade already happened, the entrypoint says so on every start:
`WARNING: /opt/palworld/backups is empty but this world already has saves`. It is
detected from the world (`palworld-saved` has saves, backups has nothing), so it
also fires on a first boot with a pre-seeded world — harmless, and preferable to
silence.

Bare metal is unaffected: `/opt/palworld/backups` is a real directory on the host
and `install.sh` never removes it.

### Changing the schedule or retention

The schedule is a **file**, not a unit: `/etc/palworld/backup.env` on bare metal,
`/var/lib/palworld/backup.env` in the container (`/etc/palworld` is not persisted
there, so a schedule kept in it was reverted by every recreate). The timer
(`palworld-backup-auto.timer`, or the container's `backup-auto` service) fires on a
short fixed tick and `palworld-backups` decides whether anything is due. So nothing
needs a reload after a change.

```bash
# from the browser: Backups page -> Schedule -> Save (writes the file via jobd)
# or by hand:
sudo $EDITOR /etc/palworld/backup.env
palworld-backups --show-schedule      # what the tick will actually do

# container: use the Backups page, or read the file and copy an edited one back
docker compose exec palwarden cat /var/lib/palworld/backup.env
docker compose exec palwarden palworld-backups --show-schedule
```

`--show-schedule` is the authority, and it is worth reading after an edit: a bad
value is **never fatal** — it warns on stderr and falls back to that key's default,
because a parse error must not silently stop backups. A key that vanished from the
output's expectations is a typo in the key name; a value that came back as the
default when you set something else is out of range.

```bash
systemctl enable --now palworld-backup-auto.timer   # bare metal, once
systemctl list-timers palworld-backup-auto.timer    # when it next fires
journalctl -u palworld-backup-auto.service -n 50 --no-pager
```

To pause backups without disabling anything, set `BACKUP_ENABLED=false`. The tick
keeps running and prints why it created nothing; turning them back on is one word
in a file, with no unit to re-enable and no `daemon-reload`.

Retention deletes by **age** (`BACKUP_RETENTION_DAYS`), keeps the newest
`BACKUP_KEEP_MIN` whatever their age, and **never deletes the last archive** —
whatever the settings say. If the directory is growing anyway, it is usually
because every restore also takes a pre-restore safety archive; those are ordinary
backups and are pruned like any other.

### Disaster recovery: take an archive off the host and bring it back

This is the loop the panel exists for, and it is four steps in two sittings. The
first two are the part you do *before* anything goes wrong.

**1. Get an archive off the host.** Backups page → the archive's **Download** link
(it streams the file to your browser and changes nothing), or from a shell:

```bash
# bare metal
scp <host>:/opt/palworld/backups/palworld-save-<stamp>.tar.gz .
# container
docker compose cp palwarden:/opt/palworld/backups/palworld-save-<stamp>.tar.gz .
```

Keep the filename exactly as it is. Do not rename it, do not let a browser
de-duplicate it to `...tar (1).gz`, and do not re-tar it.

**2. On the rebuilt host, upload it back.** Install the tooling (and, in the
container, bring the stack up) so the Backups page is reachable through the tunnel,
then: **Import an archive** → choose the file → **Upload and import**. That one
button does both halves — it streams the body into the staging directory
(`POST /api/backups/upload`) and then queues the `backup_import` job that root
runs. Importing restores nothing; the archive simply appears in the Archives list.

By hand instead of by browser:

```bash
# stage it: the whole request body is the archive (no multipart), and the
# endpoint needs a real Content-Length -- chunked is refused -- so -T, not
# --data-binary, which would buffer gigabytes in curl.
curl -sS -X POST -T palworld-save-<stamp>.tar.gz \
  -u admin:"$WEBUI_PASSWORD" -H "X-Palwarden-Token: $WEBUI_TOKEN" \
  -H 'Content-Type: application/octet-stream' \
  -H 'X-Palwarden-Filename: palworld-save-<stamp>.tar.gz' \
  http://127.0.0.1:8088/api/backups/upload      # 202 {"staged": "..."}

# then promote it (this is what the backup_import job runs)
sudo palworld-restore --import palworld-save-<stamp>.tar.gz   # prints the promoted path

# or skip HTTP entirely: root can read a file you put in the staging dir yourself
sudo cp palworld-save-<stamp>.tar.gz /var/lib/palworld/uploads/
sudo palworld-restore --import palworld-save-<stamp>.tar.gz
```

**The failure you will hit first is a renamed archive.** Import is **round-trip
only**: the name must be exactly `palworld-save-<8 digits>T<6 digits>Z.tar.gz`, and
anything else is refused before a byte is read — by the page, by the upload
endpoint (`400 X-Palwarden-Filename must be an archive name this project wrote
(palworld-save-<UTC stamp>.tar.gz), not '...'`), and again by root:

```text
palworld-restore: 'worldsave.tar.gz' is not a name palworld-backup could have written; refused
```

Rename the file back to the stamp it was written with and it imports. This is
**not** a migration tool: an arbitrary Palworld save, someone else's archive, or a
tarball you rolled yourself will not be accepted no matter what you call it — every
member must also sit under `SaveGames/` or `Config/`. To move a world in from
outside, put the files in place under `Pal/Saved` by hand and take a
`palworld-backup` of it.

**3. Restore it.** Archives list → **Restore** on that row → confirm. Or
`sudo palworld-restore --restore palworld-save-<stamp>.tar.gz`. On a fresh host
with no `ADMIN_PASSWORD` set yet, expect the *successful* ending that could not
confirm readiness — it keeps a full copy of the previous world beside the new one;
see the exit-code table in [`tools.md`](tools.md#palworld-restore) and the cleanup
note at the end of this section.

**4. Then set the server up as usual** (`settings.env`, `ADMIN_PASSWORD`, apply,
restart), and take a fresh backup once it is known good.

### Recovering from a failed or wrong restore

A restore leaves **two** independent ways back, and prints both. Read the job's
output (Backups page, or `GET /api/jobs/<id>`) before touching anything:

```text
safety backup: palworld-save-<stamp>.tar.gz        <- the world as it was, archived
replaced: previous world moved to /opt/palworld/server/Pal/Saved.replaced-<stamp>
```

1. **`Pal/Saved.replaced-<stamp>`** — the previous world tree, moved aside rather
   than deleted. This is the fastest undo there is: a rename, no untarring. It is
   kept whenever the restore did **not** confirm a startup (the service failed to
   start, readiness timed out, or the REST API is not configured so readiness could
   not be checked at all), and deleted only on a positive confirmation.

   ```bash
   sudo systemctl stop palworld.service      # container: s6-svc -wD -d /run/service/palworld-server
   cd /opt/palworld/server/Pal
   sudo mv Saved Saved.failed-restore
   sudo mv Saved.replaced-<stamp> Saved
   sudo chown -R palworld:palworld Saved     # container: steam:steam
   sudo systemctl start palworld.service
   ```

2. **The pre-restore safety archive** — an ordinary archive in
   `/opt/palworld/backups`, named in the job output. Use it when the replaced tree
   is gone (a confirmed startup removed it, or a later prune took the archive's
   place): restore it the same way you restored the wrong one, from the Backups
   page or `sudo palworld-restore --restore <name>`.

If the restore aborted *before* the swap — a validation failure, or a safety backup
that could not be taken — nothing was touched at all. That is the design: the live
world is only ever replaced by two `rename` calls after the new tree is fully
extracted beside it.

Three things to check when a restore keeps failing — the **parent** matters as much
as the directory, and it is the one most likely to be wrong:

```bash
stat -c '%U %a' /opt/palworld/restore-scratch     # must be root 700
stat -c '%U %a' /opt/palworld                     # must be root 755 (every ancestor is checked)
stat -c '%U %a' /var/lib/palworld/uploads         # must be <service account> 700
```

`palworld-restore` verifies the scratch directory **and its whole parent chain**
and refuses otherwise, so a wrong owner here shows up as a clean refusal in the job
output rather than as a bad restore. The three refusals read:

```text
the restore scratch directory /opt/palworld/restore-scratch is owned by uid 1000,
  not by uid 0 that this tool runs as; refusing to stage a restore in a directory
  another account can rewrite
the restore scratch parent /opt/palworld is owned by uid 1000, which could rename
  the scratch directory aside; refusing
the restore scratch parent /opt/palworld is mode 0777 and so is writable by other
  accounts, which could rename the scratch directory aside; refusing
```

The last two are what a `sudo chown -R palworld:palworld /opt/palworld` (or a
world-writable ancestor) produces, and they refuse **every** restore, not just the
one you tried. Fix the ownership — or simply re-run `sudo ./install.sh`, which
re-applies `root:root 0755` to `/opt/palworld` and `root:root 0700` to
`restore-scratch`. `--restore` is also **refused entirely in
`PALWARDEN_MODE=external`**: the game runs on another host, so "is the server
running?" has no truthful answer locally and the world could be replaced under a
live server. Restore on the host that runs the server.

Old `Pal/Saved.replaced-*` trees are listed at the start of every restore and are
never deleted automatically — each is a full world save. Remove them by hand once
the server is known good.

## Short version

The core service is simply:

```text
SteamCMD app 2394010 installed under /opt/palworld/server
run as unprivileged palworld user
live config at Pal/Saved/Config/LinuxServer/PalWorldSettings.ini
start /opt/palworld/server/PalServer.sh with:
  -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS
set SteamAppId=2394010
set LD_LIBRARY_PATH to linux64 and Pal/Binaries/Linux
listen on UDP 8211
stop with SIGINT and allow about 120s
```

That maps cleanly to a container entrypoint, persistent `Saved` volume, UDP port mapping, non-root user, and SIGINT stop behavior.
