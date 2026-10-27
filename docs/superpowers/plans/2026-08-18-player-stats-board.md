# Per-player stats board — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parse `Players/<uid>.sav` (`RecordData` activity ledgers) into a
periodically refreshed JSON snapshot, serve it via `/api/player-stats`, and
render per-player stats on the existing Players page — joined to presence by
UID, degrading gracefully at every layer.

**Architecture:** A first-party GVAS reader in `lib/palwarden_gvas.py`
(magic-driven PlM→pyooz / PlZ→zlib codec dispatch, per-field degradation);
`sbin/palworld-player-stats` with `refresh` (mtime-cached parse → atomic
snapshot), `show --json` (codec-free read), and `dump` (RecordData
introspection); a periodic tick per platform (systemd timer / s6
run-periodic, 60 s); a standard READ_ENDPOINTS entry; extra card rows on
`webui/players.html`.

**Tech Stack:** Python 3 stdlib everywhere except `pyooz`
(GPL-3.0-or-later, optional at runtime — its absence is a reported state,
never a crash). Bash + `tests/lib/assert.sh` for tests; PlZ (zlib) fixtures
so the suite needs no pyooz.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-18-player-stats-board-design.md`.
  Its `## Snapshot`, `## v1 aggregates`, and `## Security notes` sections are
  the source of truth for schema, fields, and validation.
- **Read copies, never live files.** Bounded copy → verify header → retry
  once on torn read. The game rewrites saves on autosave and exit.
- **Per-field degradation** in the parser; **degradation is state, not
  failure** in the tool (`refresh` always exits 0, always writes a snapshot).
- **Host-portable:** every knob is env-overridable with bare-metal-preserving
  defaults (`PALWORLD_SAVED_DIR` honored even set-empty — copy
  `sbin/palworld-restore:128-136` semantics byte-for-byte;
  `PALWARDEN_PLAYER_STATS_FILE`; `PLAYER_STATS_INTERVAL` in the container).
- **UID discipline:** filename stems must match `^[0-9A-F]{32}$`; skip and
  log everything else. Save-derived strings are untrusted; the page renders
  via `textContent` only (the structural checker enforces this — don't fight
  it).
- `show --json` must work without pyooz installed (no codec imports on the
  read path) — the webui depends on that.
- SPDX AGPL headers on new first-party files. No new deb dependencies;
  Docker's pyooz install stays behind an ARG.
- After every task: `./tests/run.sh` (the two known environmental failures
  on the yggdrassil sandbox — `chgrp nogroup`, `/tmp` uid 65534 — are
  expected).

## Interfaces that already exist

- `sbin/palworld-restore:128-136` — the saved-dir resolution house rule;
  `:299-350 _scratch_copy` — bounded-copy idiom.
- `sbin/palworld-service-events:99-110` — atomic JSON state write idiom.
- `sbin/palwarden-webui` — `READ_ENDPOINTS` (:761), `run_tool_json` (:552),
  `ep_playtime` (:642) as the model endpoint; tools stubbed in tests via
  `PALWARDEN_SBIN_DIR` (`tests/unit/test_webui_server.sh:19-88`, argv-log
  pattern).
- `webui/players.html` — presence cards, `textContent`-only rendering, 30 s
  poll; structural checker in `tests/unit/test_webui_jobs.sh:564` already
  covers this page; nav/content asserts in
  `tests/unit/test_webui_backups.sh:672`.
- `systemd/palworld-fps-sample.{service,timer}` — the oneshot+timer shape
  (note: fps runs as root; the new unit is `User=palworld`, deliberately).
- `docker/s6-rc.d/fps-sample/run` + `docker/palwarden-run-periodic` — the
  periodic s6 service shape; `docker/entrypoint.sh:198 enable_service` +
  mode gates near `:264-285`.
- `docker/Dockerfile:19-41` — the `WITH_GRAPHS` optional-dependency ARG
  pattern to mirror for `WITH_PLAYER_STATS`.
- `packaging/nfpm.yaml` globs `sbin/*`, `lib/*`, `systemd/*.service`,
  `systemd/*.timer` — new files need zero packaging changes.
- `lib/` is importable via the `sbin/palwarden-webui:52-62` sys.path idiom
  (installed `/usr/local/lib` + repo-relative fallback for dev checkouts).

## File Structure

```
lib/palwarden_gvas.py                      # NEW — container + GVAS reader
sbin/palworld-player-stats                 # NEW — refresh / show --json / dump
sbin/palwarden-webui                       # + ep_player_stats endpoint
webui/players.html                         # + stats rows, freshness, notice
systemd/palworld-player-stats.service      # NEW — oneshot, flock, User=palworld
systemd/palworld-player-stats.timer        # NEW — 60 s
docker/s6-rc.d/player-stats/{run,type,timeout-kill}  # NEW longrun
docker/entrypoint.sh                       # + enable_service (embedded only)
docker/Dockerfile                          # + ARG WITH_PLAYER_STATS, pip pyooz
tests/lib/gvas_fixture.py                  # NEW — synthetic PlZ .sav builder
tests/unit/test_player_stats.sh            # NEW — lib + tool coverage
tests/unit/test_webui_server.sh            # + /api/player-stats
tests/unit/test_webui_backups.sh           # + players.html stats asserts
docs/{tools,architecture,backlog}.md  CREDITS.md  README.md  docker/README.md
```

---

### Task 1: `lib/palwarden_gvas.py` + fixture builder

The reader and the seam every later test depends on: PlZ fixtures built with
stdlib zlib exercise the full container + GVAS + degradation path with no
pyooz anywhere.

- [ ] **Step 1: Write the failing tests**
  - `tests/lib/gvas_fixture.py`: builds a minimal Player `.sav` — GVAS
    header, a `SaveData` StructProperty containing a `RecordData` struct of
    MapProperties (`PalCaptureCount` name→int, `TowerBossDefeatFlag`
    name→bool, `PaldeckUnlockFlag`, `FastTravelPointUnlockFlag`), zlib
    payload, `PlZ` magic, type 1. Parameterized so tests can inject extra /
    malformed properties.
  - Start `tests/unit/test_player_stats.sh` (drive python inline). Cases:
    fixture maps round-trip through the reader; truncated file, wrong magic,
    and lying `uncompressed_len` each produce a clean typed error (the
    torn-read signal); **an unknown property type inside RecordData is
    skipped, recorded in errors, and every sibling still parses** (the
    load-bearing degradation case); a `PlM` file with pyooz absent yields
    the `ParserUnavailable` sentinel, not an exception escape.
- [ ] **Step 2: Run tests to verify they fail** (module doesn't exist).
- [ ] **Step 3: Implement** — container reader (magic dispatch, lazy pyooz
  import), GVAS property readers for Int/Int64/UInt32/Float/Bool/Str/Name/
  Enum/Struct/Array/Map/Set, the SetProperty quirks from the spec, and the
  per-property try/except that records-and-skips by the property's size
  field.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Mutation-check** — break the optional-guid pad-byte handling
  and delete the per-field try/except; confirm each is caught.
- [ ] **Step 6: Commit.**

### Task 2: `sbin/palworld-player-stats`

- [ ] **Step 1: Write the failing tests** — build a fake world tree in
  `mktemp -d` (`Pal/Saved/SaveGames/0/<32hex>/Players/*.sav` from the
  fixture builder). Cases: `refresh` writes the spec's snapshot schema
  (version, status ok, per-uid stats + records + mtimes); zero and two
  world dirs → degraded statuses, exit 0; `evil.sav` / lowercase / 31-hex
  filenames skipped; **mtime carry-forward** (replace file content while
  preserving mtime → stats stay stale on the next refresh); torn read
  (header lies about lengths) → `unreadable` after one retry, siblings
  fine, previous good entry retained; deleted `.sav` pruned; atomic write
  (no partial file visible); `show --json` echoes the snapshot and never
  imports the codec; `dump` prints RecordData keys and shapes; env
  overrides incl. set-empty `PALWORLD_SAVED_DIR`.
- [ ] **Step 2: Run tests to verify they fail.**
- [ ] **Step 3: Implement** per spec: saved-dir resolution copied
  byte-for-byte from `palworld-restore`, world-dir glob, uid regex, scratch
  copy with 64 MiB cap + post-copy header verify + one retry, aggregate
  mapping (`## v1 aggregates` table), records retention, atomic snapshot,
  argparse subcommands in the house shape.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Pin the TBD property names** — copy one production player
  `.sav` (read-only, over SSH) and run `dump` against it; add the real
  craft/fish/NPC-talk/dungeon property names to the aggregate table (spec +
  code + fixtures). Absent names stay absent from `stats` — safe either way.
- [ ] **Step 6: Mutation-check** — break the mtime comparison and the uid
  regex; confirm each is caught.
- [ ] **Step 7: Commit.**

### Task 3: `GET /api/player-stats`

- [ ] **Step 1: Write the failing tests** — in `test_webui_server.sh`: stub
  `palworld-player-stats` in `$WORK/sbin` answering `show --json` with a
  canned snapshot (argv-logged); assert 401 unauthenticated, 200 with the
  snapshot under `data` authenticated, failing stub → `"ok": false`.
- [ ] **Step 2: Run tests to verify they fail** (404 today).
- [ ] **Step 3: Implement** — `ep_player_stats(_query)` wrapping
  `run_tool_json([str(SBIN / "palworld-player-stats"), "show", "--json"])`;
  register `"/api/player-stats"` in `READ_ENDPOINTS`. No query params.
- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Commit.**

### Task 4: Players page stats rendering

- [ ] **Step 1: Write the failing tests** — `test_webui_backups.sh`:
  players.html fetches `"/api/player-stats"`, contains the freshness string
  ("stats as of") and the degraded-notice hook, renders stat labels;
  `test_webui_jobs.sh` structural checker must stay green unchanged.
- [ ] **Step 2: Run tests to verify they fail.**
- [ ] **Step 3: Implement** — second fetch in `refresh()` (its failure
  degrades to presence-only, never breaks the page); join
  `players[uid.toUpperCase()]`; append `dt/dd` rows via `textContent` for
  present aggregate keys only; per-card "stats as of HH:MM" from
  `parsed_at`; page-level notice when `status != "ok"` showing
  `degraded_reason`.
- [ ] **Step 4: Run tests + view both themes** against the live container
  (docker cp, screenshot light/dark).
- [ ] **Step 5: Commit.**

### Task 5: systemd units

- [ ] **Step 1: Write the failing tests** — grep-assert the pair exists:
  `Type=oneshot`, `flock -n /run/palworld-player-stats.lock`,
  `User=palworld`, timer `OnUnitActiveSec=60`.
- [ ] **Step 2–4: Implement, verify, commit** — model on
  `palworld-fps-sample.{service,timer}`; comment the deliberate `User=`
  divergence. nfpm globs pick both up; no packaging change.

### Task 6: Docker wiring

- [ ] **Step 1:** `docker/s6-rc.d/player-stats/` longrun:
  `exec s6-setuidgid steam palwarden-run-periodic
  "${PLAYER_STATS_INTERVAL:-60}" player-stats palworld-player-stats refresh`.
- [ ] **Step 2:** entrypoint: `enable_service player-stats` in the
  **embedded-mode** gate only.
- [ ] **Step 3:** Dockerfile: `ARG WITH_PLAYER_STATS=true` mirroring
  `WITH_GRAPHS`; pip-install pinned `pyooz` (PEP 668: `--break-system-packages`
  or venv fallback — **verify the abi3 wheel installs on the steamcmd base
  here** and settle the mechanism).
- [ ] **Step 4:** Build both ARG values; in the `false` image confirm
  `refresh` degrades to `parser-unavailable` gracefully. Integration tests
  if the sandbox allows.
- [ ] **Step 5: Commit.**

### Task 7: Docs + credits + full sweep

- [ ] **Step 1:** `docs/tools.md` — new tool section (subcommands, env vars,
  snapshot path, the bare-metal `pip install pyooz` step and its optionality);
  webui endpoint list gains `/api/player-stats`.
- [ ] **Step 2:** `docs/architecture.md` — one paragraph (snapshot pipeline,
  read-only saves, degradation ladder). `docs/backlog.md` — item 9 progress
  note + pointer that `records` exists for item 10's diffing.
- [ ] **Step 3:** `CREDITS.md` — pyooz (GPL-3.0-or-later) + the ooz
  provenance caveat; palworld-save-tools (MIT) as format reference.
  `README.md` / `docker/README.md` — feature line + ARG.
- [ ] **Step 4:** Full `./tests/run.sh` and `RUN_INTEGRATION=1` if the
  sandbox allows; commit.

---

## Verification (whole-increment)

1. All unit suites pass (modulo the two known environmental failures).
2. Live embedded container: `refresh` against the real world; `show --json`
   sane; `/api/player-stats` via Basic auth; Players page shows stats +
   freshness in both themes; stopping the refresh job degrades the page to
   presence-only.
3. `WITH_PLAYER_STATS=false` image boots and the page shows the
   parser-unavailable notice with the install hint.
4. Prod dry run (read-only): `dump` + parse one real player save locally;
   aggregates plausible for a known player.
