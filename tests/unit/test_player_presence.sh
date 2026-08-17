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

assert_report
