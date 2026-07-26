# palwarden in Docker

An **all-in-one image** for Palworld: one artifact that can either **run the
dedicated server itself** (self-contained) or **manage an existing server**
elsewhere. Which role it plays is chosen at runtime, not at build time.

> **Status — increment 1:** the **server / embedded** half is functional. The
> **management tooling** (config rendering, REST wrappers, telemetry, timers) and
> therefore the *active* part of **external** mode are wired in the next
> increment. See [`../docs/docker-roadmap.md`](../docs/docker-roadmap.md).

## The two modes

| | `embedded` | `external` |
|---|-----------|-----------|
| **What runs** | Palworld server (+ tooling, next increment) | Tooling only, targeting your existing server |
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
docker compose logs -f palworld-server
```

Wait for `Running Palworld dedicated server on :8211`. First boot downloads the
game via SteamCMD (a few GB), so it takes a while. Players connect on
`UDP 8211` (host port set by `PALWORLD_GAME_PORT`).

Stop gracefully (SIGINT, up to 120s to save and exit):

```bash
docker compose down            # or: docker compose stop
```

## Managing config and saves

Persisted in named volumes:

| Volume | Mounted at | Holds |
|--------|-----------|-------|
| `palworld-server` | `/opt/palworld/server` | Full game install (SteamCMD downloads persist) |
| `palworld-saved` | `/opt/palworld/server/Pal/Saved` | Worlds + `Config/LinuxServer/PalWorldSettings.ini` |

Edit the live config until env-driven rendering lands next increment:

```bash
docker compose exec palworld-server \
  sh -c 'vi /opt/palworld/server/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini'
docker compose restart palworld-server
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
the next increment gives it the tooling to actually drive that server. Your
existing server must expose its REST API reachably (e.g. over a private network
or SSH tunnel — never the public Internet).

## Security notes

- The REST API (`8212/tcp`) is **not** published to the host; keep it that way.
- No secrets are baked into the image; `.env`, `settings.env`, and `notify.env`
  are git-ignored and stay on the host / in volumes.
- The container runs as the non-root `steam` user (uid/gid 1000).

## Configuration reference

All knobs live in `.env` (see [`.env.example`](.env.example)):
`COMPOSE_PROFILES`, `PALWARDEN_MODE`, `UPDATE_ON_START`, `PALWORLD_GAME_PORT`,
`PALWORLD_TARGET_HOST`, `PALWORLD_REST_PORT`.

## Image internals

- Base: `cm2network/steamcmd` (SteamCMD + 32-bit libs + non-root `steam` user).
- Server startup follows [`../docs/palworld-service-runbook.md`](../docs/palworld-service-runbook.md)
  §12: optional SteamCMD update → seed `PalWorldSettings.ini` from default →
  `exec PalServer.sh -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS`.
- `STOPSIGNAL SIGINT`, `nofile=100000`, app id `2394010`, and the VM's
  `LD_LIBRARY_PATH` are preserved.
