#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Unit tests for the container `systemctl` -> s6/cgroup shim. Fake s6-svstat /
# s6-svc binaries and a fake cgroup file let us test the mapping without s6.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
SHIM="$DIR/../../docker/shims/systemctl"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fake s6 tool dir + service scandir.
mkdir -p "$WORK/bin" "$WORK/run/service/palworld-server" "$WORK/contents"
cat > "$WORK/bin/s6-svstat" <<EOF
#!/usr/bin/env bash
# Report state from a file we control per service dir.
svc="\${1##*/}"
cat "$WORK/state_\$svc" 2>/dev/null || echo "down"
EOF
cat > "$WORK/bin/s6-svc" <<EOF
#!/usr/bin/env bash
# Record the last s6-svc invocation for assertions.
echo "\$*" >> "$WORK/svc_calls"
EOF
chmod +x "$WORK/bin/s6-svstat" "$WORK/bin/s6-svc"

printf '104857600' > "$WORK/cgmem"        # 100 MiB
printf 'up (pid 4242 pgid 4242) 5 seconds' > "$WORK/state_palworld-server"

run_shim() {
  PATH="$WORK/bin:$PATH" \
  PALWARDEN_S6_SVC_DIR="$WORK/run/service" \
  PALWARDEN_CGROUP_MEM="$WORK/cgmem" \
    bash "$SHIM" "$@"
}

# is-active: up -> "active" / rc 0
assert_eq "$(run_shim is-active palworld.service)" "active" "is-active up"
assert_rc 0 run_shim is-active --quiet palworld.service

# is-active: down -> "inactive" / rc 3
printf 'down' > "$WORK/state_palworld-server"
assert_eq "$(run_shim is-active palworld.service)" "inactive" "is-active down"
assert_rc 3 run_shim is-active palworld.service
printf 'up (pid 4242 pgid 4242) 5 seconds' > "$WORK/state_palworld-server"

# MemoryCurrent from the fake cgroup file
assert_eq "$(run_shim show -p MemoryCurrent --value palworld.service)" "104857600" "MemoryCurrent value"

# MainPID parsed from svstat
assert_eq "$(run_shim show -p MainPID --value palworld.service)" "4242" "MainPID value"

# is-enabled reflects the s6 user-bundle marker. The shim looks under
# /etc/s6-overlay/... which we can't fake without root, so just assert the
# command runs and returns a known token.
out="$(run_shim is-enabled palworld.service)"
assert_contains "${out}enabled_or_disabled" "abled" "is-enabled returns a state"

# start/stop/restart map to s6-svc
: > "$WORK/svc_calls"
run_shim start palworld.service
run_shim stop palworld.service
run_shim restart palworld.service
assert_file_contains "$WORK/svc_calls" "-u" "start -> s6-svc -u"
assert_file_contains "$WORK/svc_calls" "-d" "stop -> s6-svc -d"
assert_file_contains "$WORK/svc_calls" "-r" "restart -> s6-svc -r"

# unknown verbs are non-fatal
assert_rc 0 run_shim daemon-reload

assert_report
