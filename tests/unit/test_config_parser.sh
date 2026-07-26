#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Unit tests for palworld-config-parser: applies environment variables to
# PalWorldSettings.ini's OptionSettings=(...) line.
#
# Contract under test:
#   - env name -> INI key resolved against the keys present in the live file
#     (underscore/case-insensitive, optional `b` bool prefix), plus a small table
#     of genuine exceptions (MAX_PLAYERS -> ServerPlayerMaxNum, etc).
#   - only keys whose env var is set are touched; everything else is byte-preserved.
#   - the existing quoting style of each value is preserved.
#   - secrets are never echoed.
#   - unresolvable env vars warn but do not fail.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
PARSER="$DIR/../../bin/palworld-config-parser"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A realistic (abbreviated) PalWorldSettings.ini: single-line OptionSettings with
# a mix of quoted strings, ints, floats and bools — including the PascalCase
# quirks (PalAutoHPRegeneRate vs PalAutoHpRegeneRateInSleep) and a b-prefixed bool.
make_ini() {
  cat > "$1" <<'EOF'
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(ServerName="",ServerDescription="",AdminPassword="",ServerPassword="",Region="",PublicPort=8211,ServerPlayerMaxNum=32,RESTAPIEnabled=False,RESTAPIPort=8212,RCONEnabled=False,ExpRate=1.000000,bIsPvP=False,bEnableInvaderEnemy=True,bIsUseBackupSaveData=True,ChatPostLimitPerMinute=30,PalAutoHPRegeneRate=1.000000,PalAutoHpRegeneRateInSleep=1.000000,DropItemMaxNum_UNKO=100,bActiveUNKO=False)
EOF
}

# value_of <file> <IniKey>  -> prints the raw value text as it appears
value_of() { grep -oE "(^|[(,])$2=[^,)]*" "$1" | sed "s/^[(,]//" | sed "s/^$2=//" | head -1; }

run_parser() { local cfg="$1"; shift; env "$@" python3 "$PARSER" --config "$cfg"; }

# --- plain string, quoting style preserved ---------------------------------
cfg="$WORK/a.ini"; make_ini "$cfg"
run_parser "$cfg" SERVER_NAME="Yggdrasil Palworld" >/dev/null 2>&1
assert_eq "$(value_of "$cfg" ServerName)" '"Yggdrasil Palworld"' "string value written quoted"

# --- exception mapping + unquoted int --------------------------------------
cfg="$WORK/b.ini"; make_ini "$cfg"
run_parser "$cfg" MAX_PLAYERS=24 SERVER_PORT=8888 SERVER_REGION="us-east" >/dev/null 2>&1
assert_eq "$(value_of "$cfg" ServerPlayerMaxNum)" "24"        "MAX_PLAYERS -> ServerPlayerMaxNum"
assert_eq "$(value_of "$cfg" PublicPort)"         "8888"      "SERVER_PORT -> PublicPort"
assert_eq "$(value_of "$cfg" Region)"             '"us-east"' "SERVER_REGION -> Region"

# --- bools (with and without the b prefix) and REST/RCON acronyms -----------
cfg="$WORK/c.ini"; make_ini "$cfg"
run_parser "$cfg" REST_API_ENABLED=True IS_PVP=True RCON_ENABLE=True ENABLE_ENEMY=False \
                  USE_BACKUP_SAVE_DATA=False ACTIVE_UNKO=True >/dev/null 2>&1
assert_eq "$(value_of "$cfg" RESTAPIEnabled)"       "True"  "REST_API_ENABLED -> RESTAPIEnabled"
assert_eq "$(value_of "$cfg" bIsPvP)"               "True"  "IS_PVP -> bIsPvP"
assert_eq "$(value_of "$cfg" RCONEnabled)"          "True"  "RCON_ENABLE -> RCONEnabled"
assert_eq "$(value_of "$cfg" bEnableInvaderEnemy)"  "False" "ENABLE_ENEMY -> bEnableInvaderEnemy"
assert_eq "$(value_of "$cfg" bIsUseBackupSaveData)" "False" "USE_BACKUP_SAVE_DATA -> bIsUseBackupSaveData"
assert_eq "$(value_of "$cfg" bActiveUNKO)"          "True"  "ACTIVE_UNKO -> bActiveUNKO"

# --- PascalCase quirks resolve to the right distinct keys ------------------
cfg="$WORK/d.ini"; make_ini "$cfg"
run_parser "$cfg" PAL_AUTO_HP_REGENE_RATE=2.5 PAL_AUTO_HP_REGENE_RATE_IN_SLEEP=3.5 \
                  CHAT_POST_LIMIT=60 DROP_ITEM_MAX_NUM_UNKO=50 >/dev/null 2>&1
assert_eq "$(value_of "$cfg" PalAutoHPRegeneRate)"        "2.5" "HP-caps key resolved"
assert_eq "$(value_of "$cfg" PalAutoHpRegeneRateInSleep)" "3.5" "Hp-mixed-case key resolved"
assert_eq "$(value_of "$cfg" ChatPostLimitPerMinute)"     "60"  "CHAT_POST_LIMIT -> ChatPostLimitPerMinute"
assert_eq "$(value_of "$cfg" DropItemMaxNum_UNKO)"        "50"  "underscored key resolved"

# --- quotes/backslashes in a value are escaped ------------------------------
cfg="$WORK/e.ini"; make_ini "$cfg"
run_parser "$cfg" SERVER_DESCRIPTION='He said "hi" \ bye' >/dev/null 2>&1
assert_eq "$(value_of "$cfg" ServerDescription)" '"He said \"hi\" \\ bye"' "quotes/backslashes escaped"
# the escaping must not corrupt the surrounding keys
assert_eq "$(value_of "$cfg" PublicPort)" "8211" "neighbouring key intact after escaping"

# --- unset env vars leave everything else untouched (byte-identical) --------
cfg="$WORK/f.ini"; make_ini "$cfg"; cp "$cfg" "$WORK/f.orig"
run_parser "$cfg" SERVER_NAME="Only This" >/dev/null 2>&1
changed="$(diff <(tr ',' '\n' < "$WORK/f.orig") <(tr ',' '\n' < "$cfg") | grep -c '^[<>]')"
assert_eq "$changed" "2" "exactly one key changed (one - / one +)"

# --- empty value clears a setting ------------------------------------------
cfg="$WORK/g.ini"; make_ini "$cfg"
run_parser "$cfg" SERVER_NAME="keep" >/dev/null 2>&1
run_parser "$cfg" SERVER_NAME="" >/dev/null 2>&1
assert_eq "$(value_of "$cfg" ServerName)" '""' "empty value clears the setting"

# --- secrets are applied but never echoed ----------------------------------
cfg="$WORK/h.ini"; make_ini "$cfg"
out="$(run_parser "$cfg" ADMIN_PASSWORD="sup3rSecret" SERVER_PASSWORD="joinPw" 2>&1)"
assert_eq "$(value_of "$cfg" AdminPassword)"  '"sup3rSecret"' "admin password applied"
assert_eq "$(value_of "$cfg" ServerPassword)" '"joinPw"'      "server password applied"
assert_not_contains "$out" "sup3rSecret" "admin password not echoed"
assert_not_contains "$out" "joinPw"      "server password not echoed"

# --- ambient environment is ignored, not misapplied -------------------------
# Process-env mode must silently ignore anything that isn't a real setting
# (PATH, HOME, our own REST_API_HOST, ...) rather than warn about it.
cfg="$WORK/i.ini"; make_ini "$cfg"
out="$(run_parser "$cfg" REST_API_HOST=1.2.3.4 NOT_A_REAL_PALWORLD_SETTING=1 2>&1)"; rc=$?
assert_eq "$rc" "0" "ambient env does not fail the run"
assert_not_contains "$out" "NOT_A_REAL_PALWORLD_SETTING" "ambient env not warned about"

# --- but a typo in an explicit env file IS reported -------------------------
# With --env-file every key is intentional, so an unresolvable one is a mistake.
cfg="$WORK/i2.ini"; make_ini "$cfg"
printf 'SERVER_NAME="ok"\nNOT_A_REAL_PALWORLD_SETTING=1\n' > "$WORK/typo.env"
out="$(python3 "$PARSER" --config "$cfg" --env-file "$WORK/typo.env" 2>&1)"; rc=$?
assert_eq "$rc" "0" "typo in env file does not fail the run"
assert_contains "$out" "NOT_A_REAL_PALWORLD_SETTING" "typo in env file is reported"
assert_eq "$(value_of "$cfg" ServerName)" '"ok"' "valid keys still applied alongside a typo"

# --- palwarden's own keys in settings.env are not "typos" -------------------
# render-config writes REST_API_HOST (ours, not a game setting) into the same
# file; it must be ignored silently rather than warned about.
cfg="$WORK/i5.ini"; make_ini "$cfg"
printf 'REST_API_HOST=127.0.0.1\nPALWARDEN_MODE=embedded\nSERVER_NAME="ok"\n' > "$WORK/ours.env"
out="$(python3 "$PARSER" --config "$cfg" --env-file "$WORK/ours.env" 2>&1)"
assert_not_contains "$out" "REST_API_HOST"  "palwarden's REST_API_HOST not warned about"
assert_not_contains "$out" "PALWARDEN_MODE" "palwarden's own vars not warned about"
assert_eq "$(value_of "$cfg" ServerName)" '"ok"' "real settings still applied"

# --- unquoted (numeric/bool) keys reject junk instead of corrupting config --
cfg="$WORK/i3.ini"; make_ini "$cfg"
out="$(run_parser "$cfg" MAX_PLAYERS="not-a-number" 2>&1)"
assert_eq "$(value_of "$cfg" ServerPlayerMaxNum)" "32" "junk numeric value rejected, original kept"
assert_contains "$out" "ServerPlayerMaxNum" "rejected value is reported"

# --- lenient boolean casing is normalised for the game ---------------------
cfg="$WORK/i4.ini"; make_ini "$cfg"
run_parser "$cfg" REST_API_ENABLED=true IS_PVP=false >/dev/null 2>&1
assert_eq "$(value_of "$cfg" RESTAPIEnabled)" "True"  "lowercase true -> True"
assert_eq "$(value_of "$cfg" bIsPvP)"         "False" "lowercase false -> False"

# --- idempotent -----------------------------------------------------------
cfg="$WORK/j.ini"; make_ini "$cfg"
run_parser "$cfg" SERVER_NAME="Twice" MAX_PLAYERS=8 >/dev/null 2>&1; cp "$cfg" "$WORK/j.first"
run_parser "$cfg" SERVER_NAME="Twice" MAX_PLAYERS=8 >/dev/null 2>&1
assert_rc 0 cmp -s "$WORK/j.first" "$cfg"

# --- header/other lines preserved -----------------------------------------
assert_file_contains "$cfg" "[/Script/Pal.PalGameWorldSettings]" "section header preserved"

# --- missing config file fails clearly ------------------------------------
out="$(run_parser "$WORK/nope.ini" SERVER_NAME=x 2>&1)"; rc=$?
assert_ne "$rc" "0" "missing config file exits non-zero"
assert_contains "$out" "nope.ini" "error names the missing file"

# --- dry-run does not write ------------------------------------------------
cfg="$WORK/k.ini"; make_ini "$cfg"; cp "$cfg" "$WORK/k.orig"
env SERVER_NAME="nope" python3 "$PARSER" --config "$cfg" --dry-run >/dev/null 2>&1
assert_rc 0 cmp -s "$WORK/k.orig" "$cfg"

# ===========================================================================
# Against a realistic full-key config (all 90 canonical Palworld settings)
# ===========================================================================
FULL="$DIR/../fixtures/PalWorldSettings.full.ini"

# --- unquoted enum values (Difficulty=None, DeathPenalty=All, ...) ----------
cfg="$WORK/full1.ini"; cp "$FULL" "$cfg"
run_parser "$cfg" DIFFICULTY=Normal DEATH_PENALTY=None LOG_FORMAT_TYPE=Json >/dev/null 2>&1
assert_eq "$(value_of "$cfg" Difficulty)"     "Normal" "enum Difficulty set unquoted"
assert_eq "$(value_of "$cfg" DeathPenalty)"   "None"   "enum DeathPenalty set unquoted"
assert_eq "$(value_of "$cfg" LogFormatType)"  "Json"   "enum LogFormatType set unquoted"

# --- a value that could corrupt the structure is rejected ------------------
cfg="$WORK/full2.ini"; cp "$FULL" "$cfg"
out="$(run_parser "$cfg" DIFFICULTY="Normal,bIsPvP=True" 2>&1)"
assert_eq "$(value_of "$cfg" Difficulty)" "None" "value with a comma rejected, original kept"
assert_contains "$out" "Difficulty" "structure-breaking value is reported"

# --- the paren-tuple key is parsed without corruption ----------------------
cfg="$WORK/full3.ini"; cp "$FULL" "$cfg"
run_parser "$cfg" SERVER_NAME="tuple safe" >/dev/null 2>&1
assert_file_contains "$cfg" "CrossplayPlatforms=(Steam,Xbox,PS5,Mac)" "paren tuple preserved intact"
assert_eq "$(value_of "$cfg" ServerName)" '"tuple safe"' "edit alongside a paren tuple works"

# --- SYSTEMATIC: every env var we document must resolve to a real INI key ---
# Guards the whole documented surface against mapping gaps. Values are dummies;
# we only assert on resolution failures, not type warnings.
cfg="$WORK/full4.ini"; cp "$FULL" "$cfg"
envfile="$WORK/all.env"
: > "$envfile"
grep -oE '^#?[A-Z_]+=' "$DIR/../../config/settings.env.example" | tr -d '#=' | sort -u |
  while IFS= read -r name; do printf '%s=1\n' "$name" >> "$envfile"; done
documented="$(wc -l < "$envfile")"
out="$(python3 "$PARSER" --config "$cfg" --env-file "$envfile" 2>&1)"
# SERVER_IP is a launch-arg concept, not an OptionSettings key: expected to be unresolved.
unresolved="$(printf '%s\n' "$out" | grep 'no matching Palworld setting' | grep -cv 'SERVER_IP' || true)"
assert_eq "$unresolved" "0" "all $documented documented env vars resolve to real INI keys"

assert_report
