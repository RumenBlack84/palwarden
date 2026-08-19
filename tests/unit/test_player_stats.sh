#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Player stats board (spec: docs/superpowers/specs/
# 2026-08-18-player-stats-board-design.md). The GVAS reader parses per-player
# .sav files with per-field degradation: an unknown or corrupt property is
# recorded and skipped, its siblings survive, and only genuinely torn
# containers are errors. Fixtures are PlZ (stdlib zlib) — the game accepts
# both magics, so no Oodle codec is needed to test the real parse path.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
REPO="$DIR/../.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PYTHONPATH="$REPO/lib:$REPO/tests/lib${PYTHONPATH:+:$PYTHONPATH}"

# py() runs an inline python check that prints assert_eq-able output.
py() { python3 - "$@" 2>&1; }

echo "-- reader: fixture round-trip --"
out="$(py <<'PY'
import palwarden_gvas as g
import gvas_fixture as fx

sav = fx.player_sav(
    fx.concat(
        fx.map_prop("PalCaptureCount", "NameProperty", "IntProperty",
                    [("SheepBall", 12), ("PinkCat", 3)]),
        fx.map_prop("TowerBossDefeatFlag", "NameProperty", "BoolProperty",
                    [("Tower1", True), ("Tower2", False)]),
        fx.int_prop("TotalLoginTimes", 42),
        fx.str_prop("LastTransferAccountName", "bryli"),
    )
)
props, errors = g.parse_sav(sav)
rec = props["SaveData"]["RecordData"]
print("captures", rec["PalCaptureCount"]["SheepBall"], rec["PalCaptureCount"]["PinkCat"])
print("tower", rec["TowerBossDefeatFlag"]["Tower1"], rec["TowerBossDefeatFlag"]["Tower2"])
print("logins", rec["TotalLoginTimes"])
print("name", rec["LastTransferAccountName"])
print("errors", len(errors))
PY
)"
assert_contains "$out" "captures 12 3" "map name->int round-trips"
assert_contains "$out" "tower True False" "map name->bool round-trips"
assert_contains "$out" "logins 42" "int property round-trips"
assert_contains "$out" "name bryli" "str property round-trips"
assert_contains "$out" "errors 0" "clean fixture parses without errors"

echo "-- reader: torn containers are typed errors --"
out="$(py <<'PY'
import palwarden_gvas as g
import gvas_fixture as fx

sav = fx.player_sav()

def expect(name, data):
    try:
        g.parse_sav(data)
        print(name, "NO-ERROR")
    except g.SavCorrupt:
        print(name, "corrupt")
    except Exception as e:
        print(name, "WRONG-TYPE", type(e).__name__)

expect("truncated", sav[:20])
expect("tiny", sav[:5])
gvas = fx.build_gvas()
expect("badmagic", fx.wrap_sav(gvas, magic=b"XXX"))
expect("ulen-lie", fx.wrap_sav(gvas, ulen=len(gvas) + 999))
expect("clen-lie", fx.wrap_sav(gvas, clen=4))
PY
)"
assert_contains "$out" "truncated corrupt" "truncated file -> SavCorrupt"
assert_contains "$out" "tiny corrupt" "sub-header file -> SavCorrupt"
assert_contains "$out" "badmagic corrupt" "unknown magic -> SavCorrupt"
assert_contains "$out" "ulen-lie corrupt" "lying uncompressed_len -> SavCorrupt"
assert_contains "$out" "clen-lie corrupt" "lying compressed_len -> SavCorrupt"

echo "-- reader: unknown property type degrades, siblings survive --"
out="$(py <<'PY'
import struct
import palwarden_gvas as g
import gvas_fixture as fx

sav = fx.player_sav(
    fx.concat(
        fx.map_prop("PalCaptureCount", "NameProperty", "IntProperty", [("SheepBall", 12)]),
        # A property type this reader has never heard of, following the common
        # scalar convention (optional-guid flag byte, then `size` payload bytes).
        fx.raw_prop("FutureThing", "FrobProperty", 4, b"\x00" + struct.pack("<i", 7)),
        fx.map_prop("PaldeckUnlockFlag", "NameProperty", "BoolProperty", [("SheepBall", True)]),
    )
)
props, errors = g.parse_sav(sav)
rec = props["SaveData"]["RecordData"]
print("before", rec["PalCaptureCount"]["SheepBall"])
print("after", rec["PaldeckUnlockFlag"]["SheepBall"])
print("skipped", "FutureThing" not in rec)
print("recorded", any("FutureThing" in e and "FrobProperty" in e for e in errors))
PY
)"
assert_contains "$out" "before 12" "sibling before the unknown property parses"
assert_contains "$out" "after True" "sibling after the unknown property parses"
assert_contains "$out" "skipped True" "unknown property is absent from the result"
assert_contains "$out" "recorded True" "unknown property is recorded in errors"

echo "-- reader: corrupt container payload degrades, siblings survive --"
out="$(py <<'PY'
import palwarden_gvas as g
import gvas_fixture as fx

# A MapProperty whose body lies about its element count: the inner parse
# fails, but the property's extent is known, so the reader reseeks and the
# siblings are untouched.
garbage_body = b"\x00\x00\x00\x00" + b"\x05\x00\x00\x00" + b"\xff\xff"
payload = fx.fstring("NameProperty") + fx.fstring("IntProperty") + b"\x00" + garbage_body
sav = fx.player_sav(
    fx.concat(
        fx.raw_prop("BrokenLedger", "MapProperty", len(garbage_body), payload),
        fx.map_prop("PalCaptureCount", "NameProperty", "IntProperty", [("SheepBall", 12)]),
    )
)
props, errors = g.parse_sav(sav)
rec = props["SaveData"]["RecordData"]
print("sibling", rec["PalCaptureCount"]["SheepBall"])
print("skipped", "BrokenLedger" not in rec)
print("recorded", any("BrokenLedger" in e for e in errors))
PY
)"
assert_contains "$out" "sibling 12" "sibling of the corrupt map parses"
assert_contains "$out" "skipped True" "corrupt map is absent from the result"
assert_contains "$out" "recorded True" "corrupt map is recorded in errors"

echo "-- reader: unskippable unknown degrades its container, not the file --"
out="$(py <<'PY'
import palwarden_gvas as g
import gvas_fixture as fx

# An unknown type whose payload does NOT follow the scalar convention: the
# skip heuristic must refuse, and the enclosing RecordData struct degrades —
# while the SaveData-level sibling is untouched.
sav = fx.player_sav(
    fx.raw_prop("Weird", "ZorkProperty", 4, b"\xff" * 11),
    extra_savedata=fx.int_prop("OtherLevel", 7),
)
props, errors = g.parse_sav(sav)
print("sibling", props["SaveData"]["OtherLevel"])
print("degraded", "RecordData" not in props["SaveData"])
print("recorded", any("RecordData" in e for e in errors))
PY
)"
assert_contains "$out" "sibling 7" "SaveData-level sibling survives"
assert_contains "$out" "degraded True" "the containing struct is dropped, not the file"
assert_contains "$out" "recorded True" "the degradation is recorded"

echo "-- reader: PlM without pyooz is ParserUnavailable, not a crash --"
mkdir -p "$WORK/shadow"
printf 'raise ImportError("ooz forced absent by test")\n' > "$WORK/shadow/ooz.py"
out="$(PYTHONPATH="$WORK/shadow:$PYTHONPATH" py <<'PY'
import palwarden_gvas as g
import gvas_fixture as fx

sav = fx.player_sav()
plm = fx.wrap_sav(fx.build_gvas(), magic=b"PlM")
try:
    g.parse_sav(plm)
    print("plm NO-ERROR")
except g.ParserUnavailable as e:
    print("plm unavailable")
except Exception as e:
    print("plm WRONG-TYPE", type(e).__name__)
# And the PlZ path must not care that pyooz is broken.
props, errors = g.parse_sav(sav)
print("plz ok", len(errors))
PY
)"
assert_contains "$out" "plm unavailable" "PlM without pyooz -> ParserUnavailable"
assert_contains "$out" "plz ok 0" "PlZ path never imports pyooz"

# ---------------------------------------------------------------------------
# The tool: sbin/palworld-player-stats (refresh / show / dump)
# ---------------------------------------------------------------------------
TOOL="$REPO/sbin/palworld-player-stats"
UID_A="AAAA0173000000000000000000000001"
UID_B="BBBB0173000000000000000000000002"
UID_C="CCCC0173000000000000000000000003"
WORLD="C3D76E3FBB68428897B1FEB0D2AD2016"
SAVED="$WORK/install/Pal/Saved"
PLAYERS="$SAVED/SaveGames/0/$WORLD/Players"
SNAP="$WORK/player-stats.json"
mkdir -p "$PLAYERS"

# Fixture writer: builds a player .sav with a capture map + tower flags.
write_player() { # path captures_a captures_b tower1
  python3 - "$@" <<'PY'
import sys
import gvas_fixture as fx

path, a, b, tower1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1"
data = fx.player_sav(
    fx.concat(
        fx.map_prop("PalCaptureCount", "NameProperty", "IntProperty",
                    [("SheepBall", a), ("PinkCat", b)]),
        fx.map_prop("TowerBossDefeatFlag", "NameProperty", "BoolProperty",
                    [("Tower1", tower1), ("Tower2", False)]),
        fx.map_prop("PaldeckUnlockFlag", "NameProperty", "BoolProperty",
                    [("SheepBall", True), ("PinkCat", True)]),
        fx.map_prop("CraftItemCount", "NameProperty", "IntProperty",
                    [("Pickaxe_Tier_00", 2), ("Sword", 1)]),
        fx.int_prop("NormalDungeonClearCount", 4),
        fx.int_prop("FixedDungeonClearCount", 2),
        fx.int_prop("CampConqueredCount", 5),
    )
)
open(path, "wb").write(data)
PY
}

refresh() {
  env PALWORLD_SAVED_DIR="$SAVED" PALWARDEN_PLAYER_STATS_FILE="$SNAP" \
      python3 "$TOOL" refresh "$@"
}
# snap_q <python-expr over `s` (the loaded snapshot)>
snap_q() { python3 - "$SNAP" "$1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))
PY
}

echo "-- tool: refresh writes the snapshot schema --"
write_player "$PLAYERS/$UID_A.sav" 12 3 1
write_player "$PLAYERS/$UID_B.sav" 1 0 0
assert_rc 0 refresh
assert_eq "$(snap_q 's["schema_version"]')" "1" "schema version"
assert_eq "$(snap_q 's["status"]')" "ok" "status ok"
assert_contains "$(snap_q 's["world_dir"]')" "$WORLD" "world dir recorded"
assert_eq "$(snap_q 'sorted(s["players"])')" "['$UID_A', '$UID_B']" "both players present"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["captures_total"]')" "15" "captures_total"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["species_captured_distinct"]')" "2" "species distinct"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["towers_cleared"]')" "1" "towers cleared counts true flags only"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["paldeck_unlocked"]')" "2" "paldeck unlocked"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["items_crafted_total"]')" "3" "crafts summed"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["items_crafted_distinct"]')" "2" "distinct crafts counted"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["dungeons_cleared"]')" "6" "dungeon ints accumulate (normal + fixed)"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["camps_conquered"]')" "5" "camp scalar aggregated"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["parse_status"]')" "ok" "parse status ok"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["records"]["PalCaptureCount"]["SheepBall"]')" "12" "records ledger retained for diffing"
assert_eq "$(snap_q 'isinstance(s["players"]["'$UID_A'"]["source_mtime"], int)')" "True" "source mtime recorded"
assert_path_absent "$SNAP.tmp" "no temp file left behind"

echo "-- tool: bad filenames are skipped --"
write_player "$PLAYERS/evil.sav" 1 1 0
write_player "$PLAYERS/aaaa0173000000000000000000000001.sav" 1 1 0
write_player "$PLAYERS/AAAA017300000000000000000000000.sav" 1 1 0  # 31 hex
write_player "$PLAYERS/${UID_A}_dps.sav" 1 1 0  # pal-storage sidecar
err="$(refresh 2>&1 >/dev/null)"
assert_eq "$(snap_q 'sorted(s["players"])')" "['$UID_A', '$UID_B']" "only 32-uppercase-hex uids admitted"
assert_contains "$err" "evil.sav" "odd file names are logged"
assert_not_contains "$err" "_dps.sav" "the known _dps sidecar is skipped silently"
rm -f "$PLAYERS/evil.sav" "$PLAYERS/aaaa0173000000000000000000000001.sav" \
      "$PLAYERS/AAAA017300000000000000000000000.sav" "$PLAYERS/${UID_A}_dps.sav"

echo "-- tool: mtime carry-forward --"
mt="$(python3 -c "import os,sys; st=os.stat(sys.argv[1]); print(st.st_mtime_ns)" "$PLAYERS/$UID_A.sav")"
write_player "$PLAYERS/$UID_A.sav" 99 99 0
python3 -c "import os,sys; ns=int(sys.argv[2]); os.utime(sys.argv[1], ns=(ns, ns))" "$PLAYERS/$UID_A.sav" "$mt"
assert_rc 0 refresh
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["captures_total"]')" "15" "unchanged mtime is carried forward, not re-parsed"
touch "$PLAYERS/$UID_A.sav"
assert_rc 0 refresh
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["captures_total"]')" "198" "changed mtime is re-parsed"

echo "-- tool: torn file degrades to unreadable, previous stats retained --"
python3 - "$PLAYERS/$UID_C.sav" <<'PY'
import sys
import gvas_fixture as fx
gvas = fx.build_gvas()
open(sys.argv[1], "wb").write(fx.wrap_sav(gvas, ulen=len(gvas) + 999))
PY
assert_rc 0 refresh
assert_eq "$(snap_q 's["players"]["'$UID_C'"]["parse_status"]')" "unreadable" "torn file -> unreadable"
assert_eq "$(snap_q 'len(s["players"]["'$UID_C'"]["parse_errors"]) > 0')" "True" "torn file records why"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["parse_status"]')" "ok" "siblings unaffected by a torn file"
# Now the previously-good player A goes torn: its stats must be retained.
python3 - "$PLAYERS/$UID_A.sav" <<'PY'
import sys
import gvas_fixture as fx
gvas = fx.build_gvas()
open(sys.argv[1], "wb").write(fx.wrap_sav(gvas, ulen=len(gvas) + 999))
PY
assert_rc 0 refresh
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["parse_status"]')" "unreadable" "went-torn file -> unreadable"
assert_eq "$(snap_q 's["players"]["'$UID_A'"]["stats"]["captures_total"]')" "198" "previous good stats retained through a torn pass"
rm -f "$PLAYERS/$UID_C.sav"
write_player "$PLAYERS/$UID_A.sav" 99 99 0

echo "-- tool: vanished players are pruned --"
rm -f "$PLAYERS/$UID_B.sav"
assert_rc 0 refresh
assert_eq "$(snap_q 'sorted(s["players"])')" "['$UID_A']" "deleted .sav pruned from the snapshot"

echo "-- tool: degraded world-dir states, still exit 0 --"
EMPTY="$WORK/empty/Pal/Saved"
mkdir -p "$EMPTY/SaveGames/0"
assert_rc 0 env PALWORLD_SAVED_DIR="$EMPTY" PALWARDEN_PLAYER_STATS_FILE="$WORK/empty.json" python3 "$TOOL" refresh
assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['status'])" "$WORK/empty.json")" "no-world-dir" "zero world dirs"
mkdir -p "$SAVED/SaveGames/0/AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD"
assert_rc 0 refresh
assert_eq "$(snap_q 's["status"]')" "multiple-world-dirs" "two world dirs -> degraded"
assert_contains "$(snap_q 's["degraded_reason"]')" "$WORLD" "degraded reason names the world dirs"
rmdir "$SAVED/SaveGames/0/AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD"

echo "-- tool: a set-but-empty PALWORLD_SAVED_DIR is honored --"
assert_rc 0 env PALWORLD_SAVED_DIR="" PALWORLD_INSTALL_DIR="$WORK/install" \
  PALWARDEN_PLAYER_STATS_FILE="$WORK/emptyvar.json" python3 "$TOOL" refresh
assert_eq "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['status'])" "$WORK/emptyvar.json")" "no-world-dir" "empty override does not fall through to PALWORLD_INSTALL_DIR"

echo "-- tool: PlM without pyooz degrades the snapshot, not the exit code --"
python3 - "$PLAYERS/$UID_B.sav" <<'PY'
import sys
import gvas_fixture as fx
open(sys.argv[1], "wb").write(fx.wrap_sav(fx.build_gvas(), magic=b"PlM"))
PY
assert_rc 0 env PYTHONPATH="$WORK/shadow:$PYTHONPATH" PALWORLD_SAVED_DIR="$SAVED" \
  PALWARDEN_PLAYER_STATS_FILE="$SNAP" python3 "$TOOL" refresh
assert_eq "$(snap_q 's["status"]')" "parser-unavailable" "PlM without pyooz -> parser-unavailable"
assert_contains "$(snap_q 's["degraded_reason"]')" "pyooz" "degraded reason carries the install hint"
rm -f "$PLAYERS/$UID_B.sav"

echo "-- tool: show reads back without the codec --"
refresh >/dev/null
printf 'raise Exception("show must not import the codec")\n' > "$WORK/shadow/ooz.py"
out="$(env PYTHONPATH="$WORK/shadow:$PYTHONPATH" PALWARDEN_PLAYER_STATS_FILE="$SNAP" python3 "$TOOL" show --json)"
assert_contains "$out" "\"schema_version\": 1" "show --json echoes the snapshot"
assert_contains "$out" "$UID_A" "show --json includes the players"
out="$(env PALWARDEN_PLAYER_STATS_FILE="$WORK/missing.json" python3 "$TOOL" show --json)"
assert_contains "$out" "no-snapshot" "missing snapshot is a degraded state, not an error"
printf 'raise ImportError("ooz forced absent by test")\n' > "$WORK/shadow/ooz.py"

echo "-- tool: dump lists RecordData keys --"
out="$(python3 "$TOOL" dump "$PLAYERS/$UID_A.sav")"
assert_contains "$out" "PalCaptureCount" "dump names the ledgers"
assert_contains "$out" "TowerBossDefeatFlag" "dump names the flag maps"

echo "-- deployment: bare-metal units --"
SVC="$REPO/systemd/palworld-player-stats.service"
TMR="$REPO/systemd/palworld-player-stats.timer"
assert_file_exists "$SVC" "refresh service unit exists"
assert_file_exists "$TMR" "refresh timer unit exists"
assert_file_contains "$SVC" "Type=oneshot" "service is a oneshot"
assert_file_contains "$SVC" "flock -n /run/palworld-player-stats/lock" "service is flocked"
assert_file_contains "$SVC" "RuntimeDirectory=palworld-player-stats" \
  "the unprivileged user gets a writable lock dir"
assert_file_contains "$SVC" "User=palworld" "refresh runs unprivileged"
assert_file_contains "$SVC" "palworld-player-stats refresh" "service runs the refresh"
assert_file_contains "$TMR" "OnUnitActiveSec=60" "timer undercuts any plausible autosave interval"
assert_file_contains "$REPO/packaging/scripts/preremove.sh" "palworld-player-stats.timer" \
  "package removal disables the timer"

assert_report
