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
import stat
import sys
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


# --- the queue directory is hostile ------------------------------------------
# Every path operation below runs as *root* in the worker, inside a directory the
# unprivileged web user owns and must keep writable. So that user can plant
# anything it likes at any name root is about to touch: a symlink, a hardlink, a
# FIFO. Three escalations were live here, and each is closed the way
# palworld-engine-config closes its four (see read_backup_nofollow /
# write_new_nofollow / write_dest_nofollow there) — push the decision into the
# kernel at the moment of use, so there is no window between deciding and acting:
#
#   * the temp file is created O_CREAT|O_EXCL|O_NOFOLLOW under an unguessable
#     name, so a pre-planted link cannot redirect root's write;
#   * the owner carried onto the replacement inode comes from an lstat of the
#     name, must be a regular file, and is *validated* against the owners this
#     queue may legitimately have;
#   * every read opens O_NOFOLLOW|O_NONBLOCK and fstats the descriptor, so a
#     symlinked <id>.json cannot make root read a file of the attacker's choosing
#     and a FIFO cannot make it block forever (which stalled the entire queue).
#
# `fs.protected_symlinks` does not help with any of it: that sysctl only applies
# to world-writable sticky directories, and this one is 0700.

_CHOWN_WARNED: set[str] = set()


def _allowed_owner_uids() -> set[int]:
    """The uids a job file in this queue may legitimately belong to.

    Only two parties write here: root (the worker) and whoever owns the queue
    directory (the web process). An earlier version *assumed* that and skipped
    the check, reasoning that the directory is owner-only — which is not sound
    two ways. The web user owns the directory and can `chmod 0777` it (the 0700 is
    applied once, by install.sh or the container entrypoint; _write's mkdir is a
    no-op on an existing directory), after which a third account can create files
    here; and `link(2)`/`symlink(2)` introduce a foreign owner with no chown at
    all. So the owner is validated, not trusted.

    lstat, not stat: JOBS_DIR itself could be a symlink, and the owner of what it
    points at would then decide what root accepts.
    """
    uids = {0}
    try:
        uids.add(os.lstat(JOBS_DIR).st_uid)
    except OSError:
        # No queue directory yet (the very first create_job) — the writer's own
        # uid is the only owner a job file can have at that point anyway.
        pass
    return uids


def _preserve_owner(fd: int, path: Path) -> None:
    """Give `fd` the uid/gid of `path`, if that owner is one we may propagate.

    `follow_symlinks=False` is the whole point: a plain os.stat here followed a
    symlink planted at `path` and handed root the *target's* uid, which together
    with the write below meant "enqueue any job, get /etc/shadow chowned to me".
    A non-regular entry (symlink, FIFO, directory) is never a job file, so there
    is no owner to preserve and the fchown is skipped entirely.
    """
    try:
        st = os.lstat(path)
    except OSError:
        return
    if not stat.S_ISREG(st.st_mode):
        return
    if st.st_uid not in _allowed_owner_uids():
        # Not ours to propagate: leave the replacement owned by whoever is
        # writing. Worst case the web process loses read access to one job.
        print(f"palwarden_jobs: refusing to preserve unexpected owner "
              f"uid={st.st_uid} on {path}", file=sys.stderr)
        return
    try:
        os.fchown(fd, st.st_uid, st.st_gid)
    except OSError as exc:
        # Only root ever reaches this in production (the unprivileged writer
        # already owns the file, so its fchown is a no-op that succeeds), which
        # makes a failure meaningful: root without CAP_CHOWN (--cap-drop=CHOWN,
        # or userns remapping). Silently passing turned that into "the web UI
        # reports unknown job for everything I enqueued" with zero diagnostics.
        # Warn once per file, not on every state change of every job.
        key = str(path)
        if key not in _CHOWN_WARNED:
            _CHOWN_WARNED.add(key)
            print(f"palwarden_jobs: cannot preserve owner "
                  f"{st.st_uid}:{st.st_gid} on {path}: {exc}", file=sys.stderr)


def _write(job: dict) -> dict:
    # Job files can carry config values and paths, so keep the directory and
    # every file owner-only from the instant they exist — no umask-dependent
    # world/group-readable window.
    JOBS_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = job_path(job["id"])
    # Unguessable, per-writer temp name, created O_EXCL|O_NOFOLLOW. A fixed
    # "<id>.json.tmp" was plantable: `ln -s /tmp/victim <id>.json.tmp` and root's
    # next state update truncated and overwrote the victim. O_CREAT|O_EXCL refuses
    # anything already at the name — including a symlink, dangling or not, which
    # it reports as EEXIST rather than ever reaching ELOOP (the lesson
    # write_new_nofollow in palworld-engine-config records) — and O_NOFOLLOW makes
    # the refusal explicit. The random suffix is defence in depth on top of that,
    # not the mechanism; it also keeps two concurrent writers off one name.
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}.{secrets.token_hex(4)}")
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        # 0600 from creation and never widened: the file must not be
        # world-readable, not even briefly.
        with os.fdopen(fd, "w") as fh:
            # Carry the existing owner onto the replacement inode. The atomic
            # replace below creates a *new* file, so the first update by the root
            # worker would otherwise turn a web-created job root-owned — and the
            # unprivileged web process, which must keep reading it to answer
            # GET /api/jobs/<id>, would report every job it enqueued as "unknown
            # job" the moment work started on it. Unconditional, so the path is
            # exercised by ordinary same-user writes too.
            _preserve_owner(fh.fileno(), path)
            fh.write(json.dumps(job, indent=2, sort_keys=True))
        # rename(2) replaces a symlink sitting at `path` rather than writing
        # through it, so the destination needs no separate guard.
        tmp.replace(path)
    except BaseException:
        # Unlink on *any* failure: the temp file may already hold job contents,
        # and 0600 debris left by a crash is still debris.
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


def _read_job_text(path: Path) -> str:
    """Read a job file, refusing anything that is not a plausible job file.

    Deliberately the *only* way this module reads the queue, so every caller is
    covered by one implementation: read_job (hence update_job and append_output),
    list_jobs, and through those claim_next, has_pending, prune and jobd's
    reap_orphans. Guarding one call site instead of the primitive would leave the
    others open, which is how the hole below survived in the first place.

    Three refusals, all decided by the kernel or by fstat on the descriptor we are
    actually reading — never by a check on a name we then re-open:

      * O_NOFOLLOW: a symlink at `<id>.json` otherwise made root read_text() a
        file of the attacker's choosing, and (with _preserve_owner's old
        following stat) chown it to them.
      * O_NONBLOCK + S_ISREG: a FIFO at the name otherwise blocked this read
        forever. Not a disclosure but a permanent stop — the worker's poll loop
        never returns. O_NONBLOCK makes the open return immediately; fstat then
        rejects the descriptor.
      * owner validation: a file root would otherwise parse as a job, placed by a
        third account (see _allowed_owner_uids).

    Raises OSError or ValueError, both of which read_job already treats as
    "absent": a refused file is not a job.
    """
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError(f"job file is not a regular file; refused: {path}")
        if st.st_uid not in _allowed_owner_uids():
            raise ValueError(f"job file has unexpected owner uid={st.st_uid}; refused: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(fd)
    return b"".join(chunks).decode()


def read_job(job_id: str) -> dict | None:
    """Return the job, or None when it is missing, refused or unreadable.

    A corrupt file is treated as absent: a half-written or hand-edited job must
    not take down the reader. That covers decode failures too — invalid UTF-8
    bytes raise UnicodeDecodeError, which (like json.JSONDecodeError) is a
    ValueError subclass, so (OSError, ValueError) catches both without a bare
    except. It also covers _read_job_text's security refusals: a planted symlink
    or FIFO is "not a job" rather than an error every caller must handle, so a
    hostile entry cannot fail a state update it has no business being part of.
    """
    try:
        path = job_path(job_id)
    except ValueError:
        return None
    try:
        data = json.loads(_read_job_text(path))
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
