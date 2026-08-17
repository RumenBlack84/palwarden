# Player presence & playtime tracking — Design

**Problem:** Palworld persists no playtime anywhere. The save files were checked
exhaustively (2026-08-16): the per-player `.sav` carries only
`LastOnlineDateTime`, the `Level.sav` character blobs carry level/exp/HP/name,
and every time-shaped key in the world save belongs to world mechanics (boss
respawns, lottery timers, base cooldowns). If we want "hours played" on a stats
board, we must observe it ourselves — and every day the observer isn't running
is history lost, which is why this ships before the stats board itself.

**Solution:** The 15-second `palworld-fps sample` tick already calls the game's
REST API. It gains a second, failure-tolerant call to `GET /v1/api/players`
(who is online right now) and folds what it sees into two new tables in the
same `metrics.sqlite3`. Playtime is the accumulated span of observed sessions.

## What the REST call provides

`/v1/api/players` answers per online player: `name`, `accountName`, `playerId`
(the save-file UID), `userId` (the SteamID), `ip`, `ping`, `location_x/y`, and
`level`. Verified answering on both the embedded test server and production
(2026-08-16, empty list — nobody online). This is also the **only** place the
SteamID↔UID↔name mapping exists; the save files deliberately omit it.

## Data model (new tables in `metrics.sqlite3`)

Created idempotently in `connect()` like every existing table, so old databases
upgrade on the first tick.

```sql
CREATE TABLE IF NOT EXISTS player_identity (
    player_uid    TEXT NOT NULL PRIMARY KEY,  -- REST playerId == Players/<uid>.sav
    steam_userid  TEXT,                       -- REST userId, e.g. steam_7656...
    name          TEXT NOT NULL,              -- latest seen; players can rename
    level         INTEGER,                    -- latest seen
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms  INTEGER NOT NULL,
    total_play_ms INTEGER NOT NULL DEFAULT 0  -- authoritative playtime total
);
CREATE TABLE IF NOT EXISTS player_sessions (
    player_uid    TEXT NOT NULL,
    started_at_ms INTEGER NOT NULL,
    last_seen_ms  INTEGER NOT NULL,
    samples       INTEGER NOT NULL            -- ticks that saw this session
);
CREATE INDEX IF NOT EXISTS idx_player_sessions_uid_time
    ON player_sessions(player_uid, last_seen_ms);
```

**Why `total_play_ms` lives on the identity row:** totals must survive any
future pruning of the sessions table. Each tick that *extends* a session adds
the extension delta to the identity total, so sessions are a queryable history,
never the source of truth for the headline number.

## Session logic (in `sample`, after the metrics insert)

For each player in the response, at tick time `now`:

1. Upsert `player_identity`: insert with `first_seen=now`, or update
   `name`, `level`, `steam_userid`, `last_seen_ms`. Names update because
   players can rename; the UID is the stable key.
2. Load the player's most recent session. If `now - last_seen_ms <= GRACE`,
   extend it (`last_seen_ms=now`, `samples+=1`) and add the delta to
   `total_play_ms`. Otherwise insert a new session starting at `now`
   (contributing 0 playtime until its first extension — a single sighting
   proves presence, not duration).

`GRACE` defaults to **60000 ms** (survives one missed 15 s tick plus jitter),
overridable via `PALWARDEN_PRESENCE_GRACE_MS` — an env override with a
bare-metal-preserving default, per repo convention, and the lever the tests use
to force session splits without sleeping.

**Failure is a gap, not an error.** If the players call fails (REST down,
server restarting), the tick records nothing for presence — sessions simply
don't extend, and a long outage splits a session in two. That undercounts,
which is the honest direction: we never invent presence we didn't observe. The
metrics fetch and the players fetch fail independently; one broken call must
not take down the other's recording.

**Retention:** identities are never pruned. Sessions get their own
`--presence-retention-days` (default 90; the existing 7-day metrics retention
is far too short for "when was Bryli last on?"). Row volume is trivial — a few
sessions per player per day.

## Deliberately not stored

`ip`, `ping`, and `location` from the REST payload. Presence exists to power a
stats board; a per-player IP ledger in the metrics DB is surveillance with no
reader, and the IPs already exist in the server logs for the operators who
need them (hygiene, same reasoning as ep_config's redaction). Location could
power a live map someday — that feature should sample live and store nothing.

## Reading it back

- **`palworld-fps playtime [--json]`** — per player: name, UID, SteamID,
  level, first/last seen, session count, total playtime, playtime in the last
  7 days (from sessions), and whether they're online now (last seen within
  grace). Human table on stdout by default, `--json` for the machine.
- **`GET /api/playtime`** on `palwarden-webui` — a standard READ_ENDPOINTS
  entry wrapping `palworld-fps playtime --json`. Basic auth like every read.
- **A dedicated "Players" page** (`webui/players.html`), its own tab in the
  sidebar on every page — per operator decision 2026-08-16, player stats get
  their own page rather than a dashboard tile, because this page is where the
  future stats board grows (per-player cards with save-derived stats), and
  the dashboard stays an at-a-glance summary. This increment ships the page
  with what presence provides: name, level, ONLINE/last-seen, session count,
  playtime, and a "tracked since" qualifier. All values rendered via
  `textContent` (REST strings are player-controlled text — names especially —
  and must never meet innerHTML).

## Testability

`API_HELPER` in `palworld-fps` is currently a hardcoded constant; it becomes
`PALWORLD_API_BIN` (env override, default `/usr/local/sbin/palworld-api`),
matching how every other script parameterizes paths for tests. Tests drive
`sample` against a stub helper that answers `metrics` and `players` with
canned JSON, using tiny/huge grace values to force or forbid session splits.

## Non-goals (this increment)

- Discord join/leave or milestone announcements (future; will diff this data).
- Save-file parsing (the stats board increment owns that).
- A live player map (would use `location_*`, stores nothing).
- Historical backfill: playtime is "tracked since" the feature ships. The
  dashboard should say so rather than present the total as all-time.
