#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Memory watchdog. The important case is a container with a memory limit: judging
# usage against the HOST's RAM (what /proc/meminfo reports inside a container)
# makes the watchdog useless there — a server filling its 512 MiB limit is ~1.5%
# of a 32 GiB host, so it would never restart.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
WATCH="$DIR/../../sbin/palworld-memory-watch"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# fake systemctl: active/inactive from a state file, MemoryCurrent from a file
cat > "$WORK/bin/systemctl" <<EOF
#!/usr/bin/env bash
active="\$(cat "$WORK/active" 2>/dev/null || echo 1)"
case "\$1" in
  is-active) [ "\$active" = "1" ] && exit 0 || exit 3 ;;
  show) cat "$WORK/svc_mem" 2>/dev/null || echo 0 ;;
esac
exit 0
EOF
# fake graceful-restart: just record that it was asked to run
cat > "$WORK/bin/palworld-graceful-restart" <<EOF
#!/usr/bin/env bash
echo "restart \$*" >> "$WORK/restarts"
EOF
# fake flock: drop the "-n FILE" arguments and run the command
cat > "$WORK/bin/flock" <<'EOF'
#!/usr/bin/env bash
shift 2
exec "$@"
EOF
chmod +x "$WORK/bin/systemctl" "$WORK/bin/palworld-graceful-restart" "$WORK/bin/flock"

# 32 GiB host, 10 GiB available (~69% used)
host_meminfo() { printf 'MemTotal:       %d kB\nMemAvailable:   %d kB\n' 33554432 10485760 > "$WORK/meminfo"; }
host_meminfo
echo 1 > "$WORK/active"
echo 0 > "$WORK/svc_mem"

run_watch() {
  : > "$WORK/restarts"
  PATH="$WORK/bin:$PATH" \
  PALWORLD_MEMINFO="$WORK/meminfo" \
  PALWARDEN_CGROUP_MEM_MAX="$WORK/cg_max" \
  PALWARDEN_CGROUP_MEM_CURRENT="$WORK/cg_current" \
  PALWORLD_RESTART_BIN="$WORK/bin/palworld-graceful-restart" \
    bash "$WATCH" "$@"
}
restarted() { [ -s "$WORK/restarts" ]; }

# --- no cgroup limit: bare-metal behaviour, judged on host memory ------------
echo max > "$WORK/cg_max"; echo 0 > "$WORK/cg_current"
out="$(run_watch --threshold 85)"; rc=$?
assert_eq "$rc" "0" "no limit, host below threshold: exits 0"
assert_contains "$out" "Memory OK" "no limit: reports OK"
assert_rc 1 restarted

# host memory over the threshold still triggers a restart on bare metal
out="$(run_watch --threshold 60 2>&1)"
assert_rc 0 restarted
assert_contains "$out" "system memory" "host pressure names the system as the reason"

# --- THE REGRESSION: container with a 512 MiB limit, nearly full -------------
# 500 MiB of a 512 MiB limit = 97% of the limit but only ~1.5% of the host.
printf '%d\n' $((512 * 1024 * 1024)) > "$WORK/cg_max"
printf '%d\n' $((500 * 1024 * 1024)) > "$WORK/cg_current"
out="$(run_watch --threshold 85 2>&1)"
assert_rc 0 restarted
assert_contains "$out" "limit" "limit-relative reason is reported"
assert_not_contains "$out" "0%" "usage is not reported as 0% of the host"

# --- same limit, comfortably below threshold: no restart ---------------------
printf '%d\n' $((100 * 1024 * 1024)) > "$WORK/cg_current"
out="$(run_watch --threshold 85)"; rc=$?
assert_eq "$rc" "0" "limit, below threshold: exits 0"
assert_contains "$out" "Memory OK" "limit, below threshold: reports OK"
assert_contains "$out" "limit" "OK message states the basis"
assert_rc 1 restarted

# --- an inactive service is left alone --------------------------------------
echo 0 > "$WORK/active"
printf '%d\n' $((500 * 1024 * 1024)) > "$WORK/cg_current"
out="$(run_watch --threshold 85)"; rc=$?
assert_eq "$rc" "0" "inactive service: exits 0"
assert_contains "$out" "not active" "inactive service is skipped"
assert_rc 1 restarted
echo 1 > "$WORK/active"

# --- the service's own cgroup (bare metal) still counts ----------------------
# No container limit, host fine, but the unit's cgroup is huge -> restart.
echo max > "$WORK/cg_max"; echo 0 > "$WORK/cg_current"
printf '%d\n' $((30 * 1024 * 1024 * 1024)) > "$WORK/svc_mem"   # 30 GiB of a 32 GiB host
out="$(run_watch --threshold 85 2>&1)"
assert_rc 0 restarted
assert_contains "$out" "cgroup" "service cgroup pressure is reported"

# ===========================================================================
# The restart the watchdog invokes must not stall. In the container,
# graceful-restart used to wait the full startup timeout for a REST API that was
# never configured — with the watchdog on a 5-minute timer, that overlaps the
# next tick.
# ===========================================================================
RESTART="$DIR/../../sbin/palworld-graceful-restart"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/s6-svc"
cat > "$WORK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$WORK/bin/s6-svc" "$WORK/bin/sudo"

# palworld-api exits 2 when REST is not enabled / has no admin password
printf '#!/usr/bin/env bash\nexit 2\n' > "$WORK/bin/api-unconfigured"
# ...and 0 once it answers
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/api-ready"
chmod +x "$WORK/bin/api-unconfigured" "$WORK/bin/api-ready"

run_restart() {
  PATH="$WORK/bin:$PATH" PALWARDEN_CONTAINER=1 \
  PALWARDEN_S6_SVC_DIR="$WORK/service" PALWORLD_API_BIN="$1" \
    timeout 20 bash "$RESTART" --startup-timeout 15
}

start=$SECONDS
out="$(run_restart "$WORK/bin/api-unconfigured" 2>&1)"; rc=$?
elapsed=$(( SECONDS - start ))
assert_eq "$rc" "0" "unconfigured REST: restart exits 0"
assert_contains "$out" "not configured" "unconfigured REST: says readiness was skipped"
if [ "$elapsed" -lt 5 ]; then pass; else fail "unconfigured REST: returned in ${elapsed}s, should be immediate"; fi

out="$(run_restart "$WORK/bin/api-ready" 2>&1)"; rc=$?
assert_eq "$rc" "0" "ready REST: restart exits 0"
assert_contains "$out" "restarted" "ready REST: reports the restart"

assert_report
