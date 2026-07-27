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
#
# Read this as a DELETION TRIPWIRE, not a behavioural test: it proves the call is
# made, not that it is made with the right uid. Running unprivileged, the only
# uid available is our own, so a _preserve_owner that chowned to the *wrong* uid
# would pass here too. The observable properties live in the symlink/FIFO blocks
# below, which is where the actual security behaviour is pinned down.
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

# --- the queue directory is hostile: root must not be redirected out of it ----
# The unprivileged web user OWNS this directory, so it can plant a symlink, a
# hardlink or a FIFO at any name the root worker is about to touch. Each block
# below was a live local-root escalation before the O_EXCL/O_NOFOLLOW guards.

# 1. a symlink at the temp name must not redirect root's write.
# The temp name now carries a random suffix, so an attacker cannot *find* it —
# but the security property is the O_CREAT|O_EXCL|O_NOFOLLOW open, not the
# unguessable name. Pin the random part so the collision is reproducible and the
# kernel's refusal is what we observe.
reset
out="$(py '
import os, secrets, pathlib
import palwarden_jobs as j
real = secrets.token_hex
secrets.token_hex = lambda n: "deadbeef" if n == 4 else real(n)
victim = j.JOBS_DIR.parent / "victim"
victim.parent.mkdir(parents=True, exist_ok=True)
victim.write_text("SECRET")
job = j.create_job("backup", {})
path = j.job_path(job["id"])
tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}.deadbeef")
os.symlink(victim, tmp)
try:
    j.update_job(job["id"], state="running")
    print("FOLLOWED")
except OSError as exc:
    print("refused" if victim.read_text() == "SECRET" else "CLOBBERED")
' 2>&1)"
assert_eq "$out" "refused" "a symlink at the temp name is refused, not followed"

# 2. a symlink at <id>.json must not get its TARGET chowned.
# _preserve_owner used a following os.stat, so root read the uid off the target
# and then fchowned that inode: "enqueue any job, get /etc/shadow chowned to me".
# Observable without changing uid because the fix skips the syscall entirely.
reset
out="$(py '
import os
import palwarden_jobs as j
job = j.create_job("backup", {})
path = j.job_path(job["id"])
target = j.JOBS_DIR.parent / "target"
target.write_text("{}")
path.unlink()
os.symlink(target, path)
calls = []
real = os.fchown
os.fchown = lambda fd, uid, gid: calls.append((uid, gid)) or real(fd, uid, gid)
fd = os.open(target, os.O_RDONLY)
try:
    j._preserve_owner(fd, path)
finally:
    os.close(fd)
print("no-chown" if calls == [] else "CHOWNED %r" % (calls,))')"
assert_eq "$out" "no-chown" "_preserve_owner does not chown a symlink's target"

# 3. the read path refuses a job file that is not a regular file.
# Without O_NOFOLLOW root read_text()s whatever the link points at and treats it
# as a job; without O_NONBLOCK+S_ISREG a FIFO blocks the read forever, which
# stalls the worker's entire poll loop (not a disclosure, a permanent stop).
reset
out="$(py '
import os, json
import palwarden_jobs as j
job = j.create_job("backup", {})
path = j.job_path(job["id"])
decoy = j.JOBS_DIR.parent / "decoy.json"
decoy.write_text(json.dumps(dict(j.read_job(job["id"]), action="graceful_stop")))
path.unlink(); os.symlink(decoy, path)
assert j.read_job(job["id"]) is None, "read followed the symlink"
assert j.list_jobs() == [], j.list_jobs()
assert j.has_pending() is False
print("ok")')"
assert_eq "$out" "ok" "a symlinked job file reads as absent, not as its target"

reset
# The FIFO check runs under a hard timeout: the pre-fix failure mode is a HANG
# (the worker's poll loop never returns), which without an alarm would stall the
# whole suite instead of failing it.
out="$(py '
import os, signal
import palwarden_jobs as j
job = j.create_job("backup", {})
path = j.job_path(job["id"])
path.unlink(); os.mkfifo(path)
signal.alarm(5)
print("refused" if j.read_job(job["id"]) is None else "PARSED")
signal.alarm(0)' 2>&1)"
assert_eq "$out" "refused" "a FIFO job file is refused without blocking"

# ...and the S_ISREG check specifically, on the primitive rather than through
# read_job. read_job maps every refusal to None, so it cannot distinguish "we
# refused this on sight" from "the read happened to fail anyway" — a FIFO with no
# writer yields EAGAIN and a directory yields EISDIR, so dropping the check would
# leave read_job returning None either way and the assertion above green. What
# must not happen is root getting as far as *reading* a non-regular file it was
# handed (a FIFO with a writer attached feeds it whatever job it likes), so assert
# on the refusal itself.
reset
out="$(py '
import os
import palwarden_jobs as j
job = j.create_job("backup", {})
path = j.job_path(job["id"])
results = []
for kind, make in (("fifo", os.mkfifo), ("dir", os.mkdir)):
    p = path.with_name(f"{kind}{path.name}")
    make(p)
    try:
        j._read_job_text(p)
        results.append(f"{kind}:READ")
    except ValueError as exc:
        results.append(f"{kind}:refused" if "regular file" in str(exc) else f"{kind}:{exc}")
    except OSError as exc:
        results.append(f"{kind}:oserror-{exc.errno}")
print(" ".join(results))')"
assert_eq "$out" "fifo:refused dir:refused" "the read primitive refuses non-regular files on sight"

# 4. an owner outside the allowed set is refused on both paths.
# The real scenario needs three accounts (the web user chmods the queue 0777, a
# third account drops a file in, or hardlinks one owned by someone else) and root
# to observe it, so neither is available in an unprivileged suite. What IS
# testable — and what the previous version got wrong by not having it at all — is
# that the validation is *wired into both paths*: stub the allowed set to one that
# excludes our own uid and both the read and the chown must decline.
reset
out="$(py '
import os
import palwarden_jobs as j
job = j.create_job("backup", {})
path = j.job_path(job["id"])
j._allowed_owner_uids = lambda: {31337}
calls = []
real = os.fchown
os.fchown = lambda fd, uid, gid: calls.append((uid, gid)) or real(fd, uid, gid)
assert j.read_job(job["id"]) is None, "read accepted a disallowed owner"
fd = os.open(path, os.O_RDONLY)
try:
    j._preserve_owner(fd, path)
finally:
    os.close(fd)
print("refused" if calls == [] else "CHOWNED %r" % (calls,))' 2>/dev/null)"
assert_eq "$out" "refused" "a job file owned by neither root nor the queue owner is refused"

# ...and the allowed set itself, not just its wiring. The stub above proves both
# call sites consult it, but would pass just as green against a validator that
# returned every uid on the box, or one that had quietly lost root (which would
# make the worker refuse every job it had ever updated). On a queue directory we
# own there are exactly two legitimate owners: root and us.
reset
out="$(py '
import os
import palwarden_jobs as j
j.create_job("backup", {})   # creates the queue directory
print("ok" if j._allowed_owner_uids() == {0, os.getuid()} else
      "WRONG %r" % (sorted(j._allowed_owner_uids()),))')"
assert_eq "$out" "ok" "the allowed owner set is exactly root plus the queue directory owner"

# --- an oversized queue entry is refused, not read into root memory --------
# The web user owns the queue directory, so it can put any regular file at
# <id>.json — and every list_jobs() in the worker's poll loop reads each one
# whole. read_text() was unbounded and so was its replacement; the cap makes a
# planted multi-gigabyte file a refusal instead of root's RSS. Tested a little
# over the limit rather than with a real giant file: the assertion is about the
# check, and a 4 GiB fixture would be a worse test, not a better one.
reset
out="$(py '
import palwarden_jobs as j
job = j.create_job("backup", {})
path = j.job_path(job["id"])
with path.open("wb") as fh:
    fh.write(b"{}" + b" " * (j.MAX_JOB_BYTES + 1))
try:
    j._read_job_text(path)
    print("READ")
except ValueError as exc:
    print("refused" if "limit" in str(exc) else "other: %s" % exc)
# ...and read_job treats the refusal as "absent" like every other one, so a
# planted file cannot make a state update raise instead of skipping it.
print("absent" if j.read_job(job["id"]) is None else "PARSED")
print("listed %d" % len(j.list_jobs()))')"
assert_eq "$out" "refused
absent
listed 0" "an over-limit job file is refused by the read primitive and treated as absent"

# A job at the padded-but-legal size still reads, so the cap is a ceiling and not
# an accidental refusal of ordinary jobs (whose largest field, output, is capped
# at OUTPUT_LIMIT = 256 KiB — well inside it).
reset
out="$(py '
import palwarden_jobs as j
job = j.create_job("backup", {})
j.append_output(job["id"], "x" * (j.OUTPUT_LIMIT + 1000))
got = j.read_job(job["id"])
print("ok" if got is not None and len(got["output"]) > 100000 else "REFUSED %r" % (got,))')"
assert_eq "$out" "ok" "a job with the maximum permitted output still reads back"

assert_report
