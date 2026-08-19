# Palworld Tooling Ideas Backlog

Recorded: 2026-07-10

These are follow-up ideas for later review after the FPS telemetry, Engine.ini tuning editor, and event markers.

## 1. Config snapshot + label tool — implemented

Implemented in `/usr/local/sbin/palworld-config-snapshot`. Example:

```bash
sudo /usr/local/sbin/palworld-config-snapshot "balanced-60-tps-before-restart"
```

Potential output:

```text
/opt/palworld/config-snapshots/20260710T1425-balanced-60-tps/
  Engine.ini
  Engine.pretty.ini
  PalWorldSettings.ini
  PalWorldSettings.pretty.ini
  metrics.json
  system.txt
```

Purpose:

- Capture exact config + live state before/after tuning experiments.
- Make rollbacks and performance comparisons less ambiguous.

## 2. Before/after performance comparison — implemented

Implemented in `/usr/local/sbin/palworld-fps compare`. Example:

```bash
sudo /usr/local/sbin/palworld-fps compare --before 1h --after 1h --mark "Balanced 60 TPS"
```

Potential output:

```text
Before:
  avg: 58.9
  1% low: 55.0
  0.1% low: 54.0

After:
  avg: 59.1
  1% low: 58.0
  0.1% low: 56.0
```

Purpose:

- Turn tuning experiments into evidence-backed results.
- Support comparing windows around event markers or explicit timestamps.

## 3. Broader daily server health report — implemented

Extend or complement the FPS daily report with:

- FPS average / 1% lows / 0.1% lows
- current and peak player count
- API failure count
- memory current/peak
- disk usage
- restart count / recent event markers
- local Steam buildid and game version

Implemented commands:

```bash
sudo /usr/local/sbin/palworld-health-report report
sudo /usr/local/sbin/palworld-health-report discord --window 24h
```

Purpose:

- Give one Discord-safe daily operational summary.
- Highlight problems before they become player-facing.

## 4. Player count history graph panel — implemented

Implemented in `/usr/local/sbin/palworld-fps report --graph ...` and `discord`:

- top panel: FPS / server FPS average
- bottom panel: player count
- event markers spanning both panels

Purpose:

- Interpret FPS lows in context of server population.
- Distinguish idle-server dips from player-load-induced dips.

## 5. Engine profile rollback helper — implemented

Implemented in `/usr/local/sbin/palworld-engine-config rollback`:

```bash
sudo /usr/local/sbin/palworld-engine-config rollback --list
sudo /usr/local/sbin/palworld-engine-config rollback Engine.ini.20260710T182037Z
```

Expected behavior:

- Restore selected Engine.ini backup.
- Regenerate Engine.pretty.ini.
- Record an FPS event marker.
- Remind operator to run graceful restart.

Purpose:

- Make tuning experiments reversible without manual file surgery.

## 6. Engine config status/profile match — implemented

Implemented in `/usr/local/sbin/palworld-engine-config status`:

```bash
sudo /usr/local/sbin/palworld-engine-config status
```

Potential output:

```text
Active managed Engine.ini values:
- NetServerMaxTickRate=60
- MaxClientRate=100000
- MaxInternetClientRate=100000
...

Current profile match:
- Balanced 60 TPS: exact match
```

Purpose:

- Quickly understand whether the live Engine.ini matches a known profile.
- Detect manual drift.

## 7. Automatic event markers for more operational actions

Initial marker integration exists for:

- Engine.ini config apply
- PalWorldSettings.ini config apply
- graceful restart requested/completed
- Palworld update detected/completed

Potential future integrations:

- backup creation/restoration
- world save events, if useful and not too noisy
- manual maintenance windows
- crash/restart detection from systemd journal

Purpose:

- Improve graph context without making samplers noisy.

## 8. Crash/restart watchdog summary — implemented

Implemented in `/usr/local/sbin/palworld-service-events`:

```bash
sudo /usr/local/sbin/palworld-service-events sample            # periodic (timer / s6)
sudo /usr/local/sbin/palworld-service-events summary --since 24h
```

It samples the service's state and main PID and records a marker when they change,
classifying restarts as planned (we asked) or unexpected (crash/OOM/external).
Counts feed the daily health report, and the markers appear on the FPS graphs.

Purpose:

- Correlate crashes/restarts with FPS drops and config changes.
- Feed daily health report.

## 9. Per-player stats board (save-derived)

Recorded: 2026-08-16. **Shipped 2026-08-18** — spec:
`docs/superpowers/specs/2026-08-18-player-stats-board-design.md`;
`palworld-player-stats` (refresh/show/dump), `lib/palwarden_gvas.py`,
`/api/player-stats`, stats on the Players page, 60s timer + s6 service.
The snapshot's `records` section keeps the per-key ledgers item 10 will
diff. Everything below stands as the original design record. Grow the Players tab (shipped with presence tracking —
see `docs/superpowers/specs/2026-08-16-player-presence-design.md`) into a full
stats board using the save files themselves.

What the saves hold per player (verified against the production world,
2026-08-16, game v1.0.x):

- `Players/<uid>.sav`: appearance (full character-creator state), quest and
  recipe progress, and `RecordData` — an itemized activity ledger: every item
  ever crafted with counts, captures per pal species, paldeck unlocks, fish
  per species, dungeons/towers cleared, NPC talk counts, fast-travel unlocks,
  camps conquered. A genuine playstyle fingerprint.
- `Level.sav` character blobs: nickname, level, exp, HP; pal ownership counts.
- NOT in any save: playtime (that is why presence tracking exists), SteamIDs
  (presence captures those from the REST players call).

Implementation notes, learned the hard way:

- Saves are **PlM magic = Oodle-compressed** (since ~0.6). Pure-python
  `palworld-save-tools` (MIT) parses the GVAS but needs `pyooz` (PyPI wheel)
  for decompression — the increment's one new dependency (verify license
  before vendoring anything). The upstream tool lags the game: v1.0 saves
  needed a hand-patched `SetProperty` reader, and the guild-blob decoder is
  broken upstream. Any parser we ship must degrade per-field, not crash.
- Player `.sav` files parse in well under a second. The full `Level.sav` is
  ~100 MB decompressed and takes minutes + ~700 MB RAM in pure python —
  never do that on the game host per request. The needed character blobs are
  findable by scanning the decompressed bytes and parsing only those (~seconds).
- Read copies, never the live files: the game rewrites saves on autosave and
  at exit. Copy, check the header, retry on a torn read.
- Shape: a `palworld-player-stats` tool producing a JSON snapshot on an
  mtime-based cache, a read endpoint, and the Players page rendering the
  extra sections per card. Data freshness = last autosave.

## 10. Discord milestone announcements

Recorded: 2026-08-16. A periodic job diffs successive save-derived snapshots
(item 9's reader) and announces transitions via the existing `palworld-notify`
webhook: new tower boss defeated, level thresholds (50/60/70/max — not every
level), first crafts of curated legendary items.

Design constraints settled during feasibility review:

- **Rollback safety is the hard requirement**: the announced-set must persist
  independently of the snapshot (announce only never-before-announced
  milestones), or restoring a backup replays weeks of achievements into
  Discord when the flags regress and re-appear.
- Latency is autosave interval + poll interval (~10–30 min after the fact);
  set expectations rather than forcing saves.
- Needs curated tables that are content work, not code work: tower-boss ID →
  friendly name, and a legendary-item ID list (IDs shift across patches).
- Levels come from the `Level.sav` character-blob scan; boss flags and craft
  counts from the per-player `.sav` (`TowerBossDefeatFlag`,
  `NormalBossDefeatFlag`, `CraftItemCount`).

## 11. Player save export

Recorded: 2026-08-16. Let a departing player take their character with them.
The honest constraint: **a character is not contained in `Players/<uid>.sav`**
— level, inventory contents, and owned pals live in `Level.sav`, so there are
two tiers:

- **Tier 1 (small):** a jobd export action that zips `Players/<uid>.sav` +
  `_dps.sav` + a manifest, served through the same authenticated download
  pattern as backup archives. The player grafts it into their own world with
  the community character-transfer tools. Frame it as "your save files +
  instructions", not "click to play single-player".
- **Tier 2 (deep):** perform the surgery ourselves — extract the character
  blob, owned pals, and inventory containers from `Level.sav` and inject them
  into a fresh single-player world. Proven possible (community transfer
  scripts do it) but it *writes* save data in a format that drifts every
  game patch; a bug corrupts someone's exported character. Only attempt after
  the item-9 reader has survived a couple of game updates unmodified.

## Prioritized next steps

1. ~~Add crash/restart watchdog summary.~~ — done, see item 8.
2. Consider wiring health report failures into alert-only notifications.
3. ~~Stats board (item 9).~~ — done 2026-08-18; the save reader exists and
   has parsed production saves with zero errors.
4. Milestone announcements (item 10) — diff the stats snapshot's `records`
   (already retained per refresh) plus the curated name tables.
5. Export tier 1 (item 11) — cheap, any time; tier 2 waits for reader
   maturity across game patches.
