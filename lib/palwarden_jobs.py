# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
"""Shared job store for the palwarden web UI control plane.

The unprivileged web process only ever *writes* job files; the root worker only
ever *reads* them. That one-way boundary is the security property the whole
control plane rests on, so the on-disk format lives here — one implementation,
imported by both sides, rather than two that can drift apart.

Job ids are validated on every path construction: the id arrives from an HTTP
request, so `job_path("../../etc/passwd")` must raise rather than resolve.

Job dict fields: `id, action, params, state, created_at, started_at, finished_at,
exit_code, output, seq`.
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


def _preserve_owner(fd: int, path: Path) -> None:
    """Give `fd` the uid/gid of `path`, if `path` exists and we are allowed to."""
    try:
        st = os.stat(path)
    except OSError:
        return
    try:
        os.fchown(fd, st.st_uid, st.st_gid)
    except OSError:
        pass


def _write(job: dict) -> dict:
    # Job files can carry config values and paths, so keep the directory and
    # every file owner-only from the instant they exist — no umask-dependent
    # world/group-readable window.
    JOBS_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = job_path(job["id"])
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    try:
        # Carry the existing owner onto the replacement inode. The atomic replace
        # below creates a *new* file, so the first update by the root worker would
        # otherwise turn a web-created job root-owned — and the unprivileged web
        # process, which must keep reading it to answer GET /api/jobs/<id>, would
        # report every job it enqueued as "unknown job" the moment work started on
        # it. The uid can only be root's or the web user's (the queue directory is
        # owner-only), so this hands nothing to an attacker. Unconditional so the
        # path is exercised by ordinary same-user writes too; EPERM (an
        # unprivileged writer, which by definition already owns the file) is not
        # an error.
        _preserve_owner(fd, path)
        with os.fdopen(fd, "w") as fh:
            fh.write(json.dumps(job, indent=2, sort_keys=True))
        tmp.replace(path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    return job


def create_job(action: str, params: dict) -> dict:
    job = {
        "id": new_job_id(),
        "action": action,
        "params": params or {},
        "state": "queued",
        "created_at": int(time.time()),
        # A one-second created_at cannot order two jobs enqueued in the same
        # second, but the worker must still run them in submission order.
        "seq": time.time_ns(),
        "started_at": None,
        "finished_at": None,
        "exit_code": None,
        "output": "",
    }
    return _write(job)


def read_job(job_id: str) -> dict | None:
    """Return the job, or None when it is missing or unreadable.

    A corrupt file is treated as absent: a half-written or hand-edited job must
    not take down the reader. That covers decode failures too — invalid UTF-8
    bytes raise UnicodeDecodeError, which (like json.JSONDecodeError) is a
    ValueError subclass, so (OSError, ValueError) catches both without a bare
    except.
    """
    try:
        path = job_path(job_id)
    except ValueError:
        return None
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
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
    jobs.sort(key=lambda j: j.get("seq") or j.get("created_at") or 0, reverse=True)
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
    queued.sort(key=lambda j: j.get("seq") or j.get("created_at") or 0)
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
