# Docker roadmap

Goal: a single **all-in-one image** that runs the Palworld dedicated server
*and* the `palwarden` tooling, so the whole stack deploys as one container.

This is a planning sketch, not a committed design. It records what has to change
because the tooling currently assumes a full systemd host.

## What doesn't translate as-is

The tooling was built for a VM and leans on host features a container normally
lacks:

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

## Suggested increments

1. **Containerize the server alone** (server + volumes + ports), no tooling —
   prove SteamCMD-on-volume + save persistence.
2. **Add a supervisor** and port the long-running pieces (server + web UI).
3. **Port the timers** one at a time to cron/s6, starting with `fps-sample` and
   `update-check`.
4. **Abstract host-isms** (`systemctl`/cgroup) behind a small status helper with
   a container backend, so `status`/`memory-watch`/`health-report` work.
5. **Entrypoint config rendering** from env → `settings.env` → apply on boot.

## Open questions

- Base image: `steamcmd/steamcmd` vs. a slim Debian + SteamCMD install.
- Supervisor choice: s6-overlay (smaller, container-native) vs. supervisord
  (simpler to author).
- How to handle the `palworld-config-parser` binary — keep vendored, or replace
  with an in-repo parser so the image has no opaque third-party binary
  (ties into the attribution TODO in [`tools.md`](tools.md#palworld-config-parser)).
