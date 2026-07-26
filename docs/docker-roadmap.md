# Docker roadmap

Goal: a single **all-in-one image** that runs the Palworld dedicated server
*and* the `palwarden` tooling, so the whole stack deploys as one container.

> **Status: done.** The port is complete and verified against the real game — see
> [Verified against a real server](#verified-against-a-real-server) below, and
> [`../docker/README.md`](../docker/README.md) for how to actually run it. The
> sections that follow are kept as the record of what had to change and why,
> which is useful when touching the container again.

## What didn't translate as-is

The tooling was built for a VM and leaned on host features a container normally
lacks. Each of these is now resolved (see [Increments](#increments)):

| Assumption today | Why it's a problem in a container | Direction |
|------------------|-----------------------------------|-----------|
| **systemd** runs the server + all timers | Containers don't run systemd by default | Replace units with a lightweight init/process supervisor: **s6-overlay** or **supervisord**; convert `*.timer` jobs to cron or s6 timers. |
| `sudo` / root-owned `palworld` user | Containers should run as one non-root user | Run as a single `palworld` UID; drop `sudo` calls (already root-in-namespace or use `gosu`). |
| Absolute paths (`/opt/palworld`, `/etc/palworld`, `/var/lib/palworld`) | Fine in a container, but must be **volumes** to persist | Mount saves, config, and `metrics.sqlite3` as named volumes. |
| `systemctl is-active` / `MemoryCurrent` / cgroup queries in `palworld-status`, `memory-watch` | No systemctl; cgroup layout differs | Abstract "is the server up / how much RAM" behind a small helper with a container backend (read `/proc`, cgroup v2 files, or the supervisor's status). |
| `needrestart` apt hooks | No apt/unattended-upgrades in the image | Drop; image updates happen by rebuilding/repulling. |
| SteamCMD update flow writes into the image | Game files must live on a volume, not the layer | Install/update the server into a mounted volume on first boot; `palworld-update` still works, targeting that volume. |

## What already fits

- All the **REST API** logic (`palworld-api`, graceful stop/restart, telemetry
  sampling) works over `127.0.0.1:8212` inside the container unchanged.
- The **telemetry DB**, **config apply/snapshot/rollback**, and **Discord notify**
  are plain files + HTTP; they only need their directories mounted as volumes.
- The **web UI** is static — serve it on `127.0.0.1:8088` (or an internal port)
  the same way.

## Proposed shape

```
palworld-aio (image)
├── s6-overlay (or supervisord) as PID 1
│   ├── longrun: PalServer.sh                (the server)
│   ├── longrun: config-webui http.server    (127.0.0.1:8088)
│   └── cron/timers:
│       ├── fps-sample        (15s)
│       ├── update-check      (30m)
│       ├── memory-watch      (5m)
│       ├── public-info-watch (10m)
│       └── daily-health-report (09:00)
├── /home/palworld/tooling      ← this repo (bin/sbin/lib/webui)
└── volumes:
    ├── /data/server            ← game install + Pal/Saved (saves, config)
    ├── /data/etc               ← settings.env, notify.env, engine.env
    └── /data/lib               ← metrics.sqlite3, public-info.env
```

Config via env vars → an entrypoint renders `settings.env` and runs
`palworld-config-apply-env` on boot, so the container is configured the
"12-factor" way while still reusing the existing apply logic.

## Chosen architecture: one all-in-one image, MODE-toggled

Rather than separate server and tools images, `palwarden` is a **single image**
that plays one of two roles at runtime via `PALWARDEN_MODE`:

- **`embedded`** — install/update and run the Palworld server here, with the
  tooling alongside talking to it over localhost. Self-contained.
- **`external`** — do not run the server; the tooling targets an existing server
  at `PALWORLD_TARGET_HOST`. Lean, because game files live in a volume, not the
  image.

This matches the original "all-in-one docker including the actual server" goal
while still letting one artifact manage an external server. A slim tools-only
image variant (no SteamCMD layer) is a possible future addition for
external-only users.

## Increments

1. **Server component + embedded/external toggle** — ✅ **done** (this increment).
   All-in-one image on `cm2network/steamcmd`, non-root, mutable game volume,
   entrypoint per runbook §12, compose profiles for the two modes. Lives in
   [`../docker/`](../docker/). Server runs as PID 1 via `exec` (no supervisor
   yet). Verified: image builds, mode dispatch works, tooling baked in; a full
   embedded game-download boot was not run end-to-end.
2. **Add a supervisor** — ✅ **done**. s6-overlay is PID 1; the server and the
   config web UI run as supervised s6 services (`docker/s6-rc.d/`), each dropped
   to the unprivileged `steam` user. Stop forwards SIGINT for a clean save.
   Verified: image builds, both services start, web UI serves (HTTP 200),
   non-root workloads, graceful stop completes without SIGKILL. Full embedded
   game boot still not run E2E.
3. **Port the timers** to s6 — 🟡 **started**. The `fps-sample` telemetry job
   now runs under s6 via `palwarden-run-periodic`, target-aware
   (`REST_API_HOST`), which makes **external** mode functional for monitoring.
   Minimal env→`settings.env`/`notify.env` rendering (REST connection + webhook)
   is done in the entrypoint, and services are selected at runtime by mode +
   config. Verified end-to-end: embedded (with/without telemetry) and external
   sampling a live REST stub. **Deferred to increment 4** (need host-ism
   abstraction): `update-check` (systemctl→s6 restart), `memory-watch` (cgroup),
   `public-info-watch`, and the daily report (+ matplotlib for graphs).
4. **Abstract host-isms** — ✅ **done**. `systemctl`/`sudo` shims map to
   s6/cgroup so the scripts run unchanged. Ported the **memory watchdog** (runs
   as root; restarts via s6 down-signal SIGINT) and a **daily Discord report**
   (matplotlib graphs included). Switched the server to direct-binary
   supervision with `down-signal=SIGINT` so stop/restart/shutdown save cleanly;
   `palworld-graceful-restart`/`-stop` gained container branches. Verified:
   all five services up under s6, shims resolve, graceful restart cycles the
   service, watchdog OK path, clean SIGINT shutdown, matplotlib graph rendered.
   **Deferred to increment 5:** `update-check` (in-container self-update:
   s6 down → SteamCMD → up) and `public-info-watch` (needs a configurable
   hostname + IP source).
5. **Server-config rendering + test suites** — ✅ **done**. The entrypoint
   renders `settings.env`/`notify.env` from env via `palwarden-render-config`
   (values shell-quoted so spaces/metacharacters survive) and applies them to
   `PalWorldSettings.ini` with `palworld-config-apply-env` on boot: setting
   `ADMIN_PASSWORD` enables the REST API and any `PALWORLD_CFG_<KEY>` becomes a
   server setting. `config-apply-env`/`config-pretty` gained `PALWORLD_USER/GROUP`
   overrides (default `palworld`; container uses `steam`). Added unit + docker
   integration test suites under `tests/`. Verified end-to-end: env →
   `settings.env` → `RESTAPIEnabled=True` + `ServerName`/`AdminPassword` applied.

6. **Finish the last timers** — ✅ **done**. `update-check` (opt-in
   `UPDATE_CHECK=true`) runs as root and reuses the systemctl shim + container
   graceful-stop for a s6 down → SteamCMD → up flow; SteamCMD drops to steam via
   `PALWORLD_DROP_PRIV`. `public-info-watch` (opt-in `PUBLIC_HOSTNAME`) runs as
   steam. `palworld-update`/`public-info-watch` gained env overrides
   (`PALWORLD_STEAMCMD`, `PALWORLD_DROP_PRIV`, `PALWORLD_INSTALL_DIR`,
   `PALWORLD_CONFIG_FILE`, `PALWORLD_PUBLIC_INFO_FILE`, `PUBLIC_HOSTNAME`) — all
   backward compatible. Unit tests cover the buildid check and join-info write.
   The full apply-update path (real Steam build event) is not exercised E2E.

## Verified against a real server

The port is complete and has been exercised against the actual game
(**v1.0.1.100619**), not just dummies:

- A full embedded boot: SteamCMD installs ~5GB into the volume, s6 starts the
  server, it reaches `Running Palworld dedicated server on :8211`, the REST API
  answers, env-driven config is applied, and `docker stop` saves the world.
- Config durability: with both config files mutable, custom settings survived
  repeated restarts and all 119 `PalWorldSettings.ini` keys were retained — which
  is why the `chattr +i` protection was removed again.

Automated suites cover the rest with dummy servers, a REST stub and a fake
SteamCMD (see [`../tests/README.md`](../tests/README.md)).

## Still open / optional

- A **slim tools-only image** variant (no SteamCMD layer) for external-only users.
- A **fully rootless** supervisor variant (s6 currently runs as PID 1 root; all
  workloads already drop to `steam`).
- Publishing the image (e.g. GHCR) once the repo has a remote.
- From [`backlog.md`](backlog.md): a crash/restart watchdog summary, and wiring
  health-report failures into alert-only notifications.

## Open questions

- Whether to also publish a **slim tools-only image** for external-only users
  who don't want the SteamCMD base layer.
- ~~How to handle the `palworld-config-parser` binary~~ — **resolved**: replaced
  by a first-party Python implementation, so the image contains no opaque
  third-party executable (see [`../CREDITS.md`](../CREDITS.md)).
