#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Discord notifications are optional: palworld-notify itself no-ops when there is
# no webhook, and the whole toolchain must work when the helper isn't installed at
# all (fresh host, partial install, minimal container). Sourcing it must not abort
# a script, and calling palworld_notify must not fail with "command not found".
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
REPO="$(cd "$DIR/../.." && pwd)"

# --- invariant: every script that sources the helper defines a fallback -------
# Guards future scripts against reintroducing the abort-on-missing-helper bug.
missing_guard=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! grep -q 'declare -F palworld_notify' "$f"; then
    missing_guard="$missing_guard $(basename "$f")"
  fi
done < <(grep -rl 'source /usr/local/lib/palworld-notify' "$REPO"/sbin "$REPO"/lib "$REPO"/docker 2>/dev/null)
assert_eq "$missing_guard" "" "every notify-sourcing script defines a no-op fallback"

# sourcing must never be able to abort the script
hard_source="$(grep -rln 'source /usr/local/lib/palworld-notify$' "$REPO"/sbin "$REPO"/lib 2>/dev/null | while IFS= read -r f; do basename "$f"; done | tr '\n' ' ')"
assert_eq "${hard_source% }" "" "no script sources the helper without tolerating its absence"

# --- behavioural: scripts that call notify early must not die on 127 ---------
if [ -e /usr/local/lib/palworld-notify ]; then
  echo "  (skipping behavioural checks: palworld-notify IS installed on this host)"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  mkdir -p "$WORK/bin"
  # fake s6-svc so the container branch of graceful-stop can run
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/s6-svc"
  chmod +x "$WORK/bin/s6-svc"

  # The contract: a missing notify helper must never be the thing that breaks a
  # script. (These scripts may still fail for real reasons — e.g. the tool they
  # wrap isn't installed on this host either — which is correct.)
  notify_is_silent() {
    local label="$1"; shift
    local out
    out="$("$@" 2>&1)"
    assert_not_contains "$out" "palworld_notify" "$label: notify never surfaces as an error"
    assert_not_contains "$out" "palworld-notify: No such file" "$label: missing helper is tolerated"
  }

  # these call palworld_notify within the first few lines
  notify_is_silent "api-save" bash "$REPO/sbin/palworld-api-save"
  notify_is_silent "api-stop" bash "$REPO/sbin/palworld-api-stop"
  notify_is_silent "backup"   bash "$REPO/sbin/palworld-backup"

  # graceful-stop's container path has no other missing dependency, so it must
  # complete successfully with no notify helper at all.
  out="$(env PATH="$WORK/bin:$PATH" PALWARDEN_CONTAINER=1 bash "$REPO/sbin/palworld-graceful-stop" 2>&1)"; rc=$?
  assert_eq "$rc" "0" "graceful-stop (container) succeeds without the notify helper"
  assert_not_contains "$out" "palworld_notify" "graceful-stop: notify never surfaces as an error"
fi

assert_report
