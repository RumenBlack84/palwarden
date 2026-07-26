# palwarden in Docker

An **all-in-one image** for Palworld: one artifact that can either **run the
dedicated server itself** (self-contained) or **manage an existing server**
elsewhere. Which role it plays is chosen at runtime, not at build time.

> **Status — increment 2:** the **embedded** container now runs under an
> **s6-overlay** supervisor with two managed services: the **Palworld server**
> and the **config web UI**. Background tooling (telemetry, timers, REST
> wrappers) and the active side of **external** mode land in the next increment.
> See [`../docs/docker-roadmap.md`](../docs/docker-roadmap.md).

## Process model

`s6-overlay` is PID 1 (as root) and supervises the workloads; **every workload
runs unprivileged as the `steam` user** (uid/gid 1000). On stop, s6 receives
SIGTERM and the server's service forwards **SIGINT** to the game so it saves
before exiting (`S6_KILL_GRACETIME` gives it headroom under the 120s stop grace).

## The two modes

| | `embedded` | `external` |
|---|-----------|-----------|
| **What runs** | s6 → Palworld server + config web UI (+ tooling, next increment) | Tooling only, targeting your existing server |
| **Game files** | In a Docker volume | None (managed remotely) |
| **Use when** | You want a self-contained server | You already run Palworld elsewhere and just want the tooling |
| **Toggle** | `COMPOSE_PROFILES=embedded`, `PALWARDEN_MODE=embedded` | profile empty, `PALWARDEN_MODE=external`, set `PALWORLD_TARGET_HOST` |

Both come from the **same image**; the mode is a runtime env var. Because game
files live in a volume (not the image), the external role stays lean.

## Quick start — embedded (self-contained server)

```bash
cd docker
cp .env.example .env          # adjust ports / UPDATE_ON_START if you like
COMPOSE_PROFILES=embedded docker compose up -d --build
docker compose logs -f palwarden
```

Wait for `Running Palworld dedicated server on :8211`. First boot downloads the
game via SteamCMD (a few GB), so it takes a while. Players connect on
`UDP 8211` (host port set by `PALWORLD_GAME_PORT`).

Stop gracefully (server saves via SIGINT, up to 120s):

```bash
docker compose down            # or: docker compose stop
```

## Config web UI

Served by the `config-webui` s6 service and published to **host loopback only**:

```
http://127.0.0.1:8088/PalWorldSettingsEditor.html
http://127.0.0.1:8088/EngineIniPerformanceEditor.html
```

The live config is exposed read-only at `http://127.0.0.1:8088/current/` so the
editors can load it. Change the host port with `WEBUI_PORT` in `.env`. The
editors are client-side only — they generate INI/env text; they don't write back
to the server (that's what the config tooling does).

## Managing config and saves

Persisted in named volumes:

| Volume | Mounted at | Holds |
|--------|-----------|-------|
| `palworld-server` | `/opt/palworld/server` | Full game install (SteamCMD downloads persist) |
| `palworld-saved` | `/opt/palworld/server/Pal/Saved` | Worlds + `Config/LinuxServer/PalWorldSettings.ini` |

Edit the live config until env-driven rendering lands in a later increment:

```bash
docker compose exec palwarden \
  sh -c 'vi /opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini'
docker compose restart palwarden
```

Prefer **bind mounts** (e.g. to back up saves with host tools)? Replace the
volume entries in `compose.yaml`, e.g.:

```yaml
    volumes:
      - /srv/palwarden/server:/opt/palworld/server
      - /srv/palwarden/saved:/opt/palworld/server/Pal/Saved
```

Match host ownership to the container's `steam` user (uid/gid **1000**), and note
the runbook's warning against blanket recursive `chown` of the volume.

## External mode (preview)

Set `PALWARDEN_MODE=external` and point `PALWORLD_TARGET_HOST` at your existing
server. Today the container logs the target and exits (nothing to manage yet);
a later increment gives it the tooling to actually drive that server. Your
existing server must expose its REST API reachably (private network / SSH tunnel
— never the public Internet).

## Security notes

- The REST API (`8212/tcp`) is **not** published to the host; keep it that way.
- The web UI is published to `127.0.0.1` only.
- No secrets are baked into the image; `.env`, `settings.env`, and `notify.env`
  are git-ignored and stay on the host / in volumes.
- Workloads run as the non-root `steam` user (uid/gid 1000). The s6 supervisor
  runs as PID 1 root only to manage services — a conventional, rootless-workload
  posture. A fully rootless variant is a possible future option.

## Configuration reference

All knobs live in `.env` (see [`.env.example`](.env.example)):
`COMPOSE_PROFILES`, `PALWARDEN_MODE`, `UPDATE_ON_START`, `PALWORLD_GAME_PORT`,
`WEBUI_PORT`, `PALWORLD_TARGET_HOST`, `PALWORLD_REST_PORT`.

## Image internals

- Base: `cm2network/steamcmd` (SteamCMD + 32-bit libs + non-root `steam` user).
- Supervisor: `s6-overlay` v3. Services live in
  [`s6-rc.d/`](s6-rc.d/) (`palworld-server`, `config-webui`).
- Entrypoint (`entrypoint.sh`) does the embedded bootstrap from
  [`../docs/palworld-service-runbook.md`](../docs/palworld-service-runbook.md)
  §12 — optional SteamCMD update, seed `PalWorldSettings.ini` — then `exec /init`
  to hand off to s6.
- Server launch flags, app id `2394010`, and the VM `LD_LIBRARY_PATH` are
  preserved; stop forwards SIGINT for a clean save.
