#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden-webui: auth on every path (the static editors included), safe static
# serving, and the read-only API. Uses stub tools so no real server is needed.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
WEBUI="$DIR/../../sbin/palwarden-webui"

WORK="$(mktemp -d)"
PORT=18099
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture: web root, credentials, stub tools ---------------------------
mkdir -p "$WORK/webroot" "$WORK/sbin" "$WORK/cfg"
echo '<html><body>PALWARDEN DASHBOARD</body></html>' > "$WORK/webroot/palwarden.html"
echo '<html>vendored editor</html>' > "$WORK/webroot/PalWorldSettingsEditor.html"
echo 'SECRET-HOST-FILE' > "$WORK/secret-outside-webroot.txt"

printf 'WEBUI_USER="admin"\nWEBUI_PASSWORD="pw-for-tests"\nWEBUI_TOKEN="tok-for-tests"\n' \
  > "$WORK/webui.env"

cat > "$WORK/sbin/palworld-health-report" <<'EOF'
#!/usr/bin/env bash
echo '{"service":{"active_state":"active"},"buildid":"12345"}'
EOF
cat > "$WORK/sbin/palworld-fps" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$WORK/fps-argv.log"
echo '{"windows":{"24h":{"avg":59.5}}}'
EOF
cat > "$WORK/sbin/palworld-service-events" <<'EOF'
#!/usr/bin/env bash
echo '{"restarts":2,"unexpected":1,"outages":0}'
EOF
cat > "$WORK/sbin/palworld-engine-config" <<'EOF'
#!/usr/bin/env bash
echo "Engine.ini check OK: managed values match /etc/palworld/engine.env."
EOF
cat > "$WORK/sbin/palworld-broken-tool" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2; exit 3
EOF
chmod +x "$WORK/sbin/"*

# a config file with a secret to prove redaction
printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(ServerName="Ygg",AdminPassword="hunter-would-be-bad",PublicPort=8211)\n' \
  > "$WORK/cfg/PalWorldSettings.ini"

# --- start the server ------------------------------------------------------
PALWARDEN_WEBUI_ENV="$WORK/webui.env" \
PALWARDEN_WEBUI_ROOT="$WORK/webroot" \
PALWARDEN_WEBUI_BIND=127.0.0.1 \
PALWARDEN_WEBUI_PORT="$PORT" \
PALWARDEN_SBIN_DIR="$WORK/sbin" \
PALWARDEN_JOBS_DIR="$WORK/jobs" \
PALWARDEN_PARSER_BIN="$DIR/../../bin/palworld-config-parser" \
PALWORLD_CONFIG_FILE="$WORK/cfg/PalWorldSettings.ini" \
  python3 "$WEBUI" --serve >"$WORK/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.25
done

U="http://127.0.0.1:$PORT"
CREDS="admin:pw-for-tests"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }

# --- auth is required for EVERYTHING, static pages included ---------------
assert_eq "$(code "$U/")" "401" "dashboard requires auth"
assert_eq "$(code "$U/PalWorldSettingsEditor.html")" "401" "vendored editor requires auth"
assert_eq "$(code "$U/api/health")" "401" "API requires auth"
hdrs="$(curl -s -D - -o /dev/null "$U/")"
assert_contains "$hdrs" "WWW-Authenticate" "sends a Basic challenge"
assert_eq "$(code -u "admin:wrong-password" "$U/")" "401" "wrong password rejected"
assert_eq "$(code -u "wrong-user:pw-for-tests" "$U/")" "401" "wrong user rejected"

# --- authenticated static serving -----------------------------------------
assert_eq "$(code -u "$CREDS" "$U/")" "200" "authenticated root is served"
assert_contains "$(body -u "$CREDS" "$U/")" "PALWARDEN DASHBOARD" "root serves the dashboard"
assert_eq "$(code -u "$CREDS" "$U/PalWorldSettingsEditor.html")" "200" "editor is served"

# --- traversal must not escape the web root -------------------------------
# --path-as-is stops curl from normalising ".." client-side, so the raw path
# (with the literal traversal sequence) actually reaches the server.
assert_ne "$(code --path-as-is -u "$CREDS" "$U/../secret-outside-webroot.txt")" "200" "no parent traversal"
assert_not_contains "$(body --path-as-is -u "$CREDS" "$U/../secret-outside-webroot.txt")" "SECRET-HOST-FILE" "traversal leaks nothing"
assert_ne "$(code -u "$CREDS" "$U/..%2fsecret-outside-webroot.txt")" "200" "no encoded traversal"
assert_eq "$(code -u "$CREDS" "$U/does-not-exist.html")" "404" "missing file is 404"

# --- read API --------------------------------------------------------------
assert_eq "$(code -u "$CREDS" "$U/api/health")" "200" "health is served"
assert_contains "$(body -u "$CREDS" "$U/api/health")" '"buildid"' "health returns tool JSON"
assert_contains "$(body -u "$CREDS" "$U/api/fps?window=24h")" '"avg"' "fps returns tool JSON"
assert_contains "$(body -u "$CREDS" "$U/api/service-events")" '"unexpected"' "service events returned"
assert_contains "$(body -u "$CREDS" "$U/api/engine")" '"drift_ok"' "engine drift reported"

# config is redacted
cfg="$(body -u "$CREDS" "$U/api/config")"
assert_contains "$cfg" '"ServerName"' "config exposes normal keys"
assert_contains "$cfg" "<redacted>" "config redacts secrets"
assert_not_contains "$cfg" "hunter-would-be-bad" "the admin password never leaves the host"

# a rejected window falls back rather than passing junk to the tool
assert_eq "$(code -u "$CREDS" "$U/api/fps?window=;rm%20-rf%20/")" "200" "hostile window is sanitised"
# prove it, rather than trusting the 200: the stub records its real argv, so we
# can check the LAST invocation (not just that some earlier, legitimate call
# happened to use 24h) actually received the sanitised fallback, not the raw
# hostile string.
last_fps_argv="$(tail -n 1 "$WORK/fps-argv.log")"
assert_contains "$last_fps_argv" "--window 24h" "hostile window becomes the sanitised fallback in the tool's argv"
assert_not_contains "$last_fps_argv" "rm -rf" "hostile window string never reaches the tool"

# a tool that exits non-zero with empty stdout must surface as ok:false, not a
# silently-successful empty payload (the dashboard's error path depends on this
# — see run_tool_json). Swap the health-report stub for the broken-tool
# fixture (which prints nothing on stdout and exits 3) and re-check /api/health.
cp "$WORK/sbin/palworld-broken-tool" "$WORK/sbin/palworld-health-report"
broken="$(body -u "$CREDS" "$U/api/health")"
assert_contains "$broken" '"ok": false' "a tool that exits non-zero with empty stdout reports ok:false"


# --- mutations need more than Basic auth ----------------------------------
# The full job API lives in tests/unit/test_webui_jobs.sh; here we only pin the
# invariant this suite is about: authentication alone never mutates anything.
assert_eq "$(code -u "$CREDS" -X POST "$U/api/jobs")" "403" \
  "POST /api/jobs needs the token header, not just Basic auth"

# --- nothing sensitive in the log ----------------------------------------
assert_not_contains "$(cat "$WORK/server.log")" "pw-for-tests" "password never logged"
assert_not_contains "$(cat "$WORK/server.log")" "tok-for-tests" "token never logged"

# --- the real dashboard page is what gets served at / ---------------------
REAL_ROOT="$DIR/../../webui"
assert_rc 0 test -f "$REAL_ROOT/palwarden.html"
assert_file_contains "$REAL_ROOT/palwarden.html" 'id="palwarden-dashboard"' "has the dashboard root element"
assert_file_contains "$REAL_ROOT/palwarden.html" "/api/health" "fetches health"
# The token assertion belongs on the page that actually sends it. The dashboard is
# read-only (GET /api/jobs takes Basic alone), so it holds no token at all; this
# assertion used to sit here and only passed because a since-deleted helper
# mentioned sessionStorage. Asserting on real code, not on a comment:
assert_rc 0 grep -qE 'sessionStorage\.getItem\(' "$REAL_ROOT/EngineIniPerformanceEditor.html" \
  "the editor reads its token from sessionStorage"
assert_file_not_contains "$REAL_ROOT/EngineIniPerformanceEditor.html" "localStorage" \
  "the token never goes in persistent storage"
# the shared component vocabulary from the design spec, so later pages can reuse it
assert_file_contains "$REAL_ROOT/palwarden.html" "--pw-bg" "declares the design tokens"
assert_file_contains "$REAL_ROOT/palwarden.html" "pw-card" "uses the card component"
assert_file_contains "$REAL_ROOT/palwarden.html" "pw-pill--ok" "uses state pills"
# it must not ship a hardcoded credential
assert_file_not_contains "$REAL_ROOT/palwarden.html" "WEBUI_PASSWORD" "no credential baked into the page"
# and the vendored editor must remain byte-identical, so upstream syncs stay
# trivial and the MIT attribution stays clean. Only PalWorldSettingsEditor.html
# is genuinely vendored; EngineIniPerformanceEditor.html is first-party (it
# references engine.env, palworld-engine-config and current/Engine.ini, none of
# which exist upstream) and carries our own SPDX header, so it is deliberately
# NOT pinned here — it owns the control-plane Save buttons. See the design spec,
# "Editing Engine.ini from the browser", and tests/unit/test_webui_jobs.sh.
assert_rc 0 git -C "$DIR/../.." diff --quiet -- webui/PalWorldSettingsEditor.html

# --- payloadError() handles the API's {ok: false} convention ---------------
# The API reports tool failures as HTTP 200 with {ok: false, error: "..."} so
# one broken tool doesn't blank the whole dashboard. Extract the real
# payloadError() function from the page and exercise it under node, rather
# than trusting a source grep.
if command -v node >/dev/null 2>&1; then
  PE_JS="$WORK/payloadError.js"
  awk '/^function payloadError/{f=1} f{print} f && /^}/{exit}' "$REAL_ROOT/palwarden.html" > "$PE_JS"
  cat >> "$PE_JS" <<'EOF'

let failures = 0;
function check(desc, cond) { if (!cond) { failures++; console.log("FAIL: " + desc); } }
check("ok:false carries the error message", (payloadError({ok: false, error: "boom"}) || "").includes("boom"));
check("null payload is an error", typeof payloadError(null) === "string" && payloadError(null).length > 0);
check("ok:true is usable", payloadError({ok: true, data: {}}) === null);
console.log(failures === 0 ? "OK" : "FAIL");
EOF
  pe_out="$(node "$PE_JS" 2>&1)"
  assert_eq "$pe_out" "OK" "payloadError() extracted from the page behaves correctly under node"
else
  fail "node not found; cannot exercise payloadError()"
fi

# --- job status on the dashboard (Task 6) ----------------------------------
# GET /api/jobs is a read: it must work with Basic auth alone, no token.
assert_eq "$(code -u "$CREDS" "$U/api/jobs")" "200" "job list readable with Basic auth alone, no token"
empty_jobs="$(body -u "$CREDS" "$U/api/jobs")"
assert_contains "$empty_jobs" '"ok": true' "empty job list still uses the API envelope"
assert_contains "$empty_jobs" '"data": []' "no jobs yet is an empty data array"

# Plant job files directly in the queue directory, in the same shape
# palwarden_jobs.create_job()/update_job() write (see lib/palwarden_jobs.py).
# One has HTML in its output: output is whatever the invoked tool printed, so
# it is exactly as attacker-influenceable as the error/blocked_by strings the
# existing structural guard (tests/unit/test_webui_jobs.sh) already checks,
# and it is the fixture that would actually catch a regression to innerHTML.
mkdir -p "$WORK/jobs"
python3 - "$WORK/jobs" <<'EOF'
import json, pathlib, sys
jobs_dir = pathlib.Path(sys.argv[1])
jobs_dir.mkdir(parents=True, exist_ok=True)

def plant(job_id, seq, action, state, output):
    job = {
        "id": job_id, "action": action, "params": {}, "state": state,
        "created_at": 1000, "seq": seq, "started_at": 1000,
        "finished_at": 1000 if state in ("succeeded", "failed") else None,
        "exit_code": 0 if state == "succeeded" else None,
        "output": output,
    }
    (jobs_dir / f"{job_id}.json").write_text(json.dumps(job, indent=2, sort_keys=True))

plant("a" * 32, 1, "backup", "succeeded", "backup ok\n")
# newest (highest seq): the one the dashboard's "most recent" logic must pick
plant("b" * 32, 2, "engine_save", "succeeded",
      "applied\n<img src=x onerror=alert(1)>\n")
EOF

listing="$(body -u "$CREDS" "$U/api/jobs")"
assert_contains "$listing" '"action": "engine_save"' "planted job appears in the list"
assert_contains "$listing" '<img src=x onerror=alert(1)>' \
  "the raw HTML in output is served as JSON, unescaped (the page must neutralise it, not the API)"

# --- renderJobsText()/jobIsUnfinished() extracted from the real page --------
# A grep proving id="jobs" exists is weak; run the page's own pure rendering
# and polling-continuation logic under node against fixture payloads,
# including the HTML-bearing job above, and check what it actually produces.
if command -v node >/dev/null 2>&1; then
  JOBS_JS="$WORK/renderJobs.js"
  {
    grep '^const JOBS_UNFINISHED' "$REAL_ROOT/palwarden.html"
    awk '/^function jobIsUnfinished/{f=1} f{print} f && /^}/{exit}' "$REAL_ROOT/palwarden.html"
    awk '/^function renderJobsText/{f=1} f{print} f && /^}/{exit}' "$REAL_ROOT/palwarden.html"
  } > "$JOBS_JS"
  cat >> "$JOBS_JS" <<'EOF'

let failures = 0;
function check(desc, cond) { if (!cond) { failures++; console.log("FAIL: " + desc); } }

// no jobs: a pw-empty placeholder, not a blank region
const none = renderJobsText([]);
check("no jobs yields the empty placeholder text", none.text === "No jobs yet");
check("no jobs marks empty:true", none.empty === true);

// most recent (list[0]) is what's shown; action/state/output-tail all present,
// and the HTML in output comes through as literal text, not parsed.
const htmlJob = { id: "b".repeat(32), action: "engine_save", state: "succeeded",
                   output: "applied\n<img src=x onerror=alert(1)>\n" };
const oldJob = { id: "a".repeat(32), action: "backup", state: "succeeded", output: "backup ok\n" };
const rendered = renderJobsText([htmlJob, oldJob]);
check("renders the action", rendered.text.indexOf("engine_save") !== -1);
check("renders the state", rendered.text.indexOf("succeeded") !== -1);
check("renders the output tail", rendered.text.indexOf("applied") !== -1);
check("HTML in output survives as literal text (proves it is a plain string, not markup)",
      rendered.text.indexOf("<img src=x onerror=alert(1)>") !== -1);
check("not marked empty when a job exists", rendered.empty === false);

// polling continuation: queued/running keep polling; every job terminal stops
check("queued is unfinished", jobIsUnfinished({ state: "queued" }) === true);
check("running is unfinished", jobIsUnfinished({ state: "running" }) === true);
check("succeeded is finished", jobIsUnfinished({ state: "succeeded" }) === false);
check("failed is finished", jobIsUnfinished({ state: "failed" }) === false);
check("a list with one unfinished job keeps polling",
      [{ state: "succeeded" }, { state: "running" }].some(jobIsUnfinished) === true);
check("a list where every job is terminal stops polling",
      [{ state: "succeeded" }, { state: "failed" }].some(jobIsUnfinished) === false);

console.log(failures === 0 ? "OK" : "FAIL");
EOF
  jobs_out="$(node "$JOBS_JS" 2>&1)"
  assert_eq "$jobs_out" "OK" "renderJobsText()/jobIsUnfinished() extracted from the dashboard behave correctly"
elif [ -n "${CI:-}" ]; then
  # As with payloadError() above: silently skipping this would delete the
  # dashboard's only behavioural coverage of its job rendering without anyone
  # noticing.
  fail "node is required in CI to execute renderJobsText()/jobIsUnfinished()"
else
  echo "  (skipping the node checks of renderJobsText()/jobIsUnfinished(): node not found)" >&2
fi

# --- the tested functions are actually wired into the page -------------------
# renderJobsText()/jobIsUnfinished() are extracted and executed above, which
# proves the logic but not that the page reaches it: deleting the pollJobs() call
# or mistyping the element id would leave every assertion green while the
# dashboard silently never showed a job.
DASH="$DIR/../../webui/palwarden.html"
assert_file_contains "$DASH" 'id="jobs"' "the dashboard has the job region the renderer targets"
assert_rc 0 grep -qE '^pollJobs\(\);' "$DASH" "the dashboard starts polling for jobs at load"
assert_rc 0 grep -qE "text\('jobs'|text\(\"jobs\"" "$DASH" \
  "job text reaches the DOM through the guarded text() helper"

assert_report
