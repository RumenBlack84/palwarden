# Web UI control plane, increments 2+3: job queue, root worker, Engine.ini save/apply — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the browser change server configuration and restart the server, without the browser-facing process ever holding privilege.

**Architecture:** The unprivileged `palwarden-webui` gains `POST /api/jobs`, which authenticates, validates, and writes a **job file** — it never executes anything. A new **root** worker, `palwarden-jobd`, watches the queue, re-validates each job against a hardcoded allowlist, runs it, and records status and output. The Engine.ini editor gets **Save** (writes `engine.env`) and **Save and apply** (writes, applies, graceful restart, behind a confirmation).

**Tech Stack:** Python 3 standard library only. Bash + `tests/lib/assert.sh` for tests. systemd (bare metal) and s6-overlay (container).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-26-webui-control-plane-design.md`. Read its
  `## API`, `## Job queue`, `### Actions`, `### Editing Engine.ini from the browser`
  and `### Component vocabulary` sections.
- **Python 3 standard library only.** No new image dependencies.
- **The web process must never gain privilege.** It writes job files and nothing
  more. If a task seems to need `sudo` or root in `palwarden-webui`, the design is
  being violated — stop and escalate.
- **`palwarden-jobd` must never trust the queue file.** It re-validates the action
  name and every parameter itself, because another process wrote that file.
- **No user string ever reaches a shell.** Every action is a fixed argv list with
  typed, validated slots. No `shell=True`, no string interpolation into commands.
- **Mutations require both** valid HTTP Basic auth **and** the `WEBUI_TOKEN` in the
  `X-Palwarden-Token` header; plus `Origin`/`Sec-Fetch-Site` rejection of cross-site
  requests. Basic alone must never be sufficient for a mutation (that is the CSRF
  defence). The token has its own header because Basic already occupies
  `Authorization`; a custom header is equally CSRF-safe (see the spec's
  `## Authentication and hardening` item 2).
- **Disruptive actions additionally require `"confirm": true`** in the request body.
- New first-party scripts carry `# SPDX-License-Identifier: AGPL-3.0-or-later` and
  `# SPDX-FileCopyrightText: 2026 Brian Grant`.
- **`webui/PalWorldSettingsEditor.html` must stay byte-identical** (genuine vendored
  MIT). `webui/EngineIniPerformanceEditor.html` is first-party and MAY be edited;
  give it an HTML-comment header noting AGPL and partial derivation from the MIT
  upstream (see `CREDITS.md`).
- Host-portable: every path an env override with a bare-metal-preserving default.
- Notifications stay optional (`palworld_notify` no-ops when absent).
- Every task ends green: `./tests/lint.sh` and `./tests/run.sh` pass.
- Commit messages end with a blank line then
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Do not push to any remote. The owner reviews locally.

## Interfaces that already exist (increment 1)

In `sbin/palwarden-webui`:
- `WEBUI_ENV`, `REQUIRED_KEYS`, `load_credentials(path) -> dict[str,str]` (fails
  closed, no traceback), `init_credentials(path) -> (dict, bool)`.
- `check_basic(header, creds) -> bool` — byte-wise `hmac.compare_digest`.
- `run_tool(argv, timeout) -> dict` / `run_tool_json(argv, timeout) -> dict`
  returning `{"ok": bool, ...}`; non-zero exits with unusable stdout become
  `{"ok": False, "error": ...}`.
- `READ_ENDPOINTS: dict[str, Callable[[dict], dict]]`, `Handler` (with
  `_send_json`, `_challenge`, `_authenticated`, `do_GET`, `do_POST` currently
  returning 501), `make_server(creds)`.
- Constants `SBIN`, `PARSER_BIN`, `CONFIG_FILE`, `BIND`, `PORT`, `WEB_ROOT`.

`/etc/palworld/webui.env` is `root:<service group>` mode `0640`: the web process
reads it, only root writes it. `palwarden-jobd` runs as root and reads the same
file to learn `WEBUI_TOKEN` if it ever needs to (it does not need to today —
authentication happens in the web process).

## File Structure

| File | Responsibility |
|---|---|
| `lib/palwarden_jobs.py` (create) | Shared job store: id generation/validation, atomic create/read/update, listing, pruning. Imported by both processes so the on-disk contract has exactly one implementation. |
| `sbin/palwarden-jobd` (create) | Root worker: claim, re-validate, execute, record. Owns the action allowlist. |
| `sbin/palwarden-webui` (modify) | `POST /api/jobs` (auth + CSRF + validation + enqueue), `GET /api/jobs`, `GET /api/jobs/<id>`. |
| `webui/EngineIniPerformanceEditor.html` (modify) | Save / Save-and-apply controls, confirmation dialog, job progress. |
| `webui/palwarden.html` (modify) | Show the current/last job in the existing job log region. |
| `systemd/palwarden-jobd.service` (create) | Bare-metal supervision (root). |
| `docker/s6-rc.d/jobd/{type,run,timeout-kill}` (create) | Container supervision (root). |
| `docker/entrypoint.sh`, `install.sh` (modify) | Enable/point at the worker; create the queue directory. |
| `tests/unit/test_jobs_store.py`… | see per-task test files below. |

---

### Task 1: Shared job store

**Files:**
- Create: `lib/palwarden_jobs.py`
- Test: `tests/unit/test_jobs_store.sh`

**Interfaces produced** (both later tasks depend on these exact names):
```python
JOBS_DIR: Path                      # PALWARDEN_JOBS_DIR, default /var/lib/palworld/jobs
JOB_ID_RE                           # compiled ^[0-9a-f]{32}$
STATES = ("queued", "running", "succeeded", "failed")
OUTPUT_LIMIT = 262144               # 256 KiB

def new_job_id() -> str
def job_path(job_id: str) -> Path           # raises ValueError on a bad id
def create_job(action: str, params: dict) -> dict
def read_job(job_id: str) -> dict | None
def list_jobs(limit: int = 50) -> list[dict]
def update_job(job_id: str, **fields) -> dict
def append_output(job_id: str, text: str) -> dict   # truncates at OUTPUT_LIMIT
def claim_next() -> dict | None             # oldest queued -> running, or None
def prune(max_age_days: int = 7) -> int
def has_pending(action_filter=None) -> bool  # any queued/running job
```
Job dict fields: `id, action, params, state, created_at, started_at, finished_at,
exit_code, output` (epoch ints for times, `None` when unset).

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_jobs_store.sh`:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# The job store is the contract between the unprivileged web process (which only
# writes job files) and the root worker (which only reads them), so its rules are
# load-bearing: ids must not be able to traverse paths, and a crafted id must be
# refused rather than resolved.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
LIB="$DIR/../../lib"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

py() { PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "$1"; }

# --- create / read round-trip ---------------------------------------------
out="$(py '
import palwarden_jobs as j
job = j.create_job("backup", {})
assert j.JOB_ID_RE.match(job["id"]), job["id"]
assert job["state"] == "queued", job
got = j.read_job(job["id"])
assert got["action"] == "backup", got
assert got["params"] == {}, got
print("ok")')"
assert_eq "$out" "ok" "create/read round-trip"

# --- ids cannot traverse --------------------------------------------------
for bad in '../../etc/passwd' 'x/y' 'UPPER0000000000000000000000000000' 'short' ''; do
  out="$(py "
import palwarden_jobs as j
try:
    j.job_path('$bad'); print('ACCEPTED')
except ValueError:
    print('rejected')" 2>/dev/null)"
  assert_eq "$out" "rejected" "rejects id '$bad'"
done

# --- read_job on an unknown id is None, not an error ----------------------
out="$(py '
import palwarden_jobs as j
print("none" if j.read_job("0"*32) is None else "something")')"
assert_eq "$out" "none" "unknown id reads as None"

# --- claim_next takes the oldest queued job exactly once ------------------
out="$(py '
import palwarden_jobs as j, time
a = j.create_job("backup", {})
time.sleep(0.01)
b = j.create_job("config_pretty", {})
first = j.claim_next()
assert first["id"] == a["id"], (first, a)
assert first["state"] == "running", first
second = j.claim_next()
assert second["id"] == b["id"], (second, b)
assert j.claim_next() is None
print("ok")')"
assert_eq "$out" "ok" "claim_next is FIFO and drains"

# --- output is captured and capped ----------------------------------------
out="$(py '
import palwarden_jobs as j
job = j.create_job("backup", {})
j.append_output(job["id"], "x" * (j.OUTPUT_LIMIT + 5000))
got = j.read_job(job["id"])
assert len(got["output"]) <= j.OUTPUT_LIMIT + 200, len(got["output"])
assert "truncated" in got["output"], got["output"][-100:]
print("ok")')"
assert_eq "$out" "ok" "output capped with a truncation marker"

# --- has_pending sees queued and running, not finished --------------------
out="$(py '
import palwarden_jobs as j
job = j.create_job("backup", {})
assert j.has_pending() is True
j.update_job(job["id"], state="succeeded", exit_code=0)
assert j.has_pending() is False
print("ok")')"
assert_eq "$out" "ok" "has_pending tracks unfinished work only"

# --- prune removes old finished jobs, keeps unfinished ones ---------------
out="$(py '
import palwarden_jobs as j, time
old = j.create_job("backup", {})
j.update_job(old["id"], state="succeeded", exit_code=0, finished_at=int(time.time()) - 8*86400)
keep = j.create_job("backup", {})
removed = j.prune(max_age_days=7)
assert removed == 1, removed
assert j.read_job(old["id"]) is None
assert j.read_job(keep["id"]) is not None
print("ok")')"
assert_eq "$out" "ok" "prune drops old finished jobs only"

# --- a corrupt job file does not crash readers ---------------------------
out="$(py '
import palwarden_jobs as j
from pathlib import Path
job = j.create_job("backup", {})
j.job_path(job["id"]).write_text("{not json")
assert j.read_job(job["id"]) is None
assert j.list_jobs() == [] or all(isinstance(x, dict) for x in j.list_jobs())
print("ok")')"
assert_eq "$out" "ok" "corrupt job file is ignored, not fatal"

assert_report
```

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/unit/test_jobs_store.sh
bash tests/unit/test_jobs_store.sh
```
Expected: FAIL — `ModuleNotFoundError: No module named 'palwarden_jobs'`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/palwarden_jobs.py`:

```python
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
"""Shared job store for the palwarden web UI control plane.

The unprivileged web process only ever *writes* job files; the root worker only
ever *reads* them. That one-way boundary is the security property the whole
control plane rests on, so the on-disk format lives here — one implementation,
imported by both sides, rather than two that can drift apart.

Job ids are validated on every path construction: the id arrives from an HTTP
request, so `job_path("../../etc/passwd")` must raise rather than resolve.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import time
from pathlib import Path

JOBS_DIR = Path(os.environ.get("PALWARDEN_JOBS_DIR", "/var/lib/palworld/jobs"))
JOB_ID_RE = re.compile(r"^[0-9a-f]{32}$")
STATES = ("queued", "running", "succeeded", "failed")
OUTPUT_LIMIT = 262144
TRUNCATION_MARKER = "\n[output truncated at 256 KiB]\n"


def new_job_id() -> str:
    return secrets.token_hex(16)


def job_path(job_id: str) -> Path:
    """Path for a job id, refusing anything that is not a bare 32-hex id."""
    if not isinstance(job_id, str) or not JOB_ID_RE.match(job_id):
        raise ValueError(f"invalid job id: {job_id!r}")
    return JOBS_DIR / f"{job_id}.json"


def _write(job: dict) -> dict:
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    path = job_path(job["id"])
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(job, indent=2, sort_keys=True))
    tmp.replace(path)
    return job


def create_job(action: str, params: dict) -> dict:
    job = {
        "id": new_job_id(),
        "action": action,
        "params": params or {},
        "state": "queued",
        "created_at": int(time.time()),
        "started_at": None,
        "finished_at": None,
        "exit_code": None,
        "output": "",
    }
    return _write(job)


def read_job(job_id: str) -> dict | None:
    """Return the job, or None when it is missing or unreadable.

    A corrupt file is treated as absent: a half-written or hand-edited job must
    not take down the reader.
    """
    try:
        path = job_path(job_id)
    except ValueError:
        return None
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def list_jobs(limit: int = 50) -> list[dict]:
    if not JOBS_DIR.is_dir():
        return []
    jobs = []
    for path in JOBS_DIR.glob("*.json"):
        job = read_job(path.stem)
        if job is not None:
            jobs.append(job)
    jobs.sort(key=lambda j: j.get("created_at") or 0, reverse=True)
    return jobs[:limit]


def update_job(job_id: str, **fields) -> dict:
    job = read_job(job_id)
    if job is None:
        raise KeyError(job_id)
    job.update(fields)
    return _write(job)


def append_output(job_id: str, text: str) -> dict:
    job = read_job(job_id)
    if job is None:
        raise KeyError(job_id)
    combined = (job.get("output") or "") + text
    if len(combined) > OUTPUT_LIMIT:
        combined = combined[:OUTPUT_LIMIT] + TRUNCATION_MARKER
    job["output"] = combined
    return _write(job)


def claim_next() -> dict | None:
    """Move the oldest queued job to running and return it."""
    queued = [j for j in list_jobs(limit=1000) if j.get("state") == "queued"]
    if not queued:
        return None
    queued.sort(key=lambda j: j.get("created_at") or 0)
    job = queued[0]
    return update_job(job["id"], state="running", started_at=int(time.time()))


def has_pending(action_filter=None) -> bool:
    for job in list_jobs(limit=1000):
        if job.get("state") not in ("queued", "running"):
            continue
        if action_filter is None or job.get("action") in action_filter:
            return True
    return False


def prune(max_age_days: int = 7) -> int:
    cutoff = time.time() - max_age_days * 86400
    removed = 0
    for job in list_jobs(limit=1000):
        if job.get("state") not in ("succeeded", "failed"):
            continue
        finished = job.get("finished_at") or job.get("created_at") or 0
        if finished < cutoff:
            try:
                job_path(job["id"]).unlink()
                removed += 1
            except (OSError, ValueError):
                pass
    return removed
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_jobs_store.sh
./tests/lint.sh
```
Expected: `0 failed`, `LINT PASSED`.

- [ ] **Step 5: Commit**

```bash
git add lib/palwarden_jobs.py tests/unit/test_jobs_store.sh
git commit -m "Add the shared job store for the web UI control plane

One implementation of the on-disk job contract, imported by both the unprivileged
web process (which only writes jobs) and the root worker (which only reads them),
so the two sides cannot drift apart. Job ids are validated on every path
construction because they arrive from HTTP; a corrupt job file reads as absent
rather than taking down the reader; output is capped at 256 KiB."
```

---

### Task 2: The root worker

**Files:**
- Create: `sbin/palwarden-jobd`
- Test: `tests/unit/test_jobd.sh`

**Interfaces consumed:** everything from `lib/palwarden_jobs.py` (Task 1).

**Interfaces produced:**
```python
ACTIONS: dict[str, dict]   # name -> {"argv": callable(params)->list[list[str]], "disruptive": bool}
def validate_params(action: str, params: dict) -> tuple[dict | None, str | None]
def build_commands(action: str, params: dict) -> list[list[str]]
def run_job(job: dict) -> int      # returns the exit code recorded
def reap_orphans() -> int          # running -> failed on startup
def main() -> int                  # --once for tests, otherwise poll loop
```
The action names and parameter rules are exactly the spec's `### Actions` tables,
plus `engine_save` and `engine_save_apply_restart`.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_jobd.sh`:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# The worker holds root, and its only input is a file written by a process we
# treat as untrusted. So it re-validates everything: unknown actions, hostile
# parameters and hand-edited job files must all be refused, and no parameter may
# ever reach a shell.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
JOBD="$DIR/../../sbin/palwarden-jobd"
LIB="$DIR/../../lib"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/jobs" "$WORK/bin" "$WORK/etc"

# stub tools that record their argv so we can prove nothing was mangled
for tool in palworld-backup palworld-config-pretty palworld-config-apply-env \
            palworld-config-snapshot palworld-engine-config palworld-graceful-restart \
            palworld-fps; do
  cat > "$WORK/bin/$tool" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$0") \$*" >> "$WORK/argv.log"
echo "ran \$(basename "\$0")"
EOF
  chmod +x "$WORK/bin/$tool"
done

jobd() {
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" \
  PALWARDEN_SBIN_DIR="$WORK/bin" PALWORLD_ENGINE_ENV="$WORK/etc/engine.env" \
    python3 "$JOBD" "$@"
}
enqueue() {  # enqueue <action> <json-params>
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import json, sys, palwarden_jobs as j
print(j.create_job(sys.argv[1], json.loads(sys.argv[2]))['id'])" "$1" "$2"
}
state_of() {
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import sys, palwarden_jobs as j
job = j.read_job(sys.argv[1]); print(job['state'] if job else 'missing')" "$1"
}
output_of() {
  PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import sys, palwarden_jobs as j
job = j.read_job(sys.argv[1]); print((job or {}).get('output',''))" "$1"
}

# --- a simple file-only action succeeds -----------------------------------
id="$(enqueue backup '{}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "backup job succeeds"
assert_contains "$(output_of "$id")" "ran palworld-backup" "captures tool output"

# --- an unknown action is refused by the WORKER, not just the API ---------
id="$(enqueue definitely_not_an_action '{}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "unknown action fails"
assert_contains "$(output_of "$id")" "not an allowed action" "explains the refusal"

# --- hostile parameters are rejected, never passed through ----------------
: > "$WORK/argv.log"
id="$(enqueue snapshot_create '{"label": "; rm -rf /"}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "hostile label rejected"
assert_file_not_contains "$WORK/argv.log" "rm -rf" "hostile label never reached a command"

id="$(enqueue graceful_restart '{"wait": 999999, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "out-of-range wait rejected"

# --- a valid label IS passed through, exactly ----------------------------
: > "$WORK/argv.log"
id="$(enqueue snapshot_create '{"label": "before-tuning_2"}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "valid label accepted"
assert_file_contains "$WORK/argv.log" "create before-tuning_2" "label passed verbatim"

# --- engine_save writes engine.env from validated pairs ------------------
id="$(enqueue engine_save '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60", "MAX_CLIENT_RATE": "100000"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "engine_save succeeds"
assert_file_contains "$WORK/etc/engine.env" "NET_SERVER_MAX_TICK_RATE=60" "wrote the tick rate"
assert_file_contains "$WORK/etc/engine.env" "MAX_CLIENT_RATE=100000" "wrote the client rate"

# unknown key and out-of-range value are both refused
id="$(enqueue engine_save '{"settings": {"NOT_A_SETTING": "1"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "unknown engine setting rejected"
id="$(enqueue engine_save '{"settings": {"NET_SERVER_MAX_TICK_RATE": "9999"}}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "out-of-range tick rate rejected"

# --- the composite action runs its steps in order and stops on failure ----
: > "$WORK/argv.log"
id="$(enqueue engine_save_apply_restart '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60"}, "wait": 30, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "succeeded" "composite action succeeds"
log="$(cat "$WORK/argv.log")"
assert_contains "$log" "palworld-engine-config apply" "applied the config"
assert_contains "$log" "palworld-graceful-restart" "restarted the server"
apply_line="$(grep -n 'engine-config apply' "$WORK/argv.log" | cut -d: -f1 | head -1)"
restart_line="$(grep -n 'graceful-restart' "$WORK/argv.log" | cut -d: -f1 | head -1)"
if [ "$apply_line" -lt "$restart_line" ]; then pass; else fail "apply must run before restart"; fi

# a failing apply must NOT reach the restart
cat > "$WORK/bin/palworld-engine-config" <<'EOF'
#!/usr/bin/env bash
echo "apply exploded" >&2; exit 7
EOF
chmod +x "$WORK/bin/palworld-engine-config"
: > "$WORK/argv.log"
id="$(enqueue engine_save_apply_restart '{"settings": {"NET_SERVER_MAX_TICK_RATE": "60"}, "wait": 30, "confirm": true}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "composite fails when apply fails"
assert_file_not_contains "$WORK/argv.log" "graceful-restart" "no restart after a failed apply"

# --- disruptive actions require confirm ---------------------------------
id="$(enqueue graceful_restart '{"wait": 30}')"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "disruptive action without confirm is refused"

# --- a hand-edited job file is refused ----------------------------------
id="$(enqueue backup '{}')"
PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import sys, json, palwarden_jobs as j
p = j.job_path(sys.argv[1]); d = json.loads(p.read_text())
d['action'] = 'graceful_restart'; d['params'] = {}
p.write_text(json.dumps(d))" "$id"
jobd --once >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "tampered action is re-validated and refused"

# --- orphaned running jobs are reaped on startup ------------------------
id="$(enqueue backup '{}')"
PALWARDEN_JOBS_DIR="$WORK/jobs" PYTHONPATH="$LIB" python3 -c "
import sys, palwarden_jobs as j
j.update_job(sys.argv[1], state='running')" "$id"
jobd --reap >/dev/null 2>&1
assert_eq "$(state_of "$id")" "failed" "orphaned running job marked failed"
assert_contains "$(output_of "$id")" "did not finish" "explains the orphaning"

assert_report
```

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/unit/test_jobd.sh
bash tests/unit/test_jobd.sh
```
Expected: FAIL — `can't open file '.../sbin/palwarden-jobd'`.

- [ ] **Step 3: Write minimal implementation**

Create `sbin/palwarden-jobd`. Key rules to implement:

- Import the store: prepend `/usr/local/lib` and the repo's `lib/` to `sys.path`
  (mirror how `palworld-health-report` locates `palworld-fps`), then
  `import palwarden_jobs as jobs`.
- `ENGINE_ENV = Path(os.environ.get("PALWORLD_ENGINE_ENV", "/etc/palworld/engine.env"))`,
  `SBIN = Path(os.environ.get("PALWARDEN_SBIN_DIR", "/usr/local/sbin"))`.
- Load the engine setting definitions from `palworld-engine-config` by module
  loading (as `palworld-health-report` loads `palworld-fps`) so the 15 settings,
  their types and their min/max live in exactly one place: use its
  `SETTING_BY_ENV` and `normalize_value`. Env override:
  `PALWARDEN_ENGINE_CONFIG_BIN`, default `SBIN / "palworld-engine-config"`.
- Validators:
  - `label`: `re.fullmatch(r"[A-Za-z0-9._-]{1,64}", value)`
  - `text`: length ≤ 200 and `value.isprintable()`
  - `wait`: `isinstance(value, int) and 0 <= value <= 1800` (reject `bool`)
  - `dry_run`: `isinstance(value, bool)`
  - `backup`: must be a name (no `/`) that exists in the backup directory
  - `settings`: a dict whose every key is in `SETTING_BY_ENV` and whose every
    value passes that setting's `normalize_value` (catch `ValueError` → reject).
    Store the **normalised** values.
- `ACTIONS` maps each name to the commands it runs and whether it is disruptive:
  `config_apply`, `engine_apply`, `config_pretty`, `snapshot_create`, `backup`,
  `mark` (file-only); `graceful_restart`, `graceful_stop`, `update_check`,
  `update_apply`, `engine_rollback`, `api_save`, `engine_save_apply_restart`
  (disruptive). `engine_save` is file-only and runs **no** command — it writes
  `engine.env` itself.
- Disruptive actions require `params.get("confirm") is True`, re-checked here.
- `engine_save` writes `ENGINE_ENV` atomically: a generated header comment, then
  `KEY=value` lines for the normalised settings, mode `0644`, then re-reads it to
  confirm it parses. It must not destroy an existing file on failure (temp +
  rename).
- `run_job`: for each command in sequence, `subprocess.run(argv, capture_output=True,
  text=True, timeout=1800)`, append stdout+stderr to the job, and **stop at the
  first non-zero exit**; record `exit_code` and `state`.
- `reap_orphans`: any `running` job at startup becomes `failed` with output
  `"worker restarted; this job did not finish"`.
- `main`: `--reap` reaps and exits; `--once` reaps, claims one job, runs it, prunes,
  exits; default loops with a `flock` on `PALWARDEN_JOBD_LOCK`
  (default `/run/palwarden-jobd.lock`), sleeping `PALWARDEN_JOBD_INTERVAL`
  (default `2`) seconds between polls, so only one worker ever runs.
- Never use `shell=True`. Never interpolate a parameter into a string that reaches
  a shell.
- Notifications: `palworld_notify` is not available from Python; skip notifying
  here — the invoked tools already notify.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_jobd.sh
./tests/lint.sh
./tests/run.sh
```
Expected: `0 failed` in the new suite, `LINT PASSED`, all suites pass.

- [ ] **Step 5: Commit**

```bash
git add sbin/palwarden-jobd tests/unit/test_jobd.sh
git commit -m "Add palwarden-jobd, the privileged job worker

Runs as root and treats its queue as untrusted input: it re-validates the action
name and every parameter itself, refuses anything not on its allowlist, and builds
fixed argv lists so no parameter can reach a shell. Engine setting names, types and
ranges come from palworld-engine-config's own definitions rather than a second copy.
Composite actions stop at the first failure, so a failed apply never reaches a
restart, and jobs left running by a crash are reaped as failed on startup."
```

---

### Task 3: `POST /api/jobs` with CSRF-resistant authentication

**Files:**
- Modify: `sbin/palwarden-webui`
- Test: `tests/unit/test_webui_jobs.sh`

**Interfaces produced:**
- `check_token(headers, creds) -> bool` — constant-time compare of `WEBUI_TOKEN`
  against the `X-Palwarden-Token` header.
- `origin_ok(headers) -> bool` — rejects `Sec-Fetch-Site: cross-site`/`same-site`
  and any `Origin` that is not this server's.
- `POST /api/jobs` → `202 {"id": ...}` / `400` / `403` / `409`.
- `GET /api/jobs` → `{"ok": true, "data": [...]}`; `GET /api/jobs/<id>` →
  `{"ok": true, "data": {...}}` or `404`.
- The web process validates the same way the worker does, by importing the
  worker's validators — the API rejects bad input early, the worker rejects it
  again because it must not trust the queue.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_webui_jobs.sh` covering, against a server started as in
`tests/unit/test_webui_server.sh` (reuse that fixture pattern — stub tools, a
credential file with `WEBUI_USER="admin"`, `WEBUI_PASSWORD="pw-for-tests"`,
`WEBUI_TOKEN="tok-for-tests"`, and `PALWARDEN_JOBS_DIR` pointed at a temp dir):

```bash
# Basic auth alone must NOT be enough to mutate — this is the CSRF defence.
assert_eq "$(code -u "$CREDS" -X POST -H 'Content-Type: application/json' \
  -d '{"action":"backup"}' "$U/api/jobs")" "403" "Basic alone cannot enqueue"

# With the token header it works and returns a job id.
body="$(curl -s -u "$CREDS" -H "X-Palwarden-Token: tok-for-tests" \
  -H 'Content-Type: application/json' -d '{"action":"backup"}' "$U/api/jobs")"
assert_contains "$body" '"id"' "token header enqueues"

# A wrong token is refused.
assert_eq "$(code -u "$CREDS" -H 'X-Palwarden-Token: wrong' -X POST \
  -H 'Content-Type: application/json' -d '{"action":"backup"}' "$U/api/jobs")" "403" \
  "wrong token refused"

# No credentials at all is 401, not 403.
assert_eq "$(code -X POST -d '{"action":"backup"}' "$U/api/jobs")" "401" "no auth is 401"

# A cross-site request is refused even with both credentials.
assert_eq "$(code -u "$CREDS" -H "X-Palwarden-Token: tok-for-tests" \
  -H 'Sec-Fetch-Site: cross-site' -X POST -H 'Content-Type: application/json' \
  -d '{"action":"backup"}' "$U/api/jobs")" "403" "cross-site request refused"
assert_eq "$(code -u "$CREDS" -H "X-Palwarden-Token: tok-for-tests" \
  -H 'Origin: http://evil.example' -X POST -H 'Content-Type: application/json' \
  -d '{"action":"backup"}' "$U/api/jobs")" "403" "foreign Origin refused"

# Unknown action, malformed body, and hostile params are 400.
assert_eq "$(post_json '{"action":"nope"}')" "400" "unknown action rejected"
assert_eq "$(post_json 'not json')" "400" "malformed body rejected"
assert_eq "$(post_json '{"action":"snapshot_create","params":{"label":"; rm -rf /"}}')" "400" \
  "hostile label rejected at the API"

# A disruptive action without confirm is refused; with confirm it is accepted.
assert_eq "$(post_json '{"action":"graceful_restart","params":{"wait":30}}')" "400" \
  "disruptive action needs confirm"
assert_eq "$(post_json '{"action":"graceful_restart","params":{"wait":30,"confirm":true}}')" "202" \
  "confirmed disruptive action accepted"

# A second pending disruptive job is refused with 409.
assert_eq "$(post_json '{"action":"graceful_restart","params":{"wait":30,"confirm":true}}')" "409" \
  "only one pending disruptive job at a time"

# Job status is readable, and a crafted id cannot traverse.
assert_eq "$(code -u "$CREDS" "$U/api/jobs")" "200" "job list readable"
assert_eq "$(code -u "$CREDS" "$U/api/jobs/$(printf '0%.0s' $(seq 32))")" "404" "unknown job is 404"
assert_eq "$(code -u "$CREDS" "$U/api/jobs/..%2f..%2fetc%2fpasswd")" "404" "crafted job id refused"

# The token must never appear in the log.
assert_not_contains "$(cat "$WORK/server.log")" "tok-for-tests" "token never logged"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/unit/test_webui_jobs.sh
bash tests/unit/test_webui_jobs.sh
```
Expected: FAIL — `POST /api/jobs` currently returns `501`.

- [ ] **Step 3: Write minimal implementation**

In `sbin/palwarden-webui`:
- Import the store and the worker's validators (module-load `palwarden-jobd` the
  same way it module-loads the parser) so validation rules exist once.
- `check_token`: read `X-Palwarden-Token`; compare bytes with
  `hmac.compare_digest` (encode with `errors="ignore"`-free strict handling as
  `check_basic` does, so a non-ASCII header cannot raise). A missing header is a
  refusal, not an error.
- `origin_ok`: reject when `Sec-Fetch-Site` is present and not `same-origin`; reject
  when `Origin` is present and its host:port is not this server's.
- `do_POST` on `/api/jobs`: require `_authenticated()`, then `check_token`, then
  `origin_ok` (403 for either failure), read `Content-Length`-bounded body (cap 64
  KiB), parse JSON (400 on failure), validate action+params via the shared
  validators (400 with the reason), refuse a second pending disruptive job (409),
  then `jobs.create_job(...)` and return `202 {"id": ...}`.
- `GET /api/jobs` and `/api/jobs/<id>` via the store; unknown or invalid id → 404.
- Ensure the job directory exists and is writable by this process at startup; if it
  is not, `POST` must fail with a clear 500 rather than a traceback.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_webui_jobs.sh
./tests/lint.sh && ./tests/run.sh
```

- [ ] **Step 5: Commit**

```bash
git add sbin/palwarden-webui tests/unit/test_webui_jobs.sh
git commit -m "Accept validated jobs over POST /api/jobs

Mutations require Basic auth plus the token in X-Palwarden-Token, which a
cross-origin page cannot set without a preflight we never grant, and cross-site Origin or
Sec-Fetch-Site is refused outright. The web process validates with the worker's own
validators so bad input is rejected early, while the worker still re-validates
because it must not trust the queue. Only one disruptive job may be pending."
```

---

### Task 4: Platform wiring for the worker

**Files:**
- Create: `systemd/palwarden-jobd.service`, `docker/s6-rc.d/jobd/{type,run,timeout-kill}`
- Modify: `docker/entrypoint.sh`, `install.sh`, `docker/Dockerfile`
- Test: extend `tests/integration/test_docker.sh`

Requirements:
- The systemd unit runs `palwarden-jobd` as **root**, `Restart=on-failure`,
  `RestartSec=5`. No `ProtectSystem=strict` — the worker must write
  `/etc/palworld/engine.env`, the server config, and `/var/lib/palworld`.
- The s6 service runs it as **root** (no `s6-setuidgid`), like `memory-watch`.
- The entrypoint enables `jobd` in embedded mode and creates
  `/var/lib/palworld/jobs` owned by the **web** user (the web process writes there;
  root reads and updates), mode `0700`.
- `install.sh` creates the same directory owned by the service account.
- The Dockerfile chmods the new run script (its `chmod +x` list is explicit).
- Integration scenario: enqueue `snapshot_create` through the API with both
  credentials, poll `/api/jobs/<id>` until it leaves `queued`/`running`, assert
  `succeeded`; assert `palwarden-jobd` runs as root while `palwarden-webui` runs as
  the unprivileged user; assert a `POST` with Basic only returns 403.

- [ ] **Step 1: Write the failing integration assertions** (append before
  `assert_report` in `tests/integration/test_docker.sh`, modelled on scenario I).
- [ ] **Step 2: Run** `RUN_INTEGRATION=1 bash tests/integration/test_docker.sh` and
  confirm the new assertions fail (no `jobd` service exists yet).
- [ ] **Step 3: Implement** the unit, the s6 service, the entrypoint and installer
  changes, and the Dockerfile chmod entry.
- [ ] **Step 4: Run** `./tests/lint.sh`, `./tests/run.sh`, and
  `RUN_INTEGRATION=1 ./tests/run.sh` — all green. Clean up containers.
- [ ] **Step 5: Commit** with a message explaining the privilege split.

---

### Task 5: Engine.ini editor gains Save and Save-and-apply

**Files:**
- Modify: `webui/EngineIniPerformanceEditor.html`
- Modify: `tests/unit/test_webui_server.sh` (narrow the byte-identical assertion)
- Test: extend `tests/unit/test_webui_jobs.sh`

Requirements:
- Add an HTML-comment header: AGPL identifier, `2026 Brian Grant`, and one line
  noting it is derived in part from the MIT upstream (see `CREDITS.md`).
- **Narrow the existing test assertion** that both editors are byte-identical so it
  covers only `webui/PalWorldSettingsEditor.html`. `EngineIniPerformanceEditor.html`
  is first-party (see the spec's `### Editing Engine.ini from the browser`).
- Two controls, using the spec's vocabulary (`pw-btn`, `pw-btn--danger`,
  `pw-confirm`, `pw-toast`, and the existing `--pw-*` tokens — add them to this page
  consistently with `palwarden.html`):
  - **Save** → `POST /api/jobs {"action":"engine_save","params":{"settings":{...}}}`
  - **Save and apply** → `pw-confirm` dialog naming the action and the player
    warning window; on confirm, `POST` `engine_save_apply_restart` with
    `settings`, `wait`, `confirm: true`.
- The settings object is built from the editor's existing form state — the same
  key/value pairs it already writes into its generated `engine.env` text. Send only
  keys the user has actually set.
- Send the token in `X-Palwarden-Token` from `sessionStorage`; if absent, prompt once for the
  token and store it. Never persist it beyond the session, never log it.
- Poll `GET /api/jobs/<id>` while `queued`/`running`; show progress in a `pw-log`
  region and the outcome in a `pw-toast` (errors persist until dismissed,
  successes auto-clear). Disable both buttons while a job is unfinished.
- Insert all job output with `textContent`, never `innerHTML`.
- Keyboard: the confirm dialog traps focus and Esc cancels.
- Unit test additions: assert the page contains both controls, sends
  `X-Palwarden-Token`, uses `pw-confirm` for the disruptive path, and that
  `PalWorldSettingsEditor.html` is still byte-identical.

- [ ] **Step 1: Write the failing assertions.**
- [ ] **Step 2: Run and confirm they fail.**
- [ ] **Step 3: Implement the controls.**
- [ ] **Step 4:** `./tests/lint.sh`, `./tests/run.sh`, and a manual check against
  the running review container (`docker cp` the page in, click both paths, confirm
  a real `engine.env` write and a real restart).
- [ ] **Step 5: Commit.**

---

### Task 6: Surface jobs on the dashboard

**Files:**
- Modify: `webui/palwarden.html`
- Test: extend `tests/unit/test_webui_server.sh`

Requirements: the existing `pw-log` region shows the most recent job — action,
state, and output tail — polled from `GET /api/jobs` while anything is unfinished.
`pw-empty` when there are none ("No jobs yet"). No new classes. `textContent` only.
Keep `payloadError` top-level and byte-identical in behaviour (the node test
extracts it).

- [ ] **Step 1–5:** same TDD cycle; commit.

---

## Self-Review

**Spec coverage.** Job file format, id validation, one-at-a-time execution, output
cap, pruning, orphan reaping → Task 1 + Task 2. Worker re-validation and the action
allowlist → Task 2. Basic+token+Origin on mutations, `confirm` for disruptive, 409
for a second pending disruptive job, job status endpoints → Task 3. Both platforms
running the worker as root while the web process stays unprivileged → Task 4.
`engine_save`, `engine_save_apply_restart`, and the two controls → Task 2 + Task 5.
Job visibility → Task 5 + Task 6.

**Deliberately deferred:** the remaining spec actions are implemented in the worker
(Task 2) but only Engine.ini gets UI controls; buttons for backup/snapshot/update
are a later UI pass. `pw-toast`/`pw-confirm` land in the Engine editor first and
move to a shared `palwarden.css` when a second page needs them, per the spec's
"extract at the second consumer" rule.

**Type consistency.** `create_job` returns the job dict used by `read_job`,
`update_job`, `claim_next` and `list_jobs`. `validate_params` returns
`(normalised_params | None, error | None)` and both the API and the worker consume
that pair. `build_commands` returns `list[list[str]]` — a list of argv lists —
which `run_job` iterates in order, matching the composite action's requirement.

**Resolved before execution:** Basic and Bearer cannot share the `Authorization`
header, so the token travels in `X-Palwarden-Token` throughout. That is equally
CSRF-safe — the preflight requirement, not the scheme name, is what an attacker
cannot satisfy. The spec was amended to match, so plan and spec agree.
