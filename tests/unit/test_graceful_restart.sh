#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palworld-graceful-restart --apply-config/--apply-engine: the apply must run in
# the window where the server is fully DOWN. The game rewrites its config files
# from memory as it exits, so an apply issued while it still runs is silently
# clobbered mid-shutdown (observed on v1.0.3: the applied values survived on
# disk for a fraction of a second before the exit write put the old ones back).
# And a failed apply must never leave the server down: start anyway, exit
# nonzero so the watching caller sees it.
#
# Container branch only: it is the one an s6 stub can drive hermetically, and
# both branches share the same run_applies helper at the same point in the
# stop → apply → start sequence.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
TOOL="$DIR/../../sbin/palworld-graceful-restart"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
LOG="$WORK/order.log"

# s6-svc: record down/up transitions. sudo: strip and exec (the script wraps
# its API probe in sudo). palworld-api: exit 2 = "REST not configured", the
# fast path that skips the readiness poll without waiting out any timeout.
cat > "$WORK/bin/s6-svc" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in -d) echo "s6 down" >> "$LOG";; -u) echo "s6 up" >> "$LOG";; esac; done
EOF
cat > "$WORK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$WORK/bin/palworld-api" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
cat > "$WORK/bin/apply-ok" <<EOF
#!/usr/bin/env bash
echo "apply config" >> "$LOG"
EOF
cat > "$WORK/bin/apply-fail" <<EOF
#!/usr/bin/env bash
echo "apply config (failing)" >> "$LOG"
exit 1
EOF
cat > "$WORK/bin/engine-ok" <<EOF
#!/usr/bin/env bash
[ "\$1" = "apply" ] || { echo "engine tool called without apply: \$*" >> "$LOG"; exit 64; }
echo "apply engine" >> "$LOG"
EOF
chmod +x "$WORK/bin/"*

restart() {  # restart <extra flags...>
  PATH="$WORK/bin:$PATH" PALWARDEN_CONTAINER=1 \
  PALWORLD_API_BIN="$WORK/bin/palworld-api" \
  PALWORLD_APPLY_BIN="${APPLY_BIN_OVERRIDE:-$WORK/bin/apply-ok}" \
  PALWARDEN_ENGINE_CONFIG_BIN="$WORK/bin/engine-ok" \
    bash "$TOOL" "$@" 2>&1
}

# --- no flags: a plain restart applies nothing ------------------------------
: > "$LOG"
out="$(restart)"; rc=$?
assert_eq "$rc" "0" "plain restart succeeds"
assert_eq "$(tr '\n' ';' < "$LOG")" "s6 down;s6 up;" "plain restart runs no apply"

# --- --apply-config runs the apply strictly between down and up -------------
: > "$LOG"
out="$(restart --apply-config)"; rc=$?
assert_eq "$rc" "0" "restart with apply succeeds"
assert_eq "$(tr '\n' ';' < "$LOG")" "s6 down;apply config;s6 up;" \
  "the apply runs after the server is down and before it is started"
assert_contains "$out" "applied settings while the server was stopped" "and says so"

# --- both flags: config then engine, still inside the window ----------------
: > "$LOG"
out="$(restart --apply-config --apply-engine)"; rc=$?
assert_eq "$rc" "0" "restart with both applies succeeds"
assert_eq "$(tr '\n' ';' < "$LOG")" "s6 down;apply config;apply engine;s6 up;" \
  "both applies run in the stopped window, config first"

# --- a failed apply still starts the server, and the exit code says so ------
: > "$LOG"
out="$(APPLY_BIN_OVERRIDE="$WORK/bin/apply-fail" restart --apply-config)"; rc=$?
assert_eq "$rc" "1" "a failed apply is reported as a nonzero exit"
assert_eq "$(tr '\n' ';' < "$LOG")" "s6 down;apply config (failing);s6 up;" \
  "the server is started again even though the apply failed"
assert_contains "$out" "config apply failed" "the failure is named in the output"

# --- an unknown flag is refused, not silently swallowed ---------------------
out="$(restart --apply-everything)" ; rc=$?
assert_eq "$rc" "64" "unknown flag exits 64"

assert_report
