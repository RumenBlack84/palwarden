# Spec: Docker-only support and bare-metal migration

Date: 2026-11-03 · Status: reviewed (§8) — awaiting user sign-off ·
Author: Brian Grant + agent · Supersedes: none · Affects: v0.3.0 plan

## 1. Background and decision

palwarden supports two deployments: bare metal (systemd + deb/rpm/arch
packages) and an all-in-one Docker container (s6-overlay, embedded or
external mode). Every lifecycle feature now pays a dual-supervision tax,
and the bare-metal side is the unexercised half:

- No observable bare-metal user base: 0 stars/forks; both releases'
  package assets show null/zero downloads (v0.1.0 published 2026-08-17).
- The integration suite is Docker/s6 only; systemd/palwarden-jobd.service
  comments state no bare-metal job chain has ever been exercised.
- The flagship 0.2.0 feature (idle shutdown + knock wake) is
  container-only by design; porting it to systemd is estimated at 2-4
  days, dominated by the need for a new systemd test tier.
- The maintainer's own server is bare metal and is the last real
  deployment blocking consolidation; it will be migrated (this spec, §3).

Decision: the Docker container becomes the only supported deployment
target. Bare metal is frozen at the v0.2.0 feature set — no new
features, critical fixes only — until removal in v0.3.0.

## 2. Support policy and deprecation cycle

- v0.2.x: packages keep building and installing (the release pipeline
  already install-tests them per distro), but README, docker/README, and
  the runbook gain a deprecation banner: bare metal is deprecated,
  container is the supported path, migration guide is §X of the runbook.
- v0.3.0: removal sweep (§4). Announced in CHANGELOG.md (gate already
  enforces the entry) and the GitHub release body.
- No new features land on the bare-metal path in the interim, including
  idle-knock systemd units (explicitly dropped from the backlog).

## 3. Migration guide (runbook: new section, container chapter)

Written for any operator moving a live bare-metal server to the
container; the maintainer's cutover is the reference instance.

### 3.1 Preconditions
- Docker + Compose v2 on the target host; the palwarden repo or image
  available; maintenance window (server offline for the copy).
- Game version note: the container installs the current version via
  SteamCMD on first boot (`UPDATE_ON_START=true` default). Migrating a
  save forward one game version is normal; migrating *backwards* is not
  supported. Record the bare-metal game version before stopping.

### 3.2 Stop and copy the world
1. Graceful stop on bare metal so the world saves:
   `systemctl stop palworld.service` (PalServer exits on SIGINT and
   saves; watch the journal for save completion).
2. Copy the save tree off the host:
   `/opt/palworld/server/Pal/Saved/` (world under
   `Pal/Saved/SaveGames/<guid>/`, config under
   `Pal/Saved/Config/LinuxServer/`).
3. Into the container: bring the stack up once with an empty
   `palworld-saved` volume, stop it, then `docker compose cp` the
   `SaveGames/` tree into `/opt/palworld/server/Pal/Saved/` (the
   runbook §11 volume-ownership rules apply: never chown the mounted
   volume; the image pre-creates the paths steam-owned).

### 3.3 Settings
Two supported paths; pick one:
- Reuse the ini: place the existing
  `Pal/Saved/Config/LinuxServer/PalWorldSettings.ini` in the volume.
  The game rewrites and normalises it but preserves values (measured,
  runbook/CLAUDE.md gotchas).
- Declarative: map the values to `PALWORLD_CFG_<KEY>` env vars in
  `docker/.env`; the entrypoint applies them via
  bin/palworld-config-parser.
Precedence note: `settings-overrides.env` (values saved from the web
editor) wins over `PALWORLD_CFG_*` on every start.

### 3.4 Ops state
| Bare metal | Container destination |
|---|---|
| `/opt/palworld/backups/` | `palwarden-backups` volume (`/opt/palworld/backups`) |
| `/opt/palworld/config-snapshots/` | `palwarden-config-snapshots` volume |
| `/opt/palworld/config-backups/` | `palwarden-config-backups` volume |
| `/var/lib/palworld/` (telemetry DB, job queue) | `palwarden-state` volume |
| `/etc/palworld/backup.env` | `/var/lib/palworld/backup.env` (state volume; compose pins `PALWORLD_BACKUP_SCHEDULE`) |
| `/etc/palworld/palwarden.env` (idle/knock knobs) | `palwarden-ops` volume (`/var/lib/palwarden-ops/palwarden.env`) — or re-seed via `IDLE_*`/`KNOCK_*` env, which are read only on first boot |
| `/etc/palworld/webui.env` credentials | re-created from `ADMIN_PASSWORD` at container start (no file copy) |
| `/etc/palworld/notify.env` (Discord webhook) | re-created from `DISCORD_WEBHOOK` at container start (no file copy) |
| `/var/lib/palworld/public-info.env` | covered by the `palwarden-state` volume copy |
| `/var/lib/palworld/uploads/` | deliberately NOT migrated — transient restore staging only |
| `/etc/palworld/engine.env` (Engine.ini managed values) | see caveat below |

Engine caveat: the container does not relocate `engine.env`
(`PALWORLD_ENGINE_ENV` defaults to `/etc/palworld/engine.env`, and
neither compose nor the entrypoint overrides it), so it lives in the
container's writable layer and resets on recreate. The Engine.ini
values themselves travel with the save copy (they live under
`Pal/Saved/Config/LinuxServer/`), but the drift-check baseline does
not: after migration, re-enter managed Engine overrides via the Engine
editor (which rewrites engine.env on the running container) and re-run
`palworld-engine-config --check`. Follow-up outside this spec's scope:
move engine.env onto the state volume like backup.env.

Lifecycle state: do NOT copy `/var/lib/palwarden-ops/lifecycle/` or
the knock cooldown file. The server is stopped during migration, so
the container should start from a fresh lifecycle state; copying a
stale `unsafe` marker fences every wake until
`acknowledge-maintenance --confirm`.

Transfer mechanics: `docker compose cp` in both directions, per the
existing image-upgrade migration text (runbook ~line 716). Secrets
never land in the image or the repo.

### 3.5 Bring-up and verification checklist
- `COMPOSE_PROFILES=embedded docker compose up -d --build`
- REST health on 8212 (internal), WebUI on 127.0.0.1:8088, game port
  published per `PALWORLD_GAME_PORT`.
- World continuity: same world GUID, base and characters present,
  player list via REST.
- Ops continuity: Backups page lists migrated archives; telemetry page
  accepts the new series; idle/knock panel shows expected settings.
- Public client join test before declaring done.

### 3.6 Rehearsal and rollback
- Rehearse first with a *copy* of the save on a disposable host (the
  live-testbed procedure in docs/tools.md#test-tiers): boot it in the
  container, verify continuity, discard. Only then cut over.
- Rollback: leave the bare-metal install disabled, not removed. Safe
  rollback exists until the container has booted the save with a newer
  game version; after that, rollback needs the pre-cutover save copy.
  Keep the pre-cutover copy until the container is stable (>=1 week).

## 4. v0.3.0 removal sweep

Remove: `systemd/`, `install.sh`, `packaging/`, the packages job and
its three install-test steps in `.github/workflows/release.yml`,
`tests/unit/test_install_plan.sh`, and the bare-metal `else` branches
in `sbin/` scripts (keep the container branches and `docker/shims/` —
`test_sudo_shim.sh`/`test_systemctl_shim.sh` stay). Rewrite CLAUDE.md's
"keep scripts host-portable" convention to container-first. Restructure
docs: runbook keeps its container chapters, bare-metal chapters move to
a frozen "v0.2.x legacy" appendix; README leads with compose.
CHANGELOG.md gets the removal entry (gate enforces it).

## 5. Acceptance criteria

1. Migration guide executed end-to-end on the local testbed with a
   copied save: rehearsal, cutover-equivalent, verification checklist,
   and one rollback drill — evidence logged like the live tier.
2. After v0.3.0: `./tests/run.sh --integration` green with the
   bare-metal code removed; release pipeline runs without the packages
   job; no doc references a removed path as supported.
3. The maintainer's server runs in embedded mode with idle-knock
   enabled for >=1 week before the removal tag is cut.

## 6. Out of scope
- systemd idle-knock units (superseded by this decision).
- External-mode feature expansion; k8s/helm packaging.

## 7. Risks and open questions
- Save-version coupling: rollback window closes once the container
  boots the save on a newer version (§3.6 mitigates; residual risk
  accepted).
- Volume seeding/ownership gotchas (§11) are the likeliest migration
  foot-gun; the rehearsal exists to catch exactly this.
- Unknown: whether any third party ever contacts about bare metal;
  policy then is "frozen at v0.2.x, community-maintained forks welcome"
  (AGPL permits).

## 8. Review record

- Independent review (isolated scout session, gemma route,
  deleg_2634b9b3): verdict APPROVE, zero findings. Caveat recorded in
  honesty: the reviewer's evidence cited content this spec does not
  contain (a "down marker" in §3.4/§3.6), so its clean pass was not
  fully trustworthy.
- Supplementary parent-side adversarial pass (same session, direct
  repo verification) found and folded in four gaps the reviewer
  missed: engine.env writable-layer caveat
  (`sbin/palworld-engine-config:28`, no compose/entrypoint override),
  notify.env/DISCORD_WEBHOOK recreation, public-info.env covered by
  the state volume, uploads deliberately unmigrated, and the
  do-not-copy-lifecycle-state rule (stale `unsafe` marker fences
  wakes; `lib/palwarden_lifecycle.py:82`).
- Gate status: PASS (isolated review + documented supplementary
  pass). Implementation plan derives from this spec only after user
  sign-off.
