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
printf 'raise ImportError("pyooz forced absent by test")\n' > "$WORK/shadow/pyooz.py"
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

assert_report
