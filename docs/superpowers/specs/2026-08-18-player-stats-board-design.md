# Per-player stats board (save-derived) — Design

**Problem:** Presence tracking (2026-08-16) tells us *who* was on and *when*;
the save files hold *what they did*. `Players/<uid>.sav` carries `RecordData` —
an itemized activity ledger: every item ever crafted with counts, captures per
pal species, paldeck unlocks, fish per species, dungeons/towers cleared, NPC
talk counts, fast-travel unlocks, camps conquered (verified against the
production world 2026-08-16, game v1.0.x). The Players page should show it.

**Solution:** A `palworld-player-stats` tool parses the per-player save files
into a JSON snapshot on a periodic tick, re-parsing only files whose mtime
changed. A `/api/player-stats` read endpoint serves the snapshot; the Players
page joins it to the presence cards by UID (`Players/<uid>.sav` filename ==
REST `playerId` == `player_identity.player_uid`). This increment also
deliberately forces the save reader into existence with zero risk — pure
reads — ahead of Discord milestones (backlog item 10) and player export
(item 11).

**Scope:** `Players/*.sav` only. `Level.sav` is out: its character blobs
uniquely add only exp/HP/pal-counts (name and level already arrive live via
presence), and it costs a ~100 MB decompress. Operator decision 2026-08-18.

## Save container + GVAS format

The `.sav` container (game v1.0.x): `u32 uncompressed_len, u32 compressed_len,
3-byte magic, u8 type`, payload at `data[12:12+compressed_len]`.

- Magic `PlM`, type 1 → Oodle-compressed; decompress with `pyooz`
  (GPL-3.0-or-later PyPI wheel), imported **lazily and only on this path**.
- Magic `PlZ`, type 1 → zlib; stdlib. The game itself still accepts PlZ
  saves, so this branch is genuinely correct, not a test convenience —
  though it is also what lets the test fixtures avoid pyooz entirely.

Dispatch is by magic; there is no codec env knob. If pyooz is missing and a
PlM file is encountered, parsing reports a machine-readable
`parser-unavailable` state — never a crash, and never triggered on machines
that only ever see PlZ.

The decompressed payload is GVAS. Our reader (`lib/palwarden_gvas.py`,
first-party, written against the wire format with `palworld-save-tools` 0.24.0
(MIT) as reference — see `CREDITS.md`) parses the property subset a Player
save uses. Quirks verified against production saves (2026-08-16):

- `SetProperty` (upstream lacks a working reader): fstring inner type, an
  optional-guid pad byte, u32 "removes", u32 count, then elements — struct
  elements are property lists (properties-until-None), **not** raw Guids.
- **Per-field degradation is the architecture, not an option.** The game's
  format drifts across patches; an unknown property type is skipped with its
  size field, recorded in `parse_errors`, and every sibling still parses. A
  reader that raises on novelty breaks the whole board on every game update.

## Snapshot (the tool's only output)

`/var/lib/palworld/player-stats.json` (0644, env
`PALWARDEN_PLAYER_STATS_FILE`), written atomically (tmp + rename, the
`palworld-service-events` idiom):

```json
{
  "schema_version": 1,
  "generated_at": "2026-08-18T12:00:00Z",
  "world_dir": "/opt/palworld/server/Pal/Saved/SaveGames/0/<world>/",
  "status": "ok",
  "degraded_reason": null,
  "players": {
    "<32-hex-uppercase-uid>": {
      "parse_status": "ok",
      "parse_errors": [],
      "source_mtime": 1755518400,
      "parsed_at": "2026-08-18T12:00:00Z",
      "stats":   { "captures_total": 412, "towers_cleared": 3, "...": 0 },
      "records": { "TowerBossDefeatFlag": {"...": true}, "...": {} }
    }
  }
}
```

- `status`: `ok | parser-unavailable | no-world-dir | multiple-world-dirs`;
  `degraded_reason` carries the human sentence (including the install hint
  for `parser-unavailable`).
- `parse_status`: `ok | partial | error | unreadable`; `partial` means some
  properties degraded (listed, bounded, in `parse_errors`).
- Per-uid entries whose source mtime is unchanged are carried forward
  untouched (a refresh pass over an idle server is a handful of `stat()`
  calls). Entries whose `.sav` vanished are pruned.
- **`records` exists for item 10.** The Discord milestone job will diff
  successive snapshots ("new tower boss defeated", "first legendary craft");
  aggregates alone would throw that information away. The page renders only
  `stats`.

## v1 aggregates (no ID→name tables)

Friendly-name tables (boss/item ID → display name) are item 10's content
work. v1 ships only aggregates that need none:

| aggregate | source (`RecordData.*`) |
|---|---|
| `towers_cleared` | `TowerBossDefeatFlag` — count of true |
| `bosses_defeated` | `NormalBossDefeatFlag` — count of true |
| `captures_total` / `species_captured_distinct` | `PalCaptureCount` — sum / key count |
| `paldeck_unlocked` | `PaldeckUnlockFlag` — count of true |
| `relics_obtained` | `RelicObtainForInstanceFlag` — count of true |
| `notes_obtained` | `NoteObtainForInstanceFlag` — count of true |
| `fast_travels_unlocked` | `FastTravelPointUnlockFlag` — count of true |
| `items_crafted_total` | craft ledger — **name TBD** |
| `fish_caught_total` / `fish_species_distinct` | fish ledger — **name TBD** |
| `npc_talks_total` | NPC talk ledger — **name TBD** |
| `dungeons_cleared` | dungeon ledger — **name TBD** |

TBD names are pinned by running `palworld-player-stats dump` against a real
production player save (read-only copy) before the mapping is finalized; an
aggregate whose property is absent or unparsed is simply absent from `stats`
— per-field degradation makes shipping the known subset safe.

## Refresh model

A periodic background job runs `refresh`; the endpoint only reads.

- Bare metal: `palworld-player-stats.{service,timer}` — oneshot under
  `flock`, `User=palworld` (unprivileged: reads the save tree, writes only
  `/var/lib/palworld`), every 60 s.
- Container: `docker/s6-rc.d/player-stats/` via `palwarden-run-periodic`
  as `steam`, `PLAYER_STATS_INTERVAL` default 60, enabled by the entrypoint
  in **embedded mode only** (external mode has no local save tree).

60 s deliberately undercuts any plausible autosave interval: a no-change pass
costs almost nothing, so the snapshot is fresh within a minute of every
autosave — which is the latency floor item 10's announcements inherit.
Data freshness is still bounded by the game's autosave; the page says so.

## Reading a save safely

The game rewrites saves on autosave and at exit. `refresh` never parses a
live file: bounded copy to scratch (size cap 64 MiB; Players saves are ~1 MiB),
verify the magic and lengths post-copy, retry once on a torn read, parse the
copy. A file that stays torn is `parse_status: unreadable` for this pass —
its previous good entry is retained; only `source_mtime` freshness is lost.

## Failure & degradation modes

`refresh` always exits 0 and always writes a snapshot; degradation is state,
not failure. No world dir / multiple world dirs / pyooz missing → top-level
`status` + `degraded_reason`. Unknown property → `partial` + `parse_errors`.
Unreadable file → `unreadable`, siblings unaffected. The page renders
whatever is present and shows the degraded notice; a stats fetch failure
degrades the page to presence-only.

## Security notes

- UIDs enter the system as filenames: strict `^[0-9A-F]{32}$` on the stem,
  anything else skipped and logged. Normalized uppercase; also validated
  client-side as a join key.
- Save-derived strings (property names, map keys) are player-influenceable.
  They are counted, and echoed only as bounded `records` keys and truncated
  `parse_errors` entries; the page renders everything via `textContent`
  (structural checker enforces no HTML sinks).
- The snapshot contains no secrets and is 0644 in `/var/lib/palworld`.
- `refresh` runs unprivileged (`palworld`/`steam`); the copy uses
  `O_NOFOLLOW`-style discipline and a size cap.

## Dependencies & licensing

`pyooz` 0.0.8 (GPL-3.0-or-later; abi3 manylinux wheel) is the one new
dependency, optional at runtime. GPLv3+ combines cleanly with our
AGPL-3.0-or-later. The underlying `ooz` is a reverse-engineering of
proprietary Oodle carrying per-file GPL headers — provenance caveat recorded
in `CREDITS.md`. Docker installs it behind `WITH_PLAYER_STATS=true`; bare
metal is a documented `pip install pyooz` step (the deb cannot depend on it).
`palworld-save-tools` is **not** a dependency — MIT-licensed format
reference only, credited.

## Non-goals (this increment)

- `Level.sav` in any form (exp/HP/pal counts wait; item 11 may force it).
- Friendly names for bosses/items/species (item 10 content work).
- Discord announcements (item 10 — it diffs this snapshot's `records`).
- Appearance, quest, and recipe payloads from the player save.
- Historical stat timelines; the snapshot is current-state only.
