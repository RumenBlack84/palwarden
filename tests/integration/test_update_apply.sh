#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Integration test for the FULL update-apply flow (not just --check): simulates a
# new Steam build and verifies palworld-update, in-container, gracefully stops
# the server, "installs" via a fake SteamCMD, restarts it, and records event
# markers. Uses a dummy server that serves a minimal REST API on :8212 so the
# flow's readiness probes behave like a real server.
#
# Requires docker.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
source "$DIR/../lib/assert.sh"

IMG="palwarden:test"
C=pw-update-apply
WORK="$(mktemp -d)"
cleanup() { docker rm -f "$C" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

# Pre-installed dummy server (copy so the test never mutates the committed fixture).
cp -r "$REPO/tests/fixtures/fake-server-rest" "$WORK/server"
mkdir -p "$WORK/server/steamapps"
printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' > "$WORK/server/steamapps/appmanifest_2394010.acf"
cp "$REPO/tests/fixtures/fake-steamcmd" "$WORK/fake-steamcmd"; chmod +x "$WORK/fake-steamcmd"

echo "  building $IMG ..."
docker build -q -f "$REPO/docker/Dockerfile" -t "$IMG" "$REPO" >/dev/null 2>&1 || { fail "build failed"; assert_report; exit 1; }

docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" \
  -e PALWARDEN_MODE=embedded -e UPDATE_ON_START=false -e ADMIN_PASSWORD=updpw \
  -v "$WORK/server":/opt/palworld/server \
  -v "$WORK/fake-steamcmd":/fake-steamcmd:ro \
  "$IMG" >/dev/null

# Wait for the (dummy) server + its REST API to come up.
up=0
for _ in $(seq 1 40); do
  if docker exec "$C" sh -c 'sudo palworld-api info 2>/dev/null' | grep -q "HTTP 200"; then up=1; break; fi
  sleep 1
done
if [ "$up" = 1 ]; then pass; else fail "server/REST did not come up"; fi

buildid() { docker exec "$C" sh -c 'awk -F\" "/\"buildid\"/{print \$4; exit}" /opt/palworld/server/steamapps/appmanifest_2394010.acf'; }
runpid()  { docker exec "$C" s6-svstat /run/service/palworld-server 2>/dev/null | grep -oE 'pid [0-9]+' | grep -oE '[0-9]+'; }

assert_eq "$(buildid)" "100" "starts at buildid 100"
pid_before="$(runpid)"

# --- Simulate a new build (remote 200 > local 100) and apply it -------------
out="$(docker exec -e PALWORLD_STEAMCMD=/fake-steamcmd -e STUB_REMOTE_BUILDID=200 "$C" palworld-update 2>&1)"; rc=$?
assert_eq "$rc" "0" "update-apply exits 0"
assert_contains "$out" "update complete" "reports update complete"
assert_eq "$(buildid)" "200" "manifest bumped to new build 200"

# Server came back up after the restart, with a new supervised pid.
up=0
for _ in $(seq 1 20); do
  docker exec "$C" sh -c 'sudo palworld-api info 2>/dev/null' | grep -q "HTTP 200" && { up=1; break; }; sleep 1
done
if [ "$up" = 1 ]; then pass; else fail "server did not come back up after update"; fi
assert_ne "$pid_before" "$(runpid)" "server service was restarted by the update"

# Event markers recorded in the telemetry DB.
events="$(docker exec "$C" python3 -c "import sqlite3;print('|'.join(r[0] for r in sqlite3.connect('/var/lib/palworld/metrics.sqlite3').execute('select label from fps_events')))" 2>/dev/null)"
assert_contains "$events" "Palworld update detected"  "marker: update detected"
assert_contains "$events" "Palworld update completed" "marker: update completed"

# --- No-op case: already current (remote == local == 200) -> no restart ------
pid_now="$(runpid)"
out="$(docker exec -e PALWORLD_STEAMCMD=/fake-steamcmd -e STUB_REMOTE_BUILDID=200 "$C" palworld-update 2>&1)"; rc=$?
assert_eq "$rc" "0" "no-op update exits 0"
assert_contains "$out" "no Palworld update available" "no-op reports current"
assert_eq "$(runpid)" "$pid_now" "no-op does not restart the server"

assert_report
