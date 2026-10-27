#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Player presence & playtime (spec: docs/superpowers/specs/
# 2026-08-16-player-presence-design.md). Palworld persists no playtime, so the
# 15s sampler observes it: each tick that sees a player extends their open
# session and adds the delta to an identity-row total. These tests drive the
# real `palworld-fps sample` against a stub palworld-api whose /players answer
# is a file the test rewrites between ticks.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
FPS="$DIR/../../sbin/palworld-fps"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
DB="$WORK/metrics.sqlite3"

# The stub: `metrics` and `players` answer from files, so each case swaps the
# world by rewriting one file. MODE files make either call fail on demand.
cat > "$WORK/bin/palworld-api" <<EOF
#!/usr/bin/env bash
case "\$1" in
  metrics)
    [ -e "$WORK/metrics.fail" ] && { echo "metrics down" >&2; exit 1; }
    cat "$WORK/metrics.json" ;;
  players)
    [ -e "$WORK/players.fail" ] && { echo "players down" >&2; exit 1; }
    cat "$WORK/players.json" ;;
  *) echo "unexpected action \$1" >&2; exit 64 ;;
esac
EOF
chmod +x "$WORK/bin/palworld-api"

printf '{"serverfps": 59, "serverfpsaverage": 59.5, "serverframetime": 16.9, "currentplayernum": 1, "maxplayernum": 32, "uptime": 100}\n' > "$WORK/metrics.json"

# One online player, with the fields the REST API really sends — including the
# ones we must NOT store (ip, ping, location).
player_json() { # uid name level
  printf '{"players": [{"name": "%s", "accountName": "acct", "playerId": "%s", "userId": "steam_76561198000000001", "ip": "192.168.1.50", "ping": 23.5, "location_x": -103958.8, "location_y": 41054.2, "level": %s}]}\n' "$2" "$1" "$3"
}
player_json "022E0173000000000000000000000000" "Snax" 80 > "$WORK/players.json"

sample() {
  env PALWORLD_API_BIN="$WORK/bin/palworld-api" \
      ${GRACE_MS:+PALWARDEN_PRESENCE_GRACE_MS="$GRACE_MS"} \
      python3 "$FPS" --db "$DB" sample "$@"
}
# No sqlite3 CLI on every host; a python shim queries (and commits, so the
# retention test can seed a row through the same door).
q() { python3 - "$DB" "$1" <<'PYQ'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
cur = con.execute(sys.argv[2])
rows = cur.fetchall()
con.commit()
print("\n".join("|".join("" if c is None else str(c) for c in r) for r in rows))
PYQ
}

# --- Task 1: the override is honored end-to-end -------------------------------
out="$(sample 2>&1)"; rc=$?
assert_eq "$rc" "0" "sample exits 0 through the PALWORLD_API_BIN stub (output: $out)"
# ok=1 with the stub's exact fps — a count alone also passes for the error row
# a missing helper produces, which is precisely the mutation this must catch.
assert_eq "$(q 'SELECT ok, serverfps FROM fps_samples;')" "1|59.0" \
  "the stubbed metrics landed in fps_samples (not an error row)"

# --- first sighting ------------------------------------------------------------
assert_eq "$(q 'SELECT COUNT(*) FROM player_identity;')" "1" "first sighting creates one identity"
row="$(q 'SELECT player_uid, steam_userid, name, level, first_seen_ms == last_seen_ms, total_play_ms FROM player_identity;')"
assert_eq "$row" "022E0173000000000000000000000000|steam_76561198000000001|Snax|80|1|0" \
  "identity carries uid, steam id, name, level; first==last seen; zero playtime (got: $row)"
assert_eq "$(q 'SELECT COUNT(*), MAX(samples) FROM player_sessions;')" "1|1" \
  "first sighting opens one session with one sample"

# --- second tick within grace extends, and playtime grows by the delta ---------
sleep 1.1
out="$(sample 2>&1)"; rc=$?
assert_eq "$rc" "0" "second sample exits 0"
assert_eq "$(q 'SELECT COUNT(*) FROM player_sessions;')" "1" "within grace: still one session"
assert_eq "$(q 'SELECT samples FROM player_sessions;')" "2" "the session counted a second sample"
delta_ok="$(q 'SELECT (SELECT total_play_ms FROM player_identity) == (SELECT last_seen_ms - started_at_ms FROM player_sessions);')"
assert_eq "$delta_ok" "1" "total_play_ms equals the session span exactly"
play_now="$(q 'SELECT total_play_ms FROM player_identity;')"
assert_eq "$(q "SELECT $play_now >= 1000;")" "1" "the ~1.1s between ticks was credited (got ${play_now}ms)"

# --- a tick beyond grace opens a NEW session and credits nothing for the gap ---
sleep 0.2
out="$(GRACE_MS=1 sample 2>&1)"
assert_eq "$(q 'SELECT COUNT(*) FROM player_sessions;')" "2" "beyond grace: a second session"
assert_eq "$(q 'SELECT total_play_ms FROM player_identity;')" "$play_now" \
  "the split credited no playtime for the unobserved gap"

# --- rename updates the identity, does not fork it -----------------------------
player_json "022E0173000000000000000000000000" "SnaxRenamed" 81 > "$WORK/players.json"
sample >/dev/null 2>&1
assert_eq "$(q 'SELECT COUNT(*) FROM player_identity;')" "1" "a rename keeps one identity row"
assert_eq "$(q 'SELECT name, level FROM player_identity;')" "SnaxRenamed|81" \
  "the identity carries the latest name and level"

# --- players fetch fails: metrics still sampled, presence untouched, exit 0 ----
before_sessions="$(q 'SELECT COUNT(*) FROM player_sessions;')"
before_samples="$(q 'SELECT COUNT(*) FROM fps_samples;')"
touch "$WORK/players.fail"
out="$(sample 2>&1)"; rc=$?
rm -f "$WORK/players.fail"
assert_eq "$rc" "0" "a players failure never fails the sampler (output: $out)"
assert_contains "$out" "presence" "the players failure is named in the warning"
assert_eq "$(q 'SELECT COUNT(*) FROM fps_samples;')" "$((before_samples + 1))" \
  "metrics recording survived the players failure"
assert_eq "$(q 'SELECT COUNT(*) FROM player_sessions;')" "$before_sessions" \
  "no session was invented from a failed fetch"

# --- metrics fetch fails: presence still recorded (independence both ways) -----
before_play="$(q 'SELECT total_play_ms FROM player_identity;')"
touch "$WORK/metrics.fail"
sleep 0.3
out="$(sample 2>&1)"; rc=$?
rm -f "$WORK/metrics.fail"
assert_eq "$rc" "0" "a metrics failure still exits 0"
after_play="$(q 'SELECT total_play_ms FROM player_identity;')"
assert_eq "$(q "SELECT $after_play > $before_play;")" "1" \
  "presence extended despite the metrics failure (${before_play} -> ${after_play})"

# --- two players online: two identities, two sessions, no cross-talk -----------
printf '{"players": [{"name": "SnaxRenamed", "playerId": "022E0173000000000000000000000000", "userId": "steam_76561198000000001", "ip": "192.168.1.50", "ping": 20, "level": 81}, {"name": "Tolbi", "playerId": "EF576CE7000000000000000000000000", "userId": "steam_76561198000000002", "ip": "192.168.1.51", "ping": 31, "level": 72}]}\n' > "$WORK/players.json"
sample >/dev/null 2>&1
assert_eq "$(q 'SELECT COUNT(*) FROM player_identity;')" "2" "a second player gets their own identity"
assert_eq "$(q "SELECT COUNT(*) FROM player_sessions WHERE player_uid = 'EF576CE7000000000000000000000000';")" "1" \
  "the new player got their own session"
assert_eq "$(q "SELECT total_play_ms FROM player_identity WHERE player_uid = 'EF576CE7000000000000000000000000';")" "0" \
  "the new player's playtime starts at zero, not at the veteran's"

# --- a loading player's placeholder playerId never becomes an identity ---------
# While a player loads in, the REST API lists them with playerId "None"
# (observed on v1.0.3; some builds send all zeros). Both must be skipped, or
# every login funnels through one shared phantom identity keyed on the
# placeholder.
printf '{"players": [{"name": "SnaxRenamed", "playerId": "022E0173000000000000000000000000", "userId": "steam_76561198000000001", "level": 81}, {"name": "Tolbi", "playerId": "EF576CE7000000000000000000000000", "userId": "steam_76561198000000002", "level": 72}, {"name": "Grimnyr", "playerId": "None", "userId": "steam_76561198000000003", "level": 1}, {"name": "Bryli", "playerId": "00000000000000000000000000000000", "userId": "steam_76561198000000004", "level": 1}]}\n' > "$WORK/players.json"
sample >/dev/null 2>&1
assert_eq "$(q 'SELECT COUNT(*) FROM player_identity;')" "2" \
  "placeholder playerIds (None / all zeros) create no identity"
assert_eq "$(q "SELECT COUNT(*) FROM player_sessions WHERE player_uid IN ('None', '00000000000000000000000000000000');")" "0" \
  "placeholder playerIds open no session"

# --- ip / ping / location are never stored (spec: Deliberately not stored) -----
schema="$(q "SELECT sql FROM sqlite_master WHERE name IN ('player_identity', 'player_sessions')")"
for banned in ip ping location; do
  case "$schema" in
    *"$banned"*) assert_eq "found" "absent" "schema must not contain a '$banned' column" ;;
    *) assert_eq "absent" "absent" "schema has no '$banned' column" ;;
  esac
done
stored="$(q "SELECT * FROM player_identity")
$(q "SELECT * FROM player_sessions")"
assert_not_contains "$stored" "192.168.1.5" "no stored value carries a player IP"

# --- retention prunes old sessions but never the identity or its total ---------
q "INSERT INTO player_sessions (player_uid, started_at_ms, last_seen_ms, samples)
   VALUES ('022E0173000000000000000000000000', 1000, 2000, 2);"
old_total="$(q "SELECT total_play_ms FROM player_identity WHERE player_uid = '022E0173000000000000000000000000';")"
sample --presence-retention-days 1 >/dev/null 2>&1
assert_eq "$(q "SELECT COUNT(*) FROM player_sessions WHERE last_seen_ms = 2000;")" "0" \
  "an ancient session is pruned by --presence-retention-days"
assert_eq "$(q "SELECT COUNT(*) FROM player_identity;")" "2" "identities survive pruning"
new_total="$(q "SELECT total_play_ms FROM player_identity WHERE player_uid = '022E0173000000000000000000000000';")"
assert_eq "$(q "SELECT $new_total >= $old_total;")" "1" \
  "the playtime total survives session pruning"

# ==============================================================================
# `playtime` subcommand (Task 3)
# ==============================================================================
out="$(python3 "$FPS" --db "$DB" playtime --json 2>&1)"; rc=$?
assert_eq "$rc" "0" "playtime --json exits 0 (output: $out)"
for field in player_uid steam_userid name level first_seen last_seen sessions total_play_seconds play_7d_seconds online; do
  assert_contains "$out" "\"$field\"" "playtime --json carries $field"
done
assert_contains "$out" "SnaxRenamed" "playtime reports the latest name"
assert_contains "$out" "Tolbi" "playtime reports every known player"
assert_not_contains "$out" "192.168.1.5" "playtime never emits an IP"

# online flag: both were just seen, so both are online now
online_count="$(python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print(sum(1 for p in d["players"] if p["online"]))
PY
)"
assert_eq "$online_count" "2" "players seen within grace report online=true"

# the 7d window clamps a straddling session to its inside portion: a session
# entirely outside 7d contributes 0 to play_7d even while total keeps it
python3 - "$DB" <<'PY'
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1])
now = int(time.time() * 1000)
eight_days = 8 * 86400 * 1000
# 1h session ending 8 days ago (fully outside the window)
con.execute("INSERT INTO player_sessions (player_uid, started_at_ms, last_seen_ms, samples) VALUES (?, ?, ?, ?)",
            ("EF576CE7000000000000000000000000", now - eight_days - 3600_000, now - eight_days, 240))
# straddler: started 8 days ago, ended 6.5 days ago (only ~1.5d-boundary portion inside)
con.execute("INSERT INTO player_sessions (player_uid, started_at_ms, last_seen_ms, samples) VALUES (?, ?, ?, ?)",
            ("EF576CE7000000000000000000000000", now - eight_days, now - int(6.5 * 86400 * 1000), 240))
# Real recording credits the identity total as sessions extend; seeded history
# must do the same or "total keeps what the window excludes" tests nothing.
credited = 3600_000 + int(1.5 * 86400 * 1000)
con.execute("UPDATE player_identity SET total_play_ms = total_play_ms + ? WHERE player_uid = ?",
            (credited, "EF576CE7000000000000000000000000"))
con.commit()
PY
out="$(python3 "$FPS" --db "$DB" playtime --json 2>&1)"
tolbi_7d_total="$(python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
p = next(p for p in d["players"] if p["player_uid"].startswith("EF57"))
print(f"{p['play_7d_seconds']}|{p['total_play_seconds']}")
PY
)"
tolbi_7d="${tolbi_7d_total%%|*}"; tolbi_total="${tolbi_7d_total##*|}"
# inside portion of the straddler = 0.5 day = 43200s (±generous slack for runtime)
assert_eq "$(python3 -c "print(40000 <= $tolbi_7d <= 46000)")" "True" \
  "play_7d clamps the straddling session to its inside portion (got ${tolbi_7d}s)"
assert_eq "$(python3 -c "print($tolbi_total > $tolbi_7d)")" "True" \
  "total playtime keeps what the 7d window excludes"

# human output: names and a readable duration, and a friendly empty-DB message
out="$(python3 "$FPS" --db "$DB" playtime 2>&1)"
assert_contains "$out" "SnaxRenamed" "human output lists players"
assert_contains "$out" "m" "human output shows a duration unit"
EMPTY_DB="$WORK/empty.sqlite3"
out="$(python3 "$FPS" --db "$EMPTY_DB" playtime 2>&1)"; rc=$?
assert_eq "$rc" "0" "playtime on an empty DB exits 0"
assert_contains "$out" "No players" "an empty DB is a message, not a traceback"

# ==============================================================================
# Task 4 (idle-shutdown/knock-wake spec §5.1): presence_state singleton and the
# observation sequence fence. Idle eligibility must rest on POSITIVE, fresh,
# schema-valid empty observations — never on identity history.
# ==============================================================================

# Fresh DB: the singleton is created unknown (valid=0, empty_since NULL).
q_db() { # <db> <sql> -> first row, pipe-joined, NULL as empty
  python3 - "$1" "$2" <<'PYQ'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
rows = con.execute(sys.argv[2]).fetchall()
print("|".join("" if c is None else str(c) for c in rows[0]) if rows else "NOROW")
PYQ
}
FDB="$WORK/fresh_presence.sqlite3"
python3 "$FPS" --db "$FDB" playtime >/dev/null 2>&1
fstate="$(q_db "$FDB" 'SELECT valid, empty_since_ms, last_success_ms FROM presence_state;')"
assert_eq "$fstate" "0||" "a fresh DB has presence_state unknown: valid=0, empty_since NULL, no last success"

# Additive migration: a pre-Task-4 DB (identity/session rows, never sampled by
# the new code) gains the singleton WITHOUT touching playtime data, and begins
# UNKNOWN — historical identities alone must never initialize trusted emptiness.
MDB="$WORK/migration.sqlite3"
python3 "$FPS" --db "$MDB" playtime >/dev/null 2>&1
python3 - "$MDB" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
# Simulate a pre-Task-4 DB: drop the singleton this build just added, leave
# historical presence rows behind.
con.execute("DROP TABLE presence_state")
con.execute("INSERT INTO player_identity VALUES ('OLDUID',NULL,'Ancient',10,1000,2000,60000)")
con.execute("INSERT INTO player_sessions VALUES ('OLDUID',1000,2000,5)")
con.commit()
PY
before_identities="$(python3 - "$MDB" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM player_identity").fetchone()[0])
PY
)"
before_total="$(python3 - "$MDB" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("SELECT SUM(total_play_ms) FROM player_identity").fetchone()[0])
PY
)"
python3 "$FPS" --db "$MDB" playtime >/dev/null 2>&1
assert_eq "$(q_db "$MDB" 'SELECT COUNT(*) FROM presence_state;')" "1" "migration adds exactly one presence_state row"
assert_eq "$(q_db "$MDB" 'SELECT valid, empty_since_ms FROM presence_state;')" "0|" "a migrated DB with history begins unknown, not trusted-empty"
assert_eq "$(python3 - "$MDB" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM player_identity").fetchone()[0])
PY
)" "$before_identities" "migration keeps every identity row"
assert_eq "$(python3 - "$MDB" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("SELECT SUM(total_play_ms) FROM player_identity").fetchone()[0])
PY
)" "$before_total" "migration keeps all playtime"

# --- empty-evidence lifecycle through the real sampler ------------------------
# Seed a clean DB: one recent valid empty observation.
EDB="$WORK/empty_evidence.sqlite3"
printf '{"players": []}\n' > "$WORK/players.json"
rm -f "$WORK/players.fail"
env PALWORLD_API_BIN="$WORK/bin/palworld-api" \
  python3 "$FPS" --db "$EDB" sample >/dev/null 2>&1
state="$(q_db "$EDB" 'SELECT valid, empty_since_ms IS NOT NULL, last_success_ms IS NOT NULL FROM presence_state;')"
assert_eq "$state" "1|1|1" "a valid empty observation sets valid=1, starts empty_since, records last_success"
first_empty="$(q_db "$EDB" 'SELECT empty_since_ms FROM presence_state;')"

# A second empty within the 60 s freshness window PRESERVES empty_since.
sleep 0.2
env PALWORLD_API_BIN="$WORK/bin/palworld-api" python3 "$FPS" --db "$EDB" sample >/dev/null 2>&1
assert_eq "$(q_db "$EDB" 'SELECT empty_since_ms FROM presence_state;')" "$first_empty" \
  "consecutive fresh empties preserve empty_since (interval continues)"

# A stale gap (>60 s since last success) restarts the empty interval now.
STALE_MS=$(( $(date +%s) * 1000 - 120000 ))
python3 - "$EDB" "$STALE_MS" <<'PY'
import sqlite3, sys
stale = int(sys.argv[2])
con = sqlite3.connect(sys.argv[1])
con.execute("UPDATE presence_state SET last_success_ms=?, empty_since_ms=?", (stale, stale))
con.commit()
PY
printf '{"players": []}\n' > "$WORK/players.json"
env PALWORLD_API_BIN="$WORK/bin/palworld-api" python3 "$FPS" --db "$EDB" sample >/dev/null 2>&1
new_empty="$(q_db "$EDB" 'SELECT empty_since_ms FROM presence_state;')"
# window: (stale, stale + 125s) — 'now' is within ~1s of stale+120s; the bound
# only has to exclude the stale value itself and any far-future timestamp.
assert_eq "$(python3 -c "now=int('$new_empty'); print(now > $STALE_MS and now < $STALE_MS + 125000)")" "True" \
  "a stale gap restarts the empty interval at now (not the stale value, not the future)"

# A future last_success_ms is not trusted as fresh either.
FUTURE_MS=$(( $(date +%s) * 1000 + 3600000 ))
python3 - "$EDB" "$FUTURE_MS" <<'PY'
import sqlite3, sys
future = int(sys.argv[2])
con = sqlite3.connect(sys.argv[1])
con.execute("UPDATE presence_state SET last_success_ms=?, empty_since_ms=?", (future, future))
con.commit()
PY
printf '{"players": []}\n' > "$WORK/players.json"
env PALWORLD_API_BIN="$WORK/bin/palworld-api" python3 "$FPS" --db "$EDB" sample >/dev/null 2>&1
new_empty="$(q_db "$EDB" 'SELECT empty_since_ms FROM presence_state;')"
assert_eq "$(python3 -c "print(int('$new_empty') < $FUTURE_MS)")" "True" \
  "a future last_success_ms is not treated as fresh; the interval restarts at now"

# An occupied observation clears empty continuity (valid stays 1).
player_json "022E0173000000000000000000000000" "Snax" 80 > "$WORK/players.json"
env PALWORLD_API_BIN="$WORK/bin/palworld-api" python3 "$FPS" --db "$EDB" sample >/dev/null 2>&1
assert_eq "$(q_db "$EDB" 'SELECT valid, empty_since_ms IS NULL FROM presence_state;')" "1|1" \
  "an occupied observation clears empty_since while staying valid"

# A loading placeholder counts as OCCUPIED: the list is nonempty even though no
# identity is created — identity filtering must not classify it as empty.
printf '{"players": [{"name": "Grimnyr", "playerId": "None", "userId": "steam_x", "level": 1}]}\n' > "$WORK/players.json"
env PALWORLD_API_BIN="$WORK/bin/palworld-api" python3 "$FPS" --db "$EDB" sample >/dev/null 2>&1
assert_eq "$(q_db "$EDB" 'SELECT valid, empty_since_ms IS NULL FROM presence_state;')" "1|1" \
  "a loading-placeholder list is occupied, not an empty server"
ids_before="$(q_db "$EDB" 'SELECT COUNT(*) FROM player_identity;')"
assert_eq "$ids_before" "1" "the placeholder still created no identity"

# --- invalidation: every failure mode poisons the well ------------------------
run_invalidate_case() { # $1 = description
  local desc="$1"
  env PALWORLD_API_BIN="$WORK/bin/palworld-api" python3 "$FPS" --db "$EDB" sample >/dev/null 2>&1
  assert_eq "$(q_db "$EDB" 'SELECT valid, empty_since_ms FROM presence_state;')" "0|" \
    "$desc invalidates state and clears empty_since"
  # and the NEXT empty success must start a NEW interval, not resume the old one
  printf '{"players": []}\n' > "$WORK/players.json"
  rm -f "$WORK/players.fail"
  env PALWORLD_API_BIN="$WORK/bin/palworld-api" python3 "$FPS" --db "$EDB" sample >/dev/null 2>&1
  assert_eq "$(q_db "$EDB" 'SELECT valid, empty_since_ms IS NOT NULL FROM presence_state;')" "1|1" \
    "$desc: the next empty success starts a fresh interval"
}

# fetch_players must be STRICT: these are errors, never a silent [].
touch "$WORK/players.fail"; run_invalidate_case "A players fetch failure"
printf 'not json at all\n' > "$WORK/players.json"; run_invalidate_case "Malformed JSON"
printf '{"currentplayernum": 0}\n' > "$WORK/players.json"; run_invalidate_case "A missing players field"
printf '{"players": {"0": {}}}\n' > "$WORK/players.json"; run_invalidate_case "A non-list players field"
printf '{"players": ["Snax is online"]}\n' > "$WORK/players.json"; run_invalidate_case "A non-object list entry"
printf '{"players": [null]}\n' > "$WORK/players.json"; run_invalidate_case "A null list entry"

# A failed presence pass never crashes the sampler and never stops future
# observations: after all the failures above, a healthy empty tick works.
out="$(env PALWORLD_API_BIN="$WORK/bin/palworld-api" python3 "$FPS" --db "$EDB" sample 2>&1)"; rc=$?
assert_eq "$rc" "0" "the sampler survives the whole failure gauntlet"
assert_eq "$(q_db "$EDB" 'SELECT valid FROM presence_state;')" "1" "healthy observations resume after failures"

# Metrics failure must not poison presence evidence (independence preserved).
before_valid="$(q_db "$EDB" 'SELECT valid FROM presence_state;')"
touch "$WORK/metrics.fail"
out="$(env PALWORLD_API_BIN="$WORK/bin/palworld-api" python3 "$FPS" --db "$EDB" sample 2>&1)"; rc=$?
rm -f "$WORK/metrics.fail"
assert_eq "$rc" "0" "a metrics failure still exits 0 with presence evidence intact"
assert_eq "$(q_db "$EDB" 'SELECT valid FROM presence_state;')" "$before_valid" \
  "metrics failure is independent of presence validity"

# --- the observation sequence fence (module-level) -----------------------------
# An older reserved-but-slow observation must never overwrite a newer applied
# one, and a superseded occupied result must not retroactively extend playtime.
FENCE_DB="$WORK/fence.sqlite3"
out="$(PYTHONPATH="$DIR/../../lib" python3 - "$FENCE_DB" <<'PY' 2>&1
import sqlite3, sys
import palwarden_presence as presence

con = sqlite3.connect(sys.argv[1])
presence.create_schema(con)

s1 = presence.reserve_observation(con)
s2 = presence.reserve_observation(con)
assert s2 > s1, f"sequences must increase: {s1} then {s2}"

# s2 (occupied) applies first, out of order.
r2 = presence.apply_observation(con, s2, True,
                                [{"playerId": "A", "name": "Ada", "level": 1}],
                                at_ms=2_000_000)
assert r2["applied"], "newest sequence must apply"
assert r2["seen"] == 1, "occupied observation counts one player"

# s1 (empty, reserved earlier, delivered late) is superseded: refused.
r1 = presence.apply_observation(con, s1, True, [], at_ms=1_999_000)
assert not r1["applied"], "an older sequence must never overwrite a newer applied one"

row = con.execute("SELECT valid, empty_since_ms FROM presence_state").fetchone()
assert row[0] == 1 and row[1] is None, f"state must still reflect the occupied s2: {row}"

# The superseded occupied result must not extend playtime either.
r3 = presence.apply_observation(con, 1, True,
                                [{"playerId": "A", "name": "Ada", "level": 2}],
                                at_ms=3_000_000)
assert not r3["applied"], "sequence 1 is older than the applied counter; refuse"
ident = con.execute("SELECT last_seen_ms, total_play_ms FROM player_identity WHERE player_uid='A'").fetchone()
assert ident[0] == 2_000_000, f"superseded result must not move last_seen: {ident}"

# invalidate() poisons the well; a later reserved observation refreshes it.
presence.invalidate(con)
row = con.execute("SELECT valid, empty_since_ms FROM presence_state").fetchone()
assert row[0] == 0 and row[1] is None, f"invalidate must clear validity and empty_since: {row}"

s4 = presence.reserve_observation(con)
r4 = presence.apply_observation(con, s4, True, [], at_ms=2_600_000)
assert r4["applied"], "a fresh reservation applies after invalidation"
row = con.execute("SELECT valid, empty_since_ms, last_success_ms FROM presence_state").fetchone()
assert row == (1, 2_600_000, 2_600_000), f"fresh empty after invalidate starts the interval now: {row}"

# counters are exposed alongside the singleton
alloc, applied = con.execute("SELECT allocated_seq, applied_seq FROM presence_state").fetchone()
assert alloc >= applied and applied >= s2, f"counters must track: allocated={alloc} applied={applied}"
print("FENCE_OK")
PY
)"
assert_contains "$out" "FENCE_OK" "sequence fence: out-of-order apply refused, playtime not extended, invalidate/refresh coherent (output: $out)"

# ==============================================================================
# F3 (review follow-up): strict API JSON parsing, shared by sampler and watcher.
# The reviewer's exact reproductions: a top-level array and duplicate keys must
# be parse ERRORS — never a silently-empty player list.
# ==============================================================================
parse_out="$(PYTHONPATH="$DIR/../../lib" python3 - <<'PY'
import palwarden_presence as p
cases = [
    ('[{"players": []}]', False),                          # top-level array
    ('{"players": [{"playerId": "A"}], "players": []}', False),  # dup keys
    ('{"players": []} trailing', False),                   # trailing garbage
    ('{"players": []}', True),                             # legitimate empty
    ('{"players": {"a": 1}}', False),                      # wrong shape
    ('{"meta": {"a": 1, "a": 2}, "players": []}', False),  # nested dup keys
    ('not json', False),
    ('', False),
]
bad = []
for text, want_ok in cases:
    try:
        p.validate_players_payload(p.parse_api_json(text))
        ok = True
    except p.PresencePayloadError:
        ok = False
    except Exception as e:
        ok = "unexpected %r" % (e,)
    if ok is not want_ok:
        bad.append((text, want_ok, ok))
print("PARSE_OK" if not bad else "PARSE_BAD %s" % (bad,))
PY
)"
assert_contains "$parse_out" "PARSE_OK" "strict API JSON parser ($parse_out)"

# The sampler must treat the same payloads as FAILED passes: invalidate the
# idle evidence, never record an empty observation.
printf '[{"players": []}]\n' > "$WORK/players.json"
out="$(sample 2>&1)"; rc=$?
assert_eq "$rc" "0" "sample survives a top-level-array players payload (rc=$rc)"
assert_contains "$out" "presence pass failed" \
  "array payload is reported as a failed presence pass (got: $out)"
assert_eq "$(q 'SELECT valid FROM presence_state;')" "0" \
  "array payload invalidates presence evidence (never counts as empty)"

printf '{"players": [{"playerId": "A"}], "players": []}\n' > "$WORK/players.json"
out="$(sample 2>&1)"; rc=$?
assert_eq "$rc" "0" "sample survives duplicate-key players payload (rc=$rc)"
assert_contains "$out" "presence pass failed" \
  "duplicate keys are an error, not a last-wins empty list (got: $out)"
assert_eq "$(q 'SELECT valid FROM presence_state;')" "0" \
  "duplicate-key payload invalidates presence evidence"

# A legitimate empty object still records a valid empty observation.
printf '{"players": []}\n' > "$WORK/players.json"
out="$(sample 2>&1)"; rc=$?
assert_eq "$rc" "0" "sample handles the legitimate empty response (rc=$rc)"
assert_eq "$(q 'SELECT valid FROM presence_state;')" "1" \
  "legitimate empty response stays a valid observation"

assert_report
