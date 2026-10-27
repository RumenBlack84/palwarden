#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# F9 (review follow-up): the Python notification adapters
# (palwarden_lifecycle._notify, palworld-idle-watch._notify) must SOURCE the
# optional shell helper and INVOKE its function — executing lib/palworld-notify
# merely defines palworld_notify() and exits, so dedicated idle/wake/readiness
# posts were silently absent. The shipped helper is function-only by contract
# (bash callers source it); the adapter must cope.
#
# Spec §6.3: fixed code, message/kind passed as ARGUMENTS (never interpolated
# into shell text); missing/failing helper stays nonfatal.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/../.."
source "$DIR/../lib/assert.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A function-only helper exactly like the shipped one: sourcing defines the
# function; executing it does nothing. It records argv through the ambient
# NOTIFY_SINK so the test sees the EXACT bytes each argument carried.
cat > "$WORK/helper" <<'EOF'
#!/usr/bin/env bash
palworld_notify() {
  printf '%s\0%s\0' "${1-}" "${2-}" >> "$NOTIFY_SINK"
}
EOF
chmod +x "$WORK/helper"

# Helper that fails loudly: the adapter must swallow the failure.
cat > "$WORK/helper.fails" <<'EOF'
#!/usr/bin/env bash
palworld_notify() { exit 7; }
EOF
chmod +x "$WORK/helper.fails"

# Helper that defines nothing (a stub install): nonfatal too.
: > "$WORK/helper.empty"
chmod +x "$WORK/helper.empty"

# These metacharacters must remain literal: expansion would invalidate the test.
# shellcheck disable=SC2016
MSG='wake (udp knock): $whoami `id` "quoted" it'\''s $(date) ; rm -rf /'

check_sink() { # check_sink <label> <sink> <expected-kind> <expected-message>
  python3 - "$2" "$3" "$4" <<'PY'
import sys
try:
    raw = open(sys.argv[1], "rb").read()
except OSError:
    print("MISSING"); sys.exit(0)
parts = raw.decode("utf-8").split("\0")
kind, msg = parts[0], parts[1]
if kind == sys.argv[2] and msg == sys.argv[3] and raw.count(b"\0") == 2:
    print("SINK_OK")
else:
    print("SINK_BAD %r %r" % (kind, msg))
PY
}

# --- palwarden_lifecycle._notify invokes the function ------------------------
rm -f "$WORK/lc.sink"
out="$(NOTIFY_SINK="$WORK/lc.sink" \
  PALWARDEN_NOTIFY_HELPER="$WORK/helper" PYTHONPATH="$ROOT/lib" python3 - "$MSG" <<'PY'
import sys
import palwarden_lifecycle as lc
lc._notify("warning", sys.argv[1])
print("CALLED")
PY
)"
assert_contains "$out" "CALLED" "lc._notify never raises (output: $out)"
assert_eq "$(check_sink lc "$WORK/lc.sink" warning "$MSG")" "SINK_OK" \
  "lc._notify SOURCED and INVOKED palworld_notify with exact argv (shell metacharacters literal)"

# --- palworld-idle-watch._notify invokes the function ------------------------
rm -f "$WORK/iw.sink"
out="$(NOTIFY_SINK="$WORK/iw.sink" \
  PALWARDEN_NOTIFY_HELPER="$WORK/helper" PYTHONPATH="$ROOT/lib" python3 - "$MSG" "$ROOT/sbin/palworld-idle-watch" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("idle_watch", sys.argv[2])
spec = importlib.util.spec_from_loader("idle_watch", loader)
iw = importlib.util.module_from_spec(spec)
loader.exec_module(iw)
iw._notify("warning", sys.argv[1])
print("CALLED")
PY
)"
assert_contains "$out" "CALLED" "idle-watch _notify never raises (output: $out)"
assert_eq "$(check_sink iw "$WORK/iw.sink" warning "$MSG")" "SINK_OK" \
  "idle-watch _notify SOURCED and INVOKED palworld_notify with exact argv"

# --- the shipped helper really is function-only (the contract under test) ----
# Executing it with argv must NOT deliver anything: if a future change makes
# the script self-invoking, this pins the mismatch this adapter exists for.
rm -f "$WORK/ship.sink"
NOTIFY_SINK="$WORK/ship.sink" bash "$ROOT/lib/palworld-notify" warning "x" \
  || true
assert_eq "$(check_sink ship "$WORK/ship.sink" warning "x")" "MISSING" \
  "shipped lib/palworld-notify stays function-only when EXECUTED (source-only contract)"

# --- absence / failure / no-function helper all stay nonfatal ----------------
for helper in "$WORK/no-such-helper" "$WORK/helper.fails" "$WORK/helper.empty"; do
  out="$(PALWARDEN_NOTIFY_HELPER="$helper" PYTHONPATH="$ROOT/lib" python3 - <<'PY'
import palwarden_lifecycle as lc
lc._notify("info", "bounded and nonfatal")
print("OK")
PY
)" || out="RAISED"
  assert_contains "$out" "OK" "helper '$helper' stays nonfatal for lc._notify"
done

assert_report
