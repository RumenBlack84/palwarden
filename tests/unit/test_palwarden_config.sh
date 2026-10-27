#!/usr/bin/env bash
# Harness idioms this file uses deliberately (pinned by ./tests/lint.sh):
#  - SC2015: `cmd && pass ... || fail ...` assertion chains
#  - SC2016: single-quoted python bodies where $VARS expand in the INNER shell
# shellcheck disable=SC2015,SC2016
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Shared configuration contract for idle-shutdown / knock-wake (spec §7.1,
# plan Task 1). Pins lib/palwarden_ops.py before any consumer exists:
# defaults, file -> env -> default resolution, strict validation, the
# canonical fixed-key JSON-quoted data file (never shell), atomic writer
# safety, partial merge, and the redacted public view.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"

LIB="$DIR/../../lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OPS="$WORK/ops.env"
export PALWARDEN_OPS_FILE="$OPS"

CURGROUP="$(id -gn)"
# The writer's default group follows the repo-wide PALWORLD_GROUP convention;
# point it at the test account so seed/write need no explicit group.
export PALWORLD_GROUP="$CURGROUP"

# run_py "KEY=VALUE" ... '<python code>'
#
# One fresh interpreter per call. The five feature config vars are always
# cleared first, so only explicit assignments reach the module. PALWARDEN_OPS_FILE
# is intentionally preserved (it is the module's default path).
run_py() {
    local code="${*: -1}"
    local n=$(( $# - 1 ))
    local -a envs=()
    if [ "$n" -gt 0 ]; then envs=("${@:1:$n}"); fi
    PYTHONPATH="$LIB" env -u IDLE_TIMEOUT -u IDLE_CHECK_INTERVAL -u KNOCK_ENABLED \
        -u KNOCK_COOLDOWN -u KNOCK_TOKEN \
        ${envs[@]+"${envs[@]}"} \
        python3 -c "$code"
}

expect_ok() {
    local name="$1"; shift
    local out
    if out="$(run_py "$@" 2>&1)"; then
        pass "$name"
    else
        fail "$name (output: $out)"
    fi
}

expect_err() {
    local name="$1"; shift
    local out
    if out="$(run_py "$@" 2>&1 >/dev/null)"; then
        fail "$name: expected a ConfigError"
    else
        pass "$name"
    fi
}

# ---------------------------------------------------------------------------
# A. Built-in defaults (no file, no env): exactly the five keys, typed.
# ---------------------------------------------------------------------------
expect_ok "defaults: all five keys resolve with built-in values, typed" \
'
import palwarden_ops as ops
c = ops.resolve()
assert c == {"IDLE_TIMEOUT": 0, "IDLE_CHECK_INTERVAL": 60, "KNOCK_ENABLED": True,
             "KNOCK_COOLDOWN": 600, "KNOCK_TOKEN": ""}, c
assert isinstance(c["IDLE_TIMEOUT"], int) and not isinstance(c["IDLE_TIMEOUT"], bool)
assert isinstance(c["KNOCK_ENABLED"], bool)
print("ok")
'

# ---------------------------------------------------------------------------
# B. Resolution order: data file beats env beats default.
# ---------------------------------------------------------------------------
expect_ok "file: seed creates the canonical file" \
'
import palwarden_ops as ops
cfg = dict(ops.DEFAULTS)
cfg["IDLE_TIMEOUT"] = 120
cfg["IDLE_CHECK_INTERVAL"] = 90
cfg["KNOCK_ENABLED"] = False
cfg["KNOCK_COOLDOWN"] = 1200
cfg["KNOCK_TOKEN"] = "synthetic-token-01"
assert ops.seed_if_absent(ops.OPS_FILE, cfg) is True
print("ok")
'

expect_ok "file values resolve over env (file beats env)" \
    "IDLE_TIMEOUT=777" "KNOCK_TOKEN=synthetic-env-token" \
'
import palwarden_ops as ops
c = ops.resolve()
assert c == {"IDLE_TIMEOUT": 120, "IDLE_CHECK_INTERVAL": 90, "KNOCK_ENABLED": False,
             "KNOCK_COOLDOWN": 1200, "KNOCK_TOKEN": "synthetic-token-01"}, c
print("ok")
'

rm -f "$OPS"

expect_ok "env: non-empty env applies when the file is absent" \
    "IDLE_TIMEOUT=45" "KNOCK_COOLDOWN=1800" "KNOCK_TOKEN=synthetic-env-token" \
'
import palwarden_ops as ops
c = ops.resolve()
assert c["IDLE_TIMEOUT"] == 45 and c["KNOCK_COOLDOWN"] == 1800
assert c["KNOCK_TOKEN"] == "synthetic-env-token"
assert c["IDLE_CHECK_INTERVAL"] == 60 and c["KNOCK_ENABLED"] is True
print("ok")
'

expect_ok "env: empty non-secret env selects defaults (idle off, knock on)" \
    "IDLE_TIMEOUT=" "KNOCK_ENABLED=" \
'
import palwarden_ops as ops
c = ops.resolve()
assert c["IDLE_TIMEOUT"] == 0 and c["KNOCK_ENABLED"] is True, c
print("ok")
'

expect_ok "env: empty KNOCK_TOKEN is meaningful, not an error" \
    "KNOCK_TOKEN=" \
'
import palwarden_ops as ops
assert ops.resolve()["KNOCK_TOKEN"] == ""
print("ok")
'

expect_ok "env: IDLE_CHECK_INTERVAL=1 accepted (lower bound)" \
    "IDLE_CHECK_INTERVAL=1" \
'
import palwarden_ops as ops
assert ops.resolve()["IDLE_CHECK_INTERVAL"] == 1
print("ok")
'

expect_ok "env: IDLE_CHECK_INTERVAL=3600 accepted" \
    "IDLE_CHECK_INTERVAL=3600" \
'
import palwarden_ops as ops
assert ops.resolve()["IDLE_CHECK_INTERVAL"] == 3600
print("ok")
'

# ---------------------------------------------------------------------------
# C. Strict validation: malformed or out-of-range values reject (ConfigError).
# ---------------------------------------------------------------------------
for v in 10081 -1 60.5 abc " 60" 060 +60 1e2; do
    expect_err "reject: IDLE_TIMEOUT=$v" "IDLE_TIMEOUT=$v" \
        'import palwarden_ops as ops; ops.resolve()'
done
# 0 is the valid default; "" for a non-secret selects the default, not a
# reject:
expect_ok "env: empty IDLE_TIMEOUT selects the default, not a reject" "IDLE_TIMEOUT=" \
'
import palwarden_ops as ops
assert ops.resolve()["IDLE_TIMEOUT"] == 0
print("ok")
'
for v in 10080 0; do
    expect_ok "accept: IDLE_TIMEOUT=$v" "IDLE_TIMEOUT=$v" "EXPECT=$v" \
'
import os, palwarden_ops as ops
assert ops.resolve()["IDLE_TIMEOUT"] == int(os.environ["EXPECT"])
print("ok")
'
done

for v in 0 3601 1.5; do
    expect_err "reject: IDLE_CHECK_INTERVAL=$v" "IDLE_CHECK_INTERVAL=$v" \
        'import palwarden_ops as ops; ops.resolve()'
done

for v in 0 86401 -5; do
    expect_err "reject: KNOCK_COOLDOWN=$v" "KNOCK_COOLDOWN=$v" \
        'import palwarden_ops as ops; ops.resolve()'
done
expect_ok "accept: KNOCK_COOLDOWN=86400 boundary" "KNOCK_COOLDOWN=86400" \
'
import palwarden_ops as ops
assert ops.resolve()["KNOCK_COOLDOWN"] == 86400
print("ok")
'
expect_ok "accept: KNOCK_COOLDOWN=1 boundary" "KNOCK_COOLDOWN=1" \
'
import palwarden_ops as ops
assert ops.resolve()["KNOCK_COOLDOWN"] == 1
print("ok")
'

for v in True TRUE true1 1 0 yes no "true " " false"; do
    expect_err "reject: KNOCK_ENABLED=$v" "KNOCK_ENABLED=$v" \
        'import palwarden_ops as ops; ops.resolve()'
done
expect_ok "accept: KNOCK_ENABLED=false (strict lowercase)" "KNOCK_ENABLED=false" \
'
import palwarden_ops as ops
assert ops.resolve()["KNOCK_ENABLED"] is False
print("ok")
'

# Token: byte-based UTF-8 limit, control characters, shell metacharacters as
# inert data.
expect_ok "token: 512 one-byte chars accepted" \
'
import palwarden_ops as ops
c = ops.resolve(env={"KNOCK_TOKEN": "a" * 512})
assert len(c["KNOCK_TOKEN"].encode("utf-8")) == 512
print("ok")
'
expect_err "token: 513 one-byte chars rejected" \
'
import palwarden_ops as ops
ops.resolve(env={"KNOCK_TOKEN": "a" * 513})
'
expect_ok "token: 510 UTF-8 bytes (170 x 3-byte char) accepted" \
'
import palwarden_ops as ops
c = ops.resolve(env={"KNOCK_TOKEN": "\u20ac" * 170})
assert len(c["KNOCK_TOKEN"].encode("utf-8")) == 510
print("ok")
'
expect_err "token: 513 UTF-8 bytes (171 x 3-byte char) rejected" \
'
import palwarden_ops as ops
ops.resolve(env={"KNOCK_TOKEN": "\u20ac" * 171})
'
for ch in '\n' '\x00' '\x7f' '\x1b'; do
    expect_err "token: control character $ch rejected" \
"
import palwarden_ops as ops
ops.resolve(env={\"KNOCK_TOKEN\": \"$ch\"})
"
done
expect_ok "token: unicode and shell metacharacters round-trip as data" \
'
import palwarden_ops as ops
t = "t\u00e9k\u00e9n (ok) `id` $(reboot)"
c = ops.resolve(env={"KNOCK_TOKEN": t})
assert c["KNOCK_TOKEN"] == t
print("ok")
'

# Rejection must name the offending key.
out="$(run_py "IDLE_TIMEOUT=10081" 'import palwarden_ops as ops; ops.resolve()' 2>&1 >/dev/null)"
assert_contains "$out" "IDLE_TIMEOUT" "rejection message names the key"

# ---------------------------------------------------------------------------
# D. The canonical data file: fixed keys, schema order, JSON-quoted strings.
# ---------------------------------------------------------------------------
expect_ok "render: DEFAULTS produces the exact canonical text" \
'
import palwarden_ops as ops
expected = (
    "IDLE_TIMEOUT=\"0\"\n"
    "IDLE_CHECK_INTERVAL=\"60\"\n"
    "KNOCK_ENABLED=\"true\"\n"
    "KNOCK_COOLDOWN=\"600\"\n"
    "KNOCK_TOKEN=\"\"\n"
)
assert ops.render(ops.DEFAULTS) == expected, ops.render(ops.DEFAULTS)
print("ok")
'

expect_ok "render: non-ASCII is escaped, file stays pure ASCII" \
'
import palwarden_ops as ops
cfg = dict(ops.DEFAULTS)
cfg["KNOCK_TOKEN"] = "t\u00e9k\u00e9n"
text = ops.render(cfg)
text.encode("ascii")
assert "\u00e9" not in text
assert "\\u00e9" in text
print("ok")
'

# Round-trip through a real file.
expect_ok "round-trip: parse(render(cfg)) equals cfg, render(parse(f)) equals bytes" \
'
import palwarden_ops as ops
cfg = dict(ops.DEFAULTS)
cfg["IDLE_TIMEOUT"] = 45
cfg["IDLE_CHECK_INTERVAL"] = 30
cfg["KNOCK_ENABLED"] = True
cfg["KNOCK_COOLDOWN"] = 3600
cfg["KNOCK_TOKEN"] = "t\u00e9k\u00e9n (ok) \"quoted\" `id`"
text = ops.render(cfg)
open(str(ops.OPS_FILE), "w").write(text)
assert ops.parse_file(ops.OPS_FILE) == {
    "IDLE_TIMEOUT": "45", "IDLE_CHECK_INTERVAL": "30", "KNOCK_ENABLED": "true",
    "KNOCK_COOLDOWN": "3600", "KNOCK_TOKEN": cfg["KNOCK_TOKEN"],
}
assert open(str(ops.OPS_FILE)).read() == text
print("ok")
'

# Shell syntax is inert data on disk and in memory.
rm -f "$OPS"
run_py "WORKDIR=$WORK" '
import os, palwarden_ops as ops
token = "$(touch " + os.environ["WORKDIR"] + "/leak) `id`"
cfg = dict(ops.DEFAULTS)
cfg["KNOCK_TOKEN"] = token
ops.seed_if_absent(ops.OPS_FILE, cfg)
c = ops.resolve()
assert c["KNOCK_TOKEN"] == token, c
assert not os.path.exists(os.environ["WORKDIR"] + "/leak")
' > /dev/null 2>&1
assert_file_contains "$OPS" '$(touch' "file on disk holds literal dollar-paren data"
assert_file_contains "$OPS" '`id`' "file on disk holds literal backtick data"
[ ! -e "$WORK/leak" ] && pass "no shell execution: leak file was not created" \
    || fail "no shell execution: leak file was not created"

# Malformed files reject (fail-closed; no fallback to env/defaults).
printf 'IDLE_TIMEOUT="0"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\nEXTRA_KEY="1"\n' > "$OPS"
expect_err "file: unknown key rejected" \
    "IDLE_TIMEOUT=45" 'import palwarden_ops as ops; ops.resolve()'

printf 'IDLE_TIMEOUT="0"\nIDLE_TIMEOUT="10"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\n' > "$OPS"
expect_err "file: duplicate key rejected" \
    'import palwarden_ops as ops; ops.resolve()'

printf 'IDLE_TIMEOUT="0"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\n' > "$OPS"
expect_err "file: missing KNOCK_TOKEN rejected" \
    'import palwarden_ops as ops; ops.resolve()'

printf 'IDLE_CHECK_INTERVAL="60"\nIDLE_TIMEOUT="0"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\n' > "$OPS"
expect_err "file: keys out of schema order rejected" \
    'import palwarden_ops as ops; ops.resolve()'

printf 'IDLE_TIMEOUT=0\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\n' > "$OPS"
expect_err "file: unquoted value rejected" \
    'import palwarden_ops as ops; ops.resolve()'

printf 'IDLE_TIMEOUT="0\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\n' > "$OPS"
expect_err "file: unterminated JSON string rejected" \
    'import palwarden_ops as ops; ops.resolve()'

printf 'IDLE_TIMEOUT="0"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED=true\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\n' > "$OPS"
expect_err "file: bare (non-string) JSON rejected" \
    'import palwarden_ops as ops; ops.resolve()'

printf 'IDLE_TIMEOUT="0"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\ngarbage\n' > "$OPS"
expect_err "file: trailing junk line rejected" \
    'import palwarden_ops as ops; ops.resolve()'

: > "$OPS"
expect_err "file: empty file rejected" \
    'import palwarden_ops as ops; ops.resolve()'

printf 'IDLE_TIMEOUT="\xff"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\n' > "$OPS"
expect_err "file: invalid UTF-8 rejected" \
    'import palwarden_ops as ops; ops.resolve()'

# A valid-but-invalid-value file must not be papered over by env.
printf 'IDLE_TIMEOUT="99999"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\n' > "$OPS"
expect_err "file: out-of-range value rejected (fail-closed)" \
    "IDLE_TIMEOUT=45" 'import palwarden_ops as ops; ops.resolve()'

# ---------------------------------------------------------------------------
# E. Writer: atomic, validating, restrictive, never follows symlinks.
# ---------------------------------------------------------------------------
rm -f "$OPS"
expect_ok "writer: creates 0640 file with the account group" \
    "CURGROUP=$CURGROUP" "WORKDIR=$WORK" \
'
import grp, os, palwarden_ops as ops
ops.seed_if_absent(ops.OPS_FILE, None)
st = os.lstat(ops.OPS_FILE)
assert (st.st_mode & 0o777) == 0o640, oct(st.st_mode)
assert grp.getgrgid(st.st_gid).gr_name == os.environ["CURGROUP"], st.st_gid
print("ok")
'
assert_eq "$(stat -c %a "$OPS")" "640" "writer: file mode is 0640"
assert_eq "$(stat -c %U "$OPS")" "$(id -un)" "writer: creator keeps ownership"

expect_ok "writer: overwrite keeps 0640 and updates content" \
    "CURGROUP=$CURGROUP" \
'
import os, palwarden_ops as ops
cfg = dict(ops.DEFAULTS); cfg["IDLE_TIMEOUT"] = 30
ops.write_config(ops.OPS_FILE, cfg, group=os.environ["CURGROUP"])
st = os.lstat(ops.OPS_FILE)
assert (st.st_mode & 0o777) == 0o640
c = ops.resolve()
assert c["IDLE_TIMEOUT"] == 30
print("ok")
'

# Symlink target: refused, link and target untouched.
run_py "WORKDIR=$WORK" '
import os, palwarden_ops as ops
real = os.path.join(os.environ["WORKDIR"], "real.env")
with open(real, "w") as f:
    f.write("sentinel\n")
p = str(ops.OPS_FILE)
if os.path.lexists(p):
    os.remove(p)
os.symlink(real, p)
' 2>/dev/null
out="$(run_py "CURGROUP=$CURGROUP" '
import os, palwarden_ops as ops
try:
    ops.write_config(ops.OPS_FILE, ops.DEFAULTS, group=os.environ["CURGROUP"])
    raise SystemExit("write_config followed a symlink")
except ops.ConfigError:
    print("ok")
' 2>&1)"
[ "$out" = "ok" ] && pass "writer: symlink target refused" || fail "writer: symlink target refused ($out)"
[ -L "$OPS" ] && pass "writer: symlink left in place" || fail "writer: symlink left in place"
assert_eq "$(cat "$WORK/real.env")" "sentinel" "writer: symlink target content untouched"

# FIFO target refused.
rm -f "$OPS"; mkfifo "$OPS"
out="$(run_py "CURGROUP=$CURGROUP" '
import os, palwarden_ops as ops
try:
    ops.write_config(ops.OPS_FILE, ops.DEFAULTS, group=os.environ["CURGROUP"])
    raise SystemExit("write_config wrote through a FIFO")
except ops.ConfigError:
    print("ok")
' 2>&1)"
[ "$out" = "ok" ] && pass "writer: FIFO target refused" || fail "writer: FIFO target refused ($out)"
[ -p "$OPS" ] && pass "writer: FIFO left in place" || fail "writer: FIFO left in place"
rm -f "$OPS"

# Missing parent refused.
out="$(run_py "WORKDIR=$WORK" '
import os, palwarden_ops as ops
try:
    ops.write_config(os.path.join(os.environ["WORKDIR"], "nodir", "x.env"), ops.DEFAULTS)
    raise SystemExit("write_config created a missing parent")
except ops.ConfigError:
    print("ok")
' 2>&1)"
[ "$out" = "ok" ] && pass "writer: missing parent refused" || fail "writer: missing parent refused ($out)"

# Symlinked parent refused.
mkdir -p "$WORK/realdir"
ln -s "$WORK/realdir" "$WORK/linkdir"
out="$(run_py "WORKDIR=$WORK" '
import os, palwarden_ops as ops
try:
    ops.write_config(os.path.join(os.environ["WORKDIR"], "linkdir", "x.env"), ops.DEFAULTS)
    raise SystemExit("write_config followed a symlinked parent")
except ops.ConfigError:
    print("ok")
' 2>&1)"
[ "$out" = "ok" ] && pass "writer: symlinked parent refused" || fail "writer: symlinked parent refused ($out)"
rm -rf "$WORK/realdir" "$WORK/linkdir"

# A failed write leaves the original file byte-identical.
run_py "CURGROUP=$CURGROUP" '
import palwarden_ops as ops
ops.seed_if_absent(ops.OPS_FILE, None)
' > /dev/null 2>&1
v1="$(cat "$OPS")"
chmod 0555 "$WORK"
expect_err "writer: unwritable parent fails (EACCES wrapped)" \
    "CURGROUP=$CURGROUP" \
'
import os, palwarden_ops as ops
ops.write_config(ops.OPS_FILE, ops.DEFAULTS, group=os.environ["CURGROUP"])
'
chmod 0755 "$WORK"
assert_eq "$(cat "$OPS")" "$v1" "writer: original file untouched on failure"

# No stray temp files left behind.
[ -z "$(find "$WORK" -maxdepth 1 -name '.*tmp' -print -quit)" ] \
    && pass "writer: no stray temp files" \
    || fail "writer: no stray temp files"

# Root-only assertion (foreign-group chown) — report clearly when unrunnable.
if [ "$(id -u)" -eq 0 ]; then
    expect_ok "writer: root can assign a group the writer is not in" \
        "CURGROUP=root" \
'
import os, palwarden_ops as ops
ops.seed_if_absent(ops.OPS_FILE, None)
ops.write_config(ops.OPS_FILE, ops.DEFAULTS, group="root")
st = os.lstat(ops.OPS_FILE)
assert st.st_uid == 0 and st.st_gid == 0
print("ok")
'
else
    echo "  UNAVAILABLE (non-root): foreign-group chown assertion not executed"
fi

# ---------------------------------------------------------------------------
# F. Merge: partial API payloads against the current typed config.
# ---------------------------------------------------------------------------
expect_ok "merge: omitted token kept, fields replaced, result complete" \
'
import palwarden_ops as ops
cur = dict(ops.DEFAULTS)
cur["KNOCK_TOKEN"] = "synthetic-token-01"
m = ops.merge(cur, {"IDLE_TIMEOUT": 45, "IDLE_CHECK_INTERVAL": 30})
assert m["IDLE_TIMEOUT"] == 45 and m["IDLE_CHECK_INTERVAL"] == 30
assert m["KNOCK_TOKEN"] == "synthetic-token-01"
assert m["KNOCK_ENABLED"] is True and m["KNOCK_COOLDOWN"] == 600
assert set(m) == set(ops.KEYS)
print("ok")
'
expect_ok "merge: empty token clears, text token replaces" \
'
import palwarden_ops as ops
cur = dict(ops.DEFAULTS)
cur["KNOCK_TOKEN"] = "synthetic-token-01"
assert ops.merge(cur, {"KNOCK_TOKEN": ""})["KNOCK_TOKEN"] == ""
assert ops.merge(cur, {"KNOCK_TOKEN": "synthetic-token-02"})["KNOCK_TOKEN"] == "synthetic-token-02"
print("ok")
'
expect_ok "merge: empty payload returns the current config" \
'
import palwarden_ops as ops
cur = dict(ops.DEFAULTS)
cur["KNOCK_TOKEN"] = "synthetic-token-01"
assert ops.merge(cur, {}) == cur
print("ok")
'
expect_ok "merge: API ints and bools normalise to canonical strings internally" \
'
import palwarden_ops as ops
assert ops.canonical("IDLE_TIMEOUT", 45) == "45"
assert ops.canonical("KNOCK_ENABLED", True) == "true"
assert ops.canonical("KNOCK_ENABLED", False) == "false"
assert ops.canonical("KNOCK_COOLDOWN", 3600) == "3600"
print("ok")
'
expect_err "merge: unknown key rejected" \
'
import palwarden_ops as ops
ops.merge(ops.DEFAULTS, {"IDLE_TIMEOUTS": 5})
'
expect_err "merge: out-of-range value rejected" \
'
import palwarden_ops as ops
ops.merge(ops.DEFAULTS, {"IDLE_TIMEOUT": 10081})
'
expect_err "merge: non-canonical string rejected" \
'
import palwarden_ops as ops
ops.merge(ops.DEFAULTS, {"IDLE_CHECK_INTERVAL": "60.0"})
'
expect_err "merge: loose boolean rejected" \
'
import palwarden_ops as ops
ops.merge(ops.DEFAULTS, {"KNOCK_ENABLED": "True"})
'
expect_err "merge: partial current config rejected" \
'
import palwarden_ops as ops
ops.merge({"IDLE_TIMEOUT": 5}, {"KNOCK_COOLDOWN": 100})
'

# ---------------------------------------------------------------------------
# G. Public view: exactly four non-secret fields + token_configured.
# ---------------------------------------------------------------------------
expect_ok "public view: fixed keys, typed, token redacted" \
'
import json, palwarden_ops as ops
cur = dict(ops.DEFAULTS)
cur["KNOCK_TOKEN"] = "synthetic-token-01"
v = ops.public_view(cur)
assert set(v) == {"IDLE_TIMEOUT", "IDLE_CHECK_INTERVAL", "KNOCK_ENABLED",
                  "KNOCK_COOLDOWN", "token_configured"}, v
assert v["token_configured"] is True
assert v["IDLE_TIMEOUT"] == 0 and v["KNOCK_ENABLED"] is True
assert isinstance(v["IDLE_TIMEOUT"], int) and isinstance(v["KNOCK_ENABLED"], bool)
assert "KNOCK_TOKEN" not in v
assert "synthetic-token-01" not in json.dumps(v)
v2 = ops.public_view(ops.DEFAULTS)
assert v2["token_configured"] is False
assert "synthetic" not in json.dumps(v2)
print("ok")
'

# ---------------------------------------------------------------------------
# H. seed_if_absent: idempotent, never clobbers an existing file.
# ---------------------------------------------------------------------------
rm -f "$OPS"
expect_ok "seed: absent file created with the given config" \
    "CURGROUP=$CURGROUP" \
'
import palwarden_ops as ops
cfg = dict(ops.DEFAULTS); cfg["IDLE_TIMEOUT"] = 240
assert ops.seed_if_absent(ops.OPS_FILE, cfg) is True
assert ops.resolve()["IDLE_TIMEOUT"] == 240
print("ok")
'
v1="$(cat "$OPS")"
expect_ok "seed: existing file left untouched (returns False)" \
'
import palwarden_ops as ops
assert ops.seed_if_absent(ops.OPS_FILE, ops.DEFAULTS) is False
print("ok")
'
assert_eq "$(cat "$OPS")" "$v1" "seed: existing file bytes unchanged"
expect_ok "seed: existing invalid file also left untouched" \
'
import palwarden_ops as ops
assert ops.seed_if_absent(ops.OPS_FILE, ops.DEFAULTS) is False
print("ok")
'

# ---------------------------------------------------------------------------
# I. `python3 -m palwarden_ops seed` CLI (plan Task 10): the container
#   entrypoint's ONLY seed path — the module is the shared renderer, so the
#   entrypoint must not re-serialize the five keys in bash (spec §7.1).
#   Pins: complete validated file from env seeds when absent; existing file
#   never re-rendered (changed seeds do not override saved values); invalid
#   seeds fail visibly with no file; an invalid EXISTING file fails visibly
#   and stays byte-identical (fail closed, never silently re-seeded);
#   symlink targets refused; unknown verbs are usage errors.
# ---------------------------------------------------------------------------
run_cli() {
    local code="${*: -1}"
    local n=$(( $# - 1 ))
    local -a envs=()
    if [ "$n" -gt 0 ]; then envs=("${@:1:$n}"); fi
    # deliberate word splitting below: $code is the bare verb (e.g. "seed"),
    # never a quoted argument with spaces or globs.
    # shellcheck disable=SC2086
    PYTHONPATH="$LIB" env -u IDLE_TIMEOUT -u IDLE_CHECK_INTERVAL -u KNOCK_ENABLED \
        -u KNOCK_COOLDOWN -u KNOCK_TOKEN \
        ${envs[@]+"${envs[@]}"} \
        python3 -m palwarden_ops $code
}

rm -f "$OPS"
out="$(run_cli "seed" 2>&1)"; rc=$?
assert_eq "$rc" "0" "cli seed: absent file, no seeds -> exit 0"
assert_eq "$(cat "$OPS")" "$(printf 'IDLE_TIMEOUT="0"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\n')" \
    "cli seed: complete default file (all five keys, canonical bytes)"
assert_eq "$(stat -c '%a' "$OPS")" "640" "cli seed: file mode 0640"

rm -f "$OPS"
out="$(run_cli "IDLE_TIMEOUT=240" "KNOCK_TOKEN=合成-token\$x" "seed" 2>&1)"; rc=$?
assert_eq "$rc" "0" "cli seed: env seeds accepted -> exit 0"
assert_eq "$(cat "$OPS")" "$(printf 'IDLE_TIMEOUT="240"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN="\\u5408\\u6210-token$x"\n')" \
    "cli seed: seeds land as canonical JSON data (unicode escaped, $ inert)"

# Changed seeds must NOT override the saved file (compose seeds are seeds).
out="$(run_cli "IDLE_TIMEOUT=7" "seed" 2>&1)"; rc=$?
assert_eq "$rc" "0" "cli seed: existing file -> exit 0"
assert_eq "$(PYTHONPATH="$LIB" python3 -c \
    'import palwarden_ops as ops; print(ops.resolve()["IDLE_TIMEOUT"])')" "240" \
    "cli seed: existing file untouched by changed seeds"

# Invalid seed value: visible failure, and NO file is created.
rm -f "$OPS"
out="$(run_cli "IDLE_TIMEOUT=abc" "seed" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "cli seed: invalid seed fails visibly (rc=$rc)" \
    || fail "cli seed: invalid seed must fail (output: $out)"
[[ -e "$OPS" ]] && fail "cli seed: invalid seed must not create the file" \
    || pass "cli seed: invalid seed creates nothing"
case "$out" in *IDLE_TIMEOUT*) pass "cli seed: failure names the offending key";;
    *) fail "cli seed: failure must name the key (output: $out)";; esac

# Invalid EXISTING file: fail closed, byte-identical, never re-seeded.
printf 'IDLE_TIMEOUT=99999999\n' > "$OPS"
out="$(run_cli "IDLE_TIMEOUT=5" "seed" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "cli seed: invalid existing file fails closed (rc=$rc)" \
    || fail "cli seed: invalid existing file must fail (output: $out)"
assert_eq "$(cat "$OPS")" "IDLE_TIMEOUT=99999999" \
    "cli seed: invalid existing file left byte-identical"

# Symlink target: refused, link and its target untouched.
rm -f "$OPS" "$WORK/real.env"
: > "$WORK/real.env"
ln -s "$WORK/real.env" "$OPS"
out="$(run_cli "seed" 2>&1)"; rc=$?
[[ "$rc" -ne 0 ]] && pass "cli seed: symlink target refused (rc=$rc)" \
    || fail "cli seed: symlink target must be refused (output: $out)"
[[ -L "$OPS" && ! -s "$WORK/real.env" ]] && pass "cli seed: symlink and target untouched" \
    || fail "cli seed: symlink target was followed"
rm -f "$OPS" "$WORK/real.env"

out="$(run_cli "frobnicate" 2>&1)"; rc=$?
[[ "$rc" -eq 64 ]] && pass "cli: unknown verb exits 64 (usage)" \
    || fail "cli: unknown verb must exit 64, got $rc"

assert_report
