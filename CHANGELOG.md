# Changelog

All notable changes to palwarden are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
adheres to [semantic versioning](https://semver.org/).

Release convention: before pushing a tag `vX.Y.Z`, add its `## [X.Y.Z] -
YYYY-MM-DD` section on master (the date is the release date). The release
workflow refuses to build a tag whose section is missing. GitHub's
auto-generated per-release notes (PR list) are produced separately by the
release pipeline; this file is the curated, in-repo history.

## [Unreleased]

### Fixed
- WebUI cross-origin 403s are now actionable (issue #19). When a panel loaded
  from a routable bind is refused by the loopback-only origin guard, the 403
  detail says the request *is* same-origin and names the
  `PALWARDEN_WEBUI_ORIGIN_HOSTS` opt-in instead of reading like a token bug;
  the pages' own 403 note only blames the API token when the server actually
  refused the token. The guard itself is unchanged (fail-closed; DNS-rebinding
  refusals pinned). Documented in docker/README and runbook §14.

## [0.2.0] - 2026-11-02

### Added
- Idle shutdown and knock wake for embedded servers (PR #15, #16). After
  `IDLE_TIMEOUT` minutes of observed empty telemetry the server stops
  gracefully; a UDP "knock" on the game port wakes it, subject to
  `KNOCK_COOLDOWN` and an optional `KNOCK_TOKEN`. New s6 services
  (`idle-watch`, `palworld-knock`, `jobd`) and a lifecycle lock/state
  machine fence wake, backup, and restore operations against each other.
  Settings are panel-managed (`/api/palwarden-config`); the `IDLE_*` /
  `KNOCK_*` environment entries are first-boot seeds, not live settings.
  Container-only for now; bare-metal supervision is a follow-up. See
  runbook §17 and docker/README.
- Save-derived player stats board (PR #14). The Players cards now show
  level, health, and other stats read from the world saves, refreshed by a
  new `player-stats` service (`PLAYER_STATS_INTERVAL`, default 60s) and
  served at `GET /api/player-stats`. Save decompression needs the optional
  `pyooz` dependency (GPL-3.0-or-later); without it the board degrades
  per-field and reports why. Included in the image by default
  (`WITH_PLAYER_STATS=true`); bare metal needs `pip install pyooz`.
- Live test tier (`./tests/run.sh --live`) exercising a real throwaway
  server, plus its guard and plumbing.
- `--reset-world` flag on `palworld-restore`, as the spec promised.

### Fixed
- Restores across a mount point now swap directory *contents* instead of
  the directory itself, and every scratch destination is created through
  the descriptor that owns it (no rename-aside window).
- `palworld-api` prints its HTTP status line to stderr so the JSON body on
  stdout stays machine-parseable; presence polling in-container works
  again.
- Presence ignores the placeholder `playerId` the REST API sends while a
  player is still loading in.

### Changed
- CI runs once per PR: the workflow's push trigger is scoped to master.

### Upgrade notes
- Keep idle shutdown off across an upgrade (`IDLE_TIMEOUT=0` is the
  default); enable it only after the telemetry page shows healthy empty
  observations (runbook §17, upgrade/rollback).
- An empty `KNOCK_TOKEN` is an open doorbell: any UDP packet on the
  published port can wake the server. Set a token if the port is exposed.
- Idle/knock is supervised in the container only; the deb/rpm/arch
  packages do not yet ship bare-metal units for it.

## [0.1.0] - 2026-08-17

### Added
- Live server configuration from the web UI with a unified design system
  (PR #1).
- FPS lows read under the names `palworld-fps` actually emits (PR #3), and
  Discord FPS graphs brought to the dashboard, themed to the page (PR #4).
- Player presence on the dashboard (PR #6).
- nfpm packaging: deb, rpm, and Arch packages (PR #8).
- Tag-driven release pipeline: full test suite, package install tests,
  GHCR image push, and a gated GitHub release (PR #9).

### Fixed
- `settings.env` readability after install (PR #8).
