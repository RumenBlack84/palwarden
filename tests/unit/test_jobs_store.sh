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
# The store is a directory: a block that asserts on "all jobs" or "pending
# jobs" must start from an empty one, or it inherits state left behind by
# earlier blocks (which intentionally leave jobs queued/running to test that).
reset() { rm -rf "$WORK/jobs"; }

# --- create / read round-trip ---------------------------------------------
reset
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
reset
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
reset
out="$(py '
import palwarden_jobs as j
print("none" if j.read_job("0"*32) is None else "something")')"
assert_eq "$out" "none" "unknown id reads as None"

# --- claim_next takes the oldest queued job exactly once ------------------
reset
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
reset
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
reset
out="$(py '
import palwarden_jobs as j
job = j.create_job("backup", {})
assert j.has_pending() is True
j.update_job(job["id"], state="succeeded", exit_code=0)
assert j.has_pending() is False
print("ok")')"
assert_eq "$out" "ok" "has_pending tracks unfinished work only"

# --- prune removes old finished jobs, keeps unfinished ones ---------------
reset
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

# --- a corrupt job file does not crash readers ----------------------------
# Two distinct corruption modes: invalid JSON (valid UTF-8) and invalid UTF-8
# bytes (json.loads never even gets to parse it). Both must read as absent.
reset
out="$(py '
import palwarden_jobs as j
job = j.create_job("backup", {})
j.job_path(job["id"]).write_text("{not json")
assert j.read_job(job["id"]) is None
assert job["id"] not in [x["id"] for x in j.list_jobs()]
assert j.has_pending() is False
print("ok")')"
assert_eq "$out" "ok" "invalid-JSON job file is ignored, not fatal"

reset
out="$(py '
import palwarden_jobs as j
job = j.create_job("backup", {})
j.job_path(job["id"]).write_bytes(b"\xff\xfe\x00bad")
assert j.read_job(job["id"]) is None
assert job["id"] not in [x["id"] for x in j.list_jobs()]
assert j.has_pending() is False
print("ok")')"
assert_eq "$out" "ok" "invalid-UTF-8 job file is ignored, not fatal"

# --- an update keeps the creator's ownership -------------------------------
# The web process creates the file and must keep being able to read it; the root
# worker rewrites the same job on every state change, and the atomic replace
# makes a new inode. Without the fchown the job becomes root-owned and the web UI
# answers "unknown job" for work it queued itself. Cannot be tested by actually
# changing uid unprivileged, so assert the syscall happens with the *existing*
# owner (the same result root gets).
reset
out="$(py '
import os
import palwarden_jobs as j
calls = []
real = os.fchown
os.fchown = lambda fd, uid, gid: calls.append((uid, gid)) or real(fd, uid, gid)
job = j.create_job("backup", {})
assert calls == [], "no owner to preserve on create: %r" % (calls,)
st = os.stat(j.job_path(job["id"]))
j.update_job(job["id"], state="running")
assert calls == [(st.st_uid, st.st_gid)], (calls, st.st_uid, st.st_gid)
assert j.read_job(job["id"])["state"] == "running"
print("ok")')"
assert_eq "$out" "ok" "update preserves the job file's owner"

assert_report
