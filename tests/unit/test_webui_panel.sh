#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# The browser tier for the idle/knock panel (Task 9): the ACTUALLY SERVED
# dashboard is loaded into jsdom and driven with real clicks against a real
# palwarden-webui, asserting both the wire (captured request bodies) and the
# rendered success/error states. The static endpoint tests live in
# test_webui_jobs.sh; this suite exists because those cannot prove the page
# itself behaves.
#
# Honest scope: jsdom is not a real browser engine (no layout, no CSS cascade
# effects), and chromium/playwright are unavailable on the test hosts — so the
# real-browser tier is recorded as BLOCKED, not complete, and this is the
# strongest tier that runs here. Skips (does not fail) when node or jsdom is
# missing; the node-extraction tier in test_webui_jobs.sh stays the
# CI-enforced page-behaviour gate.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
REPO="$DIR/../.."
WEBUI="$REPO/sbin/palwarden-webui"

WORK="$(mktemp -d)"
JOBS="$WORK/queue/jobs"
LCS="$WORK/lifecycle-state"
PORT=18094
U="http://127.0.0.1:$PORT"
CREDS="admin:pw-for-tests"
PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- fixture: same shape as test_webui_jobs.sh, but the REAL page -----------
mkdir -p "$WORK/webroot" "$WORK/sbin" "$WORK/cfg" "$WORK/backups" "$JOBS"
cp "$REPO/webui/palwarden.html" "$REPO/webui/palwarden-ui.css" \
   "$REPO/webui/palwarden-ui.js" "$WORK/webroot/"

printf 'WEBUI_USER="admin"\nWEBUI_PASSWORD="pw-for-tests"\nWEBUI_TOKEN="tok-for-tests"\n' \
  > "$WORK/webui.env"
cat > "$WORK/sbin/palworld-health-report" <<'EOF'
#!/usr/bin/env bash
echo '{"service":{"active_state":"active"}}'
EOF
chmod +x "$WORK/sbin/"*
printf '[/Script/Pal.PalGameWorldSettings]\nOptionSettings=(ServerName="Ygg",RESTAPIEnabled=True)\n' \
  > "$WORK/cfg/PalWorldSettings.ini"
# The on-disk format is JSON-quoted values (ops.parse_file); write the
# fixture the same shape write_config produces.
printf 'IDLE_TIMEOUT="0"\nIDLE_CHECK_INTERVAL="60"\nKNOCK_ENABLED="true"\nKNOCK_COOLDOWN="600"\nKNOCK_TOKEN=""\n' \
  > "$WORK/ops.env"

PALWARDEN_WEBUI_ENV="$WORK/webui.env" \
PALWARDEN_WEBUI_ROOT="$WORK/webroot" \
PALWARDEN_WEBUI_BIND=127.0.0.1 \
PALWARDEN_WEBUI_PORT="$PORT" \
PALWARDEN_JOBS_DIR="$JOBS" \
PALWARDEN_SBIN_DIR="$WORK/sbin" \
PALWARDEN_PARSER_BIN="$REPO/bin/palworld-config-parser" \
PALWORLD_CONFIG_FILE="$WORK/cfg/PalWorldSettings.ini" \
PALWORLD_ENGINE_ENV="$WORK/engine.env" \
PALWORLD_BACKUP_DIR="$WORK/backups" \
PALWARDEN_OPS_FILE="$WORK/ops.env" \
PALWORLD_GROUP="$(id -gn)" \
PALWARDEN_LIFECYCLE_STATE_DIR="$LCS" \
PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
  python3 "$WEBUI" --serve >"$WORK/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null "$U/" && break
  sleep 0.25
done

# --- tier gate ---------------------------------------------------------------
# The served page must be the real one before jsdom is even worth starting;
# these two assertions run whether or not the jsdom tier executes.
assert_eq "$(curl -s -o /dev/null -w '%{http_code}' -u "$CREDS" "$U/palwarden.html")" \
  "200" "the real dashboard is served"
assert_contains "$(curl -s -u "$CREDS" "$U/palwarden.html")" \
  'id="ops-form"' "the served page carries the ops panel"

# assert_report does not exit, so the skip is a branch around the scenario,
# never an early report. The gate resolves jsdom from "$WORK" — the same
# directory the scenario runs in — so node's upward node_modules walk cannot
# make the gate and the run disagree about availability.
skip_jsdom=""
if ! command -v node >/dev/null 2>&1; then
  skip_jsdom="node not found"
elif ! (cd "$WORK" && NODE_PATH="${PALWARDEN_NODE_MODULES:-${NODE_PATH:-}}" \
          node -e 'require.resolve("jsdom")' >/dev/null 2>&1); then
  skip_jsdom="jsdom not found; set PALWARDEN_NODE_MODULES to a node_modules directory containing it"
fi
if [ -n "$skip_jsdom" ]; then
  echo "  (skipping the jsdom panel tier: $skip_jsdom)" >&2
else

cat > "$WORK/panel.js" <<'NODEEOF'
// Drive the actually-served dashboard in jsdom against the real webui server.
// The fetch bridge is the browser seam: it adds the Basic session the browser
// already holds (jsdom has no credential prompt), volunteers the same
// Origin/Sec-Fetch-Site a real same-origin fetch would, records every request
// the page makes, and can drop the CSRF header on demand to exercise the
// unauthorised path. A fake worker completes jobs by rewriting the queue
// files, exactly as jobd would.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { JSDOM, VirtualConsole } = require("jsdom");

const U = process.env.PANEL_URL;
const AUTH = "Basic " + Buffer.from(process.env.PANEL_CREDS).toString("base64");
const JOBS = process.env.PANEL_JOBS;
const OPS = process.env.PANEL_OPS;
const LCS = process.env.PANEL_LCS;
const REPO = process.env.PANEL_REPO;
const TOKEN = "tok-for-tests";

let failures = 0;
function check(desc, cond) {
  if (!cond) { failures++; console.log("FAIL: " + desc); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(desc, fn, ms) {
  ms = ms || 20000;
  const t0 = Date.now();
  for (;;) {
    let v = false;
    try { v = fn(); } catch (e) { v = false; }
    if (v) return true;
    if (Date.now() - t0 > ms) { failures++; console.log("FAIL (timeout): " + desc); return false; }
    await sleep(50);
  }
}

const requests = [];
let dropToken = false;

async function bridge(input, init) {
  init = init || {};
  const url = new URL(typeof input === "string" ? input : input.url, U);
  const headers = Object.assign({}, init.headers || {});
  headers["Authorization"] = AUTH;          // the session a browser already has
  headers["Sec-Fetch-Site"] = "same-origin"; // what a real same-origin fetch sends
  headers["Origin"] = U;
  if (dropToken) delete headers["X-Palwarden-Token"];
  const sent = {};
  for (const k of Object.keys(headers)) sent[k.toLowerCase()] = headers[k];
  requests.push({ method: init.method || "GET", path: url.pathname,
                  headers: sent, body: init.body || null });
  return fetch(url.href, { method: init.method || "GET", headers, body: init.body });
}

function lastRequest(method, pathname) {
  for (let i = requests.length - 1; i >= 0; i--) {
    if (requests[i].method === method && requests[i].path === pathname) return requests[i];
  }
  return null;
}
function jsonBody(req) { try { return JSON.parse(req.body); } catch (e) { return null; } }
function opsFile() { return fs.readFileSync(OPS, "utf8"); }

async function takeJob(action, ms) {
  ms = ms || 15000;
  const t0 = Date.now();
  for (;;) {
    for (const f of fs.readdirSync(JOBS)) {
      if (!f.endsWith(".json")) continue;
      let j = null;
      try { j = JSON.parse(fs.readFileSync(path.join(JOBS, f), "utf8")); } catch (e) { continue; }
      if (j.action === action && j.state === "queued") return j;
    }
    if (Date.now() - t0 > ms) { failures++; console.log("FAIL (timeout): no queued " + action + " job"); return null; }
    await sleep(50);
  }
}
function finishJob(job, ok, output) {
  const p = path.join(JOBS, job.id + ".json");
  const j = JSON.parse(fs.readFileSync(p, "utf8"));
  if (ok && job.action === "palwarden_config_save") {
    // Mirror jobd's execution branch for this action exactly: merge the
    // partial against the CURRENT effective config at execution time and
    // write atomically (spec §7.2). The page tier must observe the same
    // file effects a real worker produces, not a hand-written shortcut.
    execFileSync("python3", ["-c",
      "import json, sys\n" +
      "import palwarden_ops as ops\n" +
      "settings = json.loads(sys.argv[1])\n" +
      "ops.write_config(ops.OPS_FILE, ops.merge(ops.resolve(), settings))\n",
      JSON.stringify(job.params.settings || {})],
      { env: Object.assign({}, process.env,
                           { PYTHONPATH: REPO + "/lib", PALWARDEN_OPS_FILE: OPS }) });
  }
  j.state = ok ? "succeeded" : "failed";
  j.exit_code = ok ? 0 : 3;
  j.output = output;
  j.finished_at = Math.floor(Date.now() / 1000);
  fs.writeFileSync(p, JSON.stringify(j));
}
function jobCount() {
  return fs.readdirSync(JOBS).filter((f) => f.endsWith(".json")).length;
}
function lifecycleWrite(code) {
  execFileSync("python3", ["-c", code], {
    env: Object.assign({}, process.env,
                       { PALWARDEN_LIFECYCLE_STATE_DIR: LCS, PYTHONPATH: REPO + "/lib" }),
  });
}

async function main() {
  // The page under test is fetched from the server, not read from disk: this
  // tier exercises what is actually served.
  const pageRes = await fetch(U + "/palwarden.html", { headers: { Authorization: AUTH } });
  if (pageRes.status !== 200) { console.log("FAIL: served page is HTTP " + pageRes.status); process.exit(1); }
  const html = await pageRes.text();
  if (html.indexOf('id="ops-form"') === -1) { console.log("FAIL: served page lacks the ops panel"); process.exit(1); }

  const vc = new VirtualConsole(); // jsdom internals stay out of the assertion log
  const dom = new JSDOM(html, {
    url: U + "/palwarden.html",
    runScripts: "dangerously",
    pretendToBeVisual: true,
    virtualConsole: vc,
    beforeParse(window) {
      window.fetch = bridge;
      window.confirm = () => true;   // the clear-token confirmation is auto-accepted
      window.prompt = () => null;
      window.URL.createObjectURL = () => "blob:stub";
      window.URL.revokeObjectURL = () => {};
    },
  });
  const win = dom.window;
  const doc = win.document;
  const el = (id) => doc.getElementById(id);
  const fire = (node, type) => node.dispatchEvent(new win.Event(type, { bubbles: true }));
  const setVal = (id, v) => { el(id).value = String(v); fire(el(id), "input"); fire(el(id), "change"); };
  const setCheck = (id, v) => { el(id).checked = v; fire(el(id), "change"); };
  const statusPill = () => el("ops-status-pill").textContent;
  const statusText = () => el("ops-status").textContent;

  // --- phase 1: the panel loads from the API, never from a preloaded secret --
  if (!await waitFor("ops form fills from GET /api/palwarden-config",
                     () => el("ops-idle-interval").value === "60")) { return finish(dom); }
  check("idle timeout prefilled from the ops file", el("ops-idle-timeout").value === "0");
  check("knock prefilled enabled", el("ops-knock-enabled").checked === true);
  check("cooldown prefilled", el("ops-knock-cooldown").value === "600");
  check("the token field is never preloaded", el("ops-knock-token").value === "");
  check("token state reads UNSET", el("ops-token-pill").textContent === "UNSET");
  check("save is disabled with nothing changed", el("ops-save").disabled === true);

  // --- phase 2: edit all five values, save, job succeeds, config reloads -----
  setVal("ops-idle-timeout", 300);
  setVal("ops-idle-interval", 30);
  setCheck("ops-knock-enabled", false);
  setVal("ops-knock-cooldown", 900);
  setVal("ops-knock-token", "first-token-1");
  check("save enables once fields change", el("ops-save").disabled === false);
  el("ops-save").click();
  const j2 = await takeJob("palwarden_config_save");
  if (!j2) return finish(dom);
  const put2 = jsonBody(lastRequest("PUT", "/api/palwarden-config"));
  check("the save PUT carries exactly the five edited keys",
        put2 && JSON.stringify(Object.keys(put2).sort()) ===
          JSON.stringify(["IDLE_CHECK_INTERVAL", "IDLE_TIMEOUT", "KNOCK_COOLDOWN", "KNOCK_ENABLED", "KNOCK_TOKEN"]));
  check("ints ride as numbers and the toggle as a boolean",
        put2 && put2.IDLE_TIMEOUT === 300 && put2.KNOCK_ENABLED === false && put2.IDLE_CHECK_INTERVAL === 30);
  check("the mutation carries the CSRF token header",
        lastRequest("PUT", "/api/palwarden-config").headers["x-palwarden-token"] === TOKEN);
  finishJob(j2, true, "wrote the ops config");
  // The OK pill is set BEFORE the post-save reload finishes; wait for the
  // reload itself (final status line + reloaded field) so no late
  // fillOpsForm can clobber the next phase's edits.
  if (!await waitFor("status shows OK after the save job succeeds",
                     () => statusPill() === "OK" && statusText() === "saved." &&
                           el("ops-idle-timeout").value === "300" &&
                           el("ops-wake").disabled === false)) { return finish(dom); }
  check("the form reloads the effective values",
        el("ops-idle-timeout").value === "300" && el("ops-idle-interval").value === "30" &&
        el("ops-knock-enabled").checked === false && el("ops-knock-cooldown").value === "900");
  check("the token field is blanked again after saving", el("ops-knock-token").value === "");
  check("the token pill flips to CONFIGURED", el("ops-token-pill").textContent === "CONFIGURED");
  check("the ops file carries the new values",
        opsFile().indexOf('IDLE_TIMEOUT="300"') !== -1 &&
        opsFile().indexOf('KNOCK_TOKEN="first-token-1"') !== -1);
  const cfgBody = await (await fetch(U + "/api/palwarden-config", { headers: { Authorization: AUTH } })).text();
  check("GET never echoes the stored token",
        cfgBody.indexOf("first-token-1") === -1 && cfgBody.indexOf('"token_configured": true') !== -1);

  // --- phase 3: keep-by-omission — a blank token field is never a key --------
  setVal("ops-knock-cooldown", 1200);   // token field left blank
  el("ops-save").click();
  const j3 = await takeJob("palwarden_config_save");
  if (!j3) return finish(dom);
  const put3 = jsonBody(lastRequest("PUT", "/api/palwarden-config"));
  check("a blank token field omits KNOCK_TOKEN entirely",
        put3 && JSON.stringify(Object.keys(put3)) === '["KNOCK_COOLDOWN"]');
  finishJob(j3, true, "wrote the ops config");
  if (!await waitFor("status OK after the keep-save",
                     () => statusPill() === "OK" && statusText() === "saved." &&
                           el("ops-knock-cooldown").value === "1200" &&
                           opsFile().indexOf('KNOCK_COOLDOWN="1200"') !== -1 &&
                           el("ops-wake").disabled === false)) { return finish(dom); }
  check("the stored token survived the keep-save", opsFile().indexOf('KNOCK_TOKEN="first-token-1"') !== -1);

  // --- phase 4: a failed job must never render as success --------------------
  setVal("ops-idle-timeout", 600);
  el("ops-save").click();
  const j4 = await takeJob("palwarden_config_save");
  if (!j4) return finish(dom);
  finishJob(j4, false, "stub refusal: disk on fire");
  if (!await waitFor("status shows ERROR after the failed job",
                     () => statusPill() === "ERROR" &&
                           el("ops-clear-token").disabled === false)) { return finish(dom); }
  check("the failure names the exit code", statusText().indexOf("failed (exit 3)") !== -1);
  check("the worker's output reaches the log as text", el("ops-log").textContent.indexOf("stub refusal: disk on fire") !== -1);
  check("no success is claimed for a failed write", statusText().indexOf("saved.") === -1);
  check("the form keeps the typed value (no silent revert)", el("ops-idle-timeout").value === "600");

  // --- phase 5: the explicit clear is its own one-key PUT --------------------
  el("ops-clear-token").click();
  const j5 = await takeJob("palwarden_config_save");
  if (!j5) return finish(dom);
  const put5 = jsonBody(lastRequest("PUT", "/api/palwarden-config"));
  check("the clear PUTs exactly {KNOCK_TOKEN: ''}",
        put5 && JSON.stringify(put5) === '{"KNOCK_TOKEN":""}');
  finishJob(j5, true, "wrote the ops config");
  if (!await waitFor("status OK after the clear",
                     () => statusPill() === "OK" && el("ops-token-pill").textContent === "UNSET" &&
                           statusText().indexOf("knock token cleared") !== -1 &&
                           el("ops-wake").disabled === false)) { return finish(dom); }
  check("the ops file lost the token",
        opsFile().indexOf('KNOCK_TOKEN=""') !== -1 &&
        opsFile().indexOf("first-token-1") === -1);

  // --- phase 6: wake admission is the server's call --------------------------
  setVal("ops-wake-reason", "player at the gate");
  el("ops-wake").click();
  if (!await waitFor("busy wake renders the server's refusal",
                     () => statusPill() === "ERROR" &&
                           el("ops-wake").disabled === false)) { return finish(dom); }
  check("the refusal is the server's own text", statusText().length > 0 && statusText() !== "saved.");
  check("a refused wake queued nothing", jobCount() === 4);  // phases 2-5 made four
  const wakeReq = lastRequest("POST", "/api/jobs");
  const wakeBody = jsonBody(wakeReq);
  check("the wake body is the fixed action with only the reason",
        wakeBody && wakeBody.action === "server_wake" &&
        JSON.stringify(Object.keys(wakeBody.params)) === '["reason"]');
  lifecycleWrite('import palwarden_lifecycle as lc; lc.ensure_state(); lc.write_state("idle", rotate=True)');
  el("ops-wake").click();
  const j6 = await takeJob("server_wake");
  if (!j6) return finish(dom);
  check("the server minted the wake fence itself",
        /^[0-9a-f]{32}$/.test(j6.params.wake_generation || "") &&
        typeof j6.params.wake_expires_at === "number" &&
        j6.params.reason === "player at the gate");
  finishJob(j6, true, "wake complete");
  if (!await waitFor("status OK after the admitted wake",
                     () => statusPill() === "OK" &&
                           el("ops-wake").disabled === false)) { return finish(dom); }
  check("the wake success is stated as a request, not a promise",
        statusText().indexOf("wake job finished") !== -1);

  // --- phase 7: unauthorised mutation surfaces an error, not a success -------
  dropToken = true;
  win.sessionStorage.removeItem("palwarden-token");
  setVal("ops-idle-interval", 45);
  el("ops-save").click();
  if (!await waitFor("the refused PUT surfaces an error",
                     () => statusPill() === "ERROR" &&
                           el("ops-save").disabled === false)) { return finish(dom); }
  check("the page reports the refused API token", statusText().indexOf("refused") !== -1);
  check("the cached token was dropped on 403", win.sessionStorage.getItem("palwarden-token") === null);
  check("the refused PUT really went out without the CSRF header",
        lastRequest("PUT", "/api/palwarden-config").headers["x-palwarden-token"] === undefined);
  dropToken = false;

  // --- phase 8: the server's validator is the single source of truth ---------
  setVal("ops-idle-timeout", 99999);   // out of range; the client does not duplicate the bound
  el("ops-save").click();
  if (!await waitFor("the out-of-range save surfaces the server's 400",
                     () => statusPill() === "ERROR" && statusText().indexOf("out of range") !== -1)) { return finish(dom); }
  check("a refused PUT queued nothing", jobCount() === 5);  // + the admitted wake

  return finish(dom);
}

function finish(dom) {
  dom.window.close();   // stop the page's 15 s refresh / poll timers
  console.log(failures === 0 ? "OK" : "FAIL (" + failures + ")");
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.log("FAIL: scenario crashed: " + (e && e.stack || e));
  process.exit(1);
});
NODEEOF

panel_out="$(PANEL_URL="$U" PANEL_CREDS="$CREDS" PANEL_JOBS="$JOBS" \
             PANEL_OPS="$WORK/ops.env" PANEL_LCS="$LCS" PANEL_REPO="$REPO" \
             PALWARDEN_OPS_FILE="$WORK/ops.env" PALWORLD_GROUP="$(id -gn)" \
             NODE_PATH="${PALWARDEN_NODE_MODULES:-${NODE_PATH:-}}" \
             node "$WORK/panel.js" 2>&1)"
panel_rc=$?
if [ "$panel_rc" -eq 0 ]; then
  pass "the served dashboard drives the full panel scenario in jsdom"
else
  printf '%s\n' "$panel_out" >&2
  printf 'server log tail:\n' >&2
  tail -20 "$WORK/server.log" >&2
  fail "the jsdom panel scenario failed (exit $panel_rc)"
fi

fi   # end of the jsdom-available branch

# ==============================================================================
# F8 (review follow-up): the idle timeout's unit is MINUTES end to end
# (ops validation 0..10080 minutes; the watcher multiplies by 60). The form
# must not label it seconds, and the save path must post the number unchanged.
# ==============================================================================
html="$REPO/webui/palwarden.html"
if grep -q 'Idle timeout (minutes)' "$html"; then
  pass "the idle timeout label says minutes"
else
  fail "the idle timeout label does not say minutes (found: $(grep -o 'Idle timeout ([a-z]*)' "$html" | head -1))"
fi
if grep -q 'many minutes with the last player gone' "$html"; then
  pass "the idle timeout help text speaks minutes"
else
  fail "the idle timeout help text still speaks seconds"
fi
if grep -q 'must be a whole number of' "$html"; then
  pass "the integer validation message names the unit (per field, R7)"
else
  fail "the integer validation message disappeared"
fi
if grep -q 'Idle timeout (seconds)' "$html"; then
  fail "a seconds label for the idle timeout survived"
else
  pass "no seconds label for the idle timeout remains"
fi
# The check interval and cooldown genuinely ARE seconds; do not over-correct.
if grep -q 'Idle check interval (seconds)' "$html"; then
  pass "the check interval keeps its seconds label"
else
  fail "the check interval label was wrongly changed (it is seconds)"
fi

# R7 (Sol review): the numeric-field validation message must name each
# field's real unit — IDLE_TIMEOUT is minutes; IDLE_CHECK_INTERVAL and
# KNOCK_COOLDOWN remain seconds. A blanket "minutes" message is wrong.
if grep -Eq 'IDLE_TIMEOUT.*"minutes"' "$html" \
  && grep -Eq 'IDLE_CHECK_INTERVAL.*"seconds"' "$html" \
  && grep -Eq 'KNOCK_COOLDOWN.*"seconds"' "$html"; then
  pass "R7: validation carries per-field units (timeout=minutes, interval/cooldown=seconds)"
else
  fail "R7: units not field-specific in collectOpsSettings"
fi

assert_report
