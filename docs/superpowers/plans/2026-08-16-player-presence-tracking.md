# Player presence & playtime tracking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record who is online on every 15-second sampler tick, accumulate
per-player playtime the save files don't contain, and read it back via CLI,
API, and a dedicated Players tab in the web UI.

**Architecture:** No new service and no new timer. `palworld-api` gains a
`players` action; `palworld-fps sample` (already fired every 15 s by
`palworld-fps-sample.timer` / the `fps-sample` s6 service) gains a
failure-tolerant presence pass writing two new tables in `metrics.sqlite3`;
a `playtime` subcommand, a `/api/playtime` read endpoint, and a new Players
page (its own sidebar tab) read it back.

**Tech Stack:** Python 3 stdlib + sqlite3 (existing). Bash +
`tests/lib/assert.sh` for tests. No new dependencies of any kind.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-16-player-presence-design.md`. Read its
  `## Data model`, `## Session logic`, and `## Deliberately not stored`
  sections before Task 2.
- **No new dependencies.** This increment is REST + sqlite only. (pyooz and
  save parsing belong to the stats-board increment, not this one.)
- **Host-portable:** every new knob is an env override with a
  bare-metal-preserving default (`PALWORLD_API_BIN`,
  `PALWARDEN_PRESENCE_GRACE_MS`, `--presence-retention-days`).
- **A failed players fetch must never break metrics sampling**, and vice
  versa. `sample` exits 0 on API failure today; that contract holds.
- **Never store `ip`, `ping`, or `location`** from the REST payload (spec:
  "Deliberately not stored"). A test greps for this.
- **Player names are untrusted text.** The Players page renders them with
  `textContent` only; the structural checker already forbids new sinks — do
  not fight it.
- SPDX headers on new files; existing files keep their headers.
- After every task: `./tests/run.sh` (the two known environmental failures on
  the yggdrassil sandbox — `chgrp nogroup`, `/tmp` uid 65534 — are expected).

## Interfaces that already exist

- `sbin/palworld-api` — bash case statement mapping actions to REST calls
  (`save`, `stop`, `info`, `metrics`); credentials come from the settings env.
- `sbin/palworld-fps` — `connect()` creates all tables idempotently
  (`fps_samples`, `fps_events`); `sample()` fetches metrics via
  `API_HELPER` (line ~28, currently a hardcoded constant), inserts, prunes,
  exits 0 even on failure. `now_ms()`, `iso_utc()` helpers exist.
- `sbin/palwarden-webui` — `READ_ENDPOINTS` dict of `(query) -> dict`
  wrappers; `run_tool_json` handles tool failure as `{"ok": false}` data;
  stubs live in `tests/unit/test_webui_server.sh` under
  `PALWARDEN_SBIN_DIR="$WORK/sbin"`.
- `webui/palwarden.html` — `pw-grid` of `.pw-card` tiles; `put(id, rows)`
  renders label/value rows via `textContent`; `refresh()` polls every 15 s.
- Test conventions: `tests/unit/test_*.sh` sourcing `tests/lib/assert.sh`,
  ending with `assert_report`; sqlite fixtures built by invoking the real
  tools against `mktemp -d` paths.

## File Structure

```
sbin/palworld-api                        # + players action
sbin/palworld-fps                        # + PALWORLD_API_BIN, presence tables,
                                         #   presence pass in sample, playtime cmd
sbin/palwarden-webui                     # + /api/playtime read endpoint
webui/players.html                       # NEW — the Players tab
webui/{palwarden,backups}.html           # + Players nav item
webui/{PalWorldSettings,EngineIniPerformance}Editor.html  # + Players nav item
tests/unit/test_player_presence.sh       # NEW — presence + playtime logic
tests/unit/test_api_exit_codes.sh        # + players action coverage
tests/unit/test_webui_server.sh          # + /api/playtime endpoint tests
tests/unit/test_webui_backups.sh         # + Players page/nav asserts
tests/unit/test_webui_jobs.sh            # + players.html in structural checker
docs/tools.md                            # palworld-api, palworld-fps, endpoint
docs/superpowers/specs/2026-08-16-player-presence-design.md  # exists
```

---

### Task 1: `palworld-api players` + testable helper path

The REST action, and the seam every later test depends on: `API_HELPER`
becomes overridable so `sample` can be driven against a stub.

- [ ] **Step 1: Write the failing tests**
  - In `tests/unit/test_api_exit_codes.sh`, extend the existing pattern:
    `players` must issue `GET /v1/api/players` (the stub curl/http layer the
    file already uses records method+path) and the usage line must name it.
  - Start `tests/unit/test_player_presence.sh`: build `$WORK/bin/palworld-api`
    as a stub answering `metrics` with canned JSON and `players` with
    `{"players": [...]}` read from `$WORK/players.json` (so each test case
    swaps who is online by rewriting one file). Assert
    `PALWORLD_API_BIN="$WORK/bin/palworld-api" palworld-fps sample --db "$WORK/m.sqlite3"`
    exits 0 and `fps_samples` gained a row — proving the override is honored
    end-to-end before any presence logic exists.
- [ ] **Step 2: Run tests to verify they fail** (unknown action; hardcoded path).
- [ ] **Step 3: Implement**
  - `palworld-api`: add `players) method=GET; path=/v1/api/players; body='' ;;`
    and extend the usage string.
  - `palworld-fps`: `API_HELPER = os.environ.get("PALWORLD_API_BIN", "/usr/local/sbin/palworld-api")`.
    Nothing else changes.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Mutation-check** — break the path (`/v1/api/player`) and the
  env fallback default; confirm each is caught.
- [ ] **Step 6: Commit.**

### Task 2: Presence recording in `sample`

The heart of the increment: two tables, the grace-window session logic, and
the failure-tolerance contract. Spec sections `## Data model` and
`## Session logic` are the source of truth for schema and semantics.

- [ ] **Step 1: Write the failing tests** in `test_player_presence.sh`.
  Drive the real `palworld-fps sample` against the stub; inspect the DB with
  `sqlite3`/inline python. Cases, each a named assert:
  1. First sighting: one identity row (uid, steam id, name, level,
     first_seen==last_seen, total_play_ms==0) and one session (samples==1).
  2. Second tick within grace: same session extended, samples==2,
     `total_play_ms` grew by exactly `last_seen_new - last_seen_old`.
  3. Tick beyond grace (`PALWARDEN_PRESENCE_GRACE_MS=1`): a second session
     row; `total_play_ms` did NOT grow from the split.
  4. Rename: same uid with a new name updates `player_identity.name`,
     row count stays 1.
  5. Players fetch fails (stub exits 1 for `players` only): `sample` still
     exits 0, `fps_samples` still gains its row, presence tables untouched.
  6. Metrics fetch fails but players succeeds: presence still recorded
     (independence in both directions).
  7. Two players online: two identities, two sessions, no cross-talk.
  8. `ip`, `ping`, `location_x` present in the stub payload: assert no
     column and no stored value contains them
     (`sqlite3 ... ".schema"` + a value grep).
  9. Retention: a session with `last_seen_ms` older than
     `--presence-retention-days` is pruned; the identity row and its
     `total_play_ms` survive.
- [ ] **Step 2: Run tests to verify they fail.**
- [ ] **Step 3: Implement**
  - Schema in `connect()` exactly as specced (idempotent DDL + index).
  - `fetch_players(timeout)` mirroring `fetch_metrics` (`[API_HELPER, "players"]`,
    `extract_json`, raise on non-zero).
  - `record_presence(con, players, now_ms, grace_ms)` — pure function taking
    the parsed list, so the logic is testable without subprocess gymnastics:
    upsert identity, extend-or-open session, increment `total_play_ms` by the
    extension delta only.
  - In `sample()`: wrap the presence pass in its own try/except that prints a
    one-line warning to stderr and never changes the exit code; add
    `--presence-retention-days` (default 90) pruning `player_sessions` only.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Mutation-check the grace boundary** — flip `<=` to `<` at the
  grace comparison and confirm case 2 or 3 catches it; drop the
  `total_play_ms` increment and confirm case 2 catches it.
- [ ] **Step 6: Commit.**

### Task 3: `palworld-fps playtime` subcommand

- [ ] **Step 1: Write the failing tests** — seed a DB via Task-2 machinery,
  then: `--json` emits per player `name`, `player_uid`, `steam_userid`,
  `level`, `first_seen`/`last_seen` (ISO UTC), `sessions`, `total_play_seconds`,
  `play_7d_seconds`, `online` (bool: last_seen within grace of now); the
  human output contains the name and an `h`/`m` duration; empty DB prints a
  friendly line and exits 0.
- [ ] **Step 2: Run tests to verify they fail.**
- [ ] **Step 3: Implement** — `playtime(args)` + argparse wiring
  (`--json`, `--db`). `play_7d_seconds` sums session overlap with the last
  7 days (clamp `started_at` to the window edge).
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Mutation-check the 7d clamp** — a session straddling the
  window boundary must count only the inside portion.
- [ ] **Step 6: Commit.**

### Task 4: `GET /api/playtime`

- [ ] **Step 1: Write the failing tests** — in `test_webui_server.sh`: extend
  the `palworld-fps` stub to answer `playtime --json` with canned JSON
  (argv-logged like the graph tests); assert 401 unauthenticated, 200 with
  the JSON under `data` authenticated, and that a failing stub surfaces as
  `"ok": false` (the run_tool_json contract).
- [ ] **Step 2: Run tests to verify they fail** (404 today).
- [ ] **Step 3: Implement** — `ep_playtime(_query)` returning
  `run_tool_json([str(SBIN / "palworld-fps"), "playtime", "--json"])`;
  register `"/api/playtime"` in `READ_ENDPOINTS`. No parameters, so no
  allowlist needed.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Commit.**

### Task 5: The "Players" page — a new sidebar tab

A first-party page (`webui/players.html`, AGPL, SPDX headers), not a dashboard
tile — operator decision: this page is where the future stats board grows.
Adding a tab touches **every** page's static sidebar markup, and the test
suites pin that nav thoroughly; update them deliberately, not reactively.

- [ ] **Step 1: Write the failing tests**
  - `test_webui_backups.sh`: add `players.html` to the nav-loop — every
    nav-bearing page (dashboard, backups, both editors, AND the new page)
    links `href="players.html"`; the new page links all five tabs and marks
    itself `aria-current="page"`; it carries SPDX headers; it fetches
    `/api/playtime`; it contains a "tracked since" qualifier; per-player
    rows render through `textContent` helpers.
  - `test_webui_jobs.sh`: add `players.html` to the structural checker's page
    list (colors only via `palwarden-ui.css` link, no inline `style=`, no
    HTML sinks, localStorage only for theme).
- [ ] **Step 2: Run tests to verify they fail** (no page, missing nav links).
- [ ] **Step 3: Implement**
  - `webui/players.html`: shared sidebar markup (copy an existing page's,
    plus the new item — pick a "people" icon in the existing SVG style),
    `palwarden-ui.css` + `palwarden-ui.js`, one `.pw-section` card per
    player (unused accent color): name in the header with an ONLINE
    `pw-pill--ok` / last-seen date, content shows level, playtime `Xh Ym`,
    sessions, first-seen; a page-level "playtime tracked since first login
    after <ship date>" note. Empty data → "No players seen yet." Poll
    every 30 s (presence granularity is 15 s; the page needn't outpace it).
  - Add the Players nav item to the sidebars of `palwarden.html`,
    `backups.html`, `EngineIniPerformanceEditor.html`,
    `PalWorldSettingsEditor.html`.
- [ ] **Step 4: Run tests + view both themes** against the live container
  (deploy via `docker cp`, screenshot light and dark, sidebar collapsed and
  expanded, and the settings editor's live-mode nav).
- [ ] **Step 5: Commit.**

### Task 6: Docs + full sweep

- [ ] **Step 1:** `docs/tools.md` — `palworld-api` action table gains
  `players`; `palworld-fps` section gains the presence behavior of `sample`
  (tables, grace, retention, what is deliberately not stored) and the
  `playtime` subcommand row; the webui endpoint list gains `/api/playtime`.
- [ ] **Step 2:** `docs/architecture.md` — one paragraph: presence rides the
  fps sampler; playtime is observed, not save-derived; tracked-since caveat.
- [ ] **Step 3:** Full `./tests/run.sh` and `RUN_INTEGRATION=1` if the sandbox
  allows; commit.

---

## Verification (whole-increment)

1. All unit suites pass (modulo the two known environmental failures).
2. On the live embedded server: log a test client in (or wait for a real
   player on prod after deploy), watch `palworld-fps playtime` go from empty
   → one identity with a growing total across two ticks.
3. `/api/playtime` returns the same through the webui with Basic auth.
4. The Players page renders in both themes and its tab appears on every
   page; a REST outage (stop the server) degrades it to its error row
   without breaking the page.
