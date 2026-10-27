#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
"""Cross-language lifecycle lock + state/generation for palwarden.

Spec:  docs/superpowers/specs/2026-10-18-idle-shutdown-knock-wake.md  §4.1, §4.4
Plan:  docs/superpowers/plans/2026-10-18-idle-shutdown-knock-wake.md (Task 2)

Two halves:

1. Lock — the lifecycle lock is a root-owned regular file locked with
   flock(2).  Python, shell flock(1) and re-exec'd children all contend on
   the same kernel object, so exclusion holds across languages.  The
   descriptor is inherited by children through FD_ENV, which carries the fd
   number (never a boolean): a child that sees FD_ENV knows it *borrows* the
   lock (it may use it, it must not release it — see release()'s identity
   record).  acquire() always opens the lock fresh: a process that already
   holds the lock on another descriptor is excluded by ordinary flock
   semantics, exactly like any other contender.

2. State — a JSON file (status + generation + operation + timestamp) that
   deliberately outlives the lock: it is the "we left mid-transaction" marker.
   Supported maintenance paths publish status "active" with a rotated
   generation BEFORE touching the service; a failed step leaves "unsafe" and
   an interrupted one (crash/SIGKILL) leaves "active" (spec §4.4).  Both
   markers are sticky: ordinary writers cannot clear them, and recovery is
   an operator-run acknowledge-maintenance (root-only, requires
   service_state() to confirm the service stopped/wanted-down; it never
   starts the game).

Acquisition order: the lifecycle lock is the OUTERMOST lock in this
codebase.  A controller takes it before any other lock (backup.lock,
restore.lock, or anything added later) and releases it last; code that
already holds another lock must never reach for the lifecycle lock.
palworld-restore is the one enrolled script that nests the other way
around — it takes the lifecycle lock only after its pre-restore safety
backup has completed (backup.lock already released), never while holding
restore.lock — so no path ever holds an inner lock while blocking on
this one, and no lock cycle exists.

CLI exit codes (sysexits): 64 usage, 65 data error, 66 no inherited
descriptor, 73 not permitted (non-root), 75 lock busy / refused.
"""

import errno
import fcntl
import json
import os
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

__all__ = [
    "FD_ENV",
    "LifecycleError",
    "acknowledge_maintenance",
    "acquire",
    "begin_transaction",
    "ensure_state",
    "init_runtime",
    "main",
    "ownership_env",
    "ownership_from_env",
    "read_state",
    "release",
    "escalate_abandoned",
    "write_state",
]

FD_ENV = "PALWARDEN_LIFECYCLE_LOCK_FD"
# Set by the acquire bridge for the re-exec'd OWNER script only.  The sourced
# bash helper registers an EXIT trap calling `complete <rc>` when it sees it,
# then unsets it so nested controllers (which inherit the lock descriptor)
# stay plain borrowers that never close the outer transaction.
TXN_ENV = "PALWARDEN_LIFECYCLE_TXN"
LOCK_ENV = "PALWARDEN_LIFECYCLE_LOCK"
STATE_ENV = "PALWARDEN_LIFECYCLE_STATE_DIR"
# F1 decision (owner, 2026-10-21, option C): the LOCK lives on /run — a pure
# mutual-exclusion primitive gains nothing from persistence, and /run always
# exists root-owned.  The maintenance STATE lives on the persistent
# palwarden-ops volume next to the ops config and cooldown file, because an
# "unsafe/active" marker is the one piece of state whose loss has safety
# meaning (it must survive in-container restarts).  Both dirs are
# pre-created: /run by the OS, /var/lib/palwarden-ops by install.sh and the
# image.
DEFAULT_LOCK_PATH = "/run/palworld-lifecycle.lock"
DEFAULT_STATE_DIR = "/var/lib/palwarden-ops/lifecycle"
STATE_FILENAME = "state.json"
DEFAULT_SERVICE = "palworld.service"

EX_USAGE = 64
EX_DATAERR = 65
EX_NODESC = 66
EX_NOTPERM = 73
EX_BUSY = 75

_STATUSES = ("idle", "active", "unsafe")
_OPERATION_CLASSES = ("update", "restore", "config", "maintenance")
_POLL_SECONDS = 0.02

USAGE = """\
usage: palwarden_lifecycle <verb> [options]

verbs:
  acquire [--timeout S] [-- CMD...]
      Take the lifecycle lock.  Without CMD: print the lock path and exit
      (lock released on exit).  With CMD: exec CMD in place — argv, exit
      code and signals are preserved; the lock is held for CMD's lifetime
      and released by the kernel when CMD exits (gracefully or not).
      Before exec the outer transaction is published: state -> active with
      a rotated generation (spec §4.4), and PALWARDEN_LIFECYCLE_TXN=1 is
      exported so the owner script's EXIT trap closes the transaction with
      `complete <rc>`.  A command that never completes leaves `active` —
      fail closed until acknowledge-maintenance.
  release
      Release an inherited lock (the owner's re-exec bridge sets FD_ENV).
  borrowed
      Exit 0 if FD_ENV names a live inherited lock descriptor, 66
      otherwise.  Lets a sourced bash helper validate a claimed borrow
      instead of trusting the environment variable's mere presence.
  state [--json]
      Print the state/generation file as JSON.
  init-runtime [--json]
      Runtime start-up: seed the state file if absent and rotate an idle
      generation so a wake admitted by the previous runtime cannot execute
      after this one.  An active/unsafe marker survives untouched.
  complete <rc>
      Close an outer transaction: rc 0 -> idle, non-zero -> unsafe.
      Best-effort and sticky-unsafe-safe; never changes the caller's exit
      code.  Called from the owner script's EXIT trap.
  acknowledge-maintenance [--confirm]
      Root-only: clear an unsafe marker after service_state() confirms the
      service is stopped/wanted-down on the live supervisor (never starts
      the game; crash-backoff, starting and unknown all refuse).
"""


class LifecycleError(Exception):
    """Raised for lifecycle lock/state failures."""


class UnsafeMaintenanceError(LifecycleError):
    """A write tried to leave `unsafe` without explicit operator recovery.

    Sticky-unsafe rule (F2, spec §4.4): an interrupted/unsafe maintenance
    marker suppresses auto-wake until an operator runs
    acknowledge-maintenance; it must never be cleared merely because a
    flock became available or an unrelated job succeeded.
    """


class _LockBusy(LifecycleError):
    """The lock was held by someone else (CLI maps this to rc=75)."""


# ---------------------------------------------------------------------------
# Lock
# ---------------------------------------------------------------------------

def _lock_path():
    return os.environ.get(LOCK_ENV) or DEFAULT_LOCK_PATH


def _state_dir():
    return os.environ.get(STATE_ENV) or DEFAULT_STATE_DIR


def _safe_open_lock(path):
    """Open the lock file safely; refuse symlinks, non-regular files, and
    parent directories not owned by root or the current user."""
    parent = os.path.dirname(path) or "."
    try:
        st_p = os.lstat(parent)
    except OSError as e:
        raise LifecycleError("lock parent unavailable: %s" % e)
    if not stat.S_ISDIR(st_p.st_mode):
        raise LifecycleError("lock parent is not a directory (or is a symlink): %s" % parent)
    if st_p.st_uid not in (0, os.geteuid()):
        raise LifecycleError("lock parent not owned by root or current user: %s" % parent)
    if os.path.islink(path):
        raise LifecycleError("lock path is a symlink: %s" % path)
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(path, flags, 0o600)
    except OSError as e:
        if getattr(e, "errno", None) == errno.ELOOP:
            raise LifecycleError("lock path is a symlink (or resolves through one): %s" % path)
        raise LifecycleError("refusing to open lock %s: %s" % (path, e))
    try:
        st = os.fstat(fd)
    except OSError as e:
        os.close(fd)
        raise LifecycleError("cannot stat lock %s: %s" % (path, e))
    if stat.S_ISLNK(st.st_mode):
        os.close(fd)
        raise LifecycleError("lock path is a symlink: %s" % path)
    if not stat.S_ISREG(st.st_mode):
        os.close(fd)
        raise LifecycleError("lock path is not a regular file: %s" % path)
    try:
        os.fchmod(fd, 0o600)
    except OSError as e:
        os.close(fd)
        raise LifecycleError("cannot set lock mode: %s" % e)
    return fd


def _flock_nonblock(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False
    except OSError as e:
        raise LifecycleError("flock failed: %s" % e)


def _holder_summary(path):
    try:
        with open(path, "r") as f:
            data = json.loads(f.read() or "null")
    except (OSError, ValueError):
        return "unknown"
    if isinstance(data, dict) and data.get("pid"):
        return "pid=%s (comm=%s)" % (data["pid"], data.get("comm") or "?")
    return "unknown"


def acquire(timeout=5.0, owner_pid=None, owner_comm=None):
    """Take the lifecycle lock; return the descriptor that holds it.

    Always opens the lock fresh (no borrowed-fd shortcut), so a process
    that already holds the lock on another descriptor is excluded like any
    other contender.  When owner_pid/owner_comm are given, a one-line JSON
    record is written into the lock file; release() with a claimed identity
    must match it.
    """
    path = _lock_path()
    fd = _safe_open_lock(path)
    try:
        deadline = time.monotonic() + max(0.0, float(timeout))
        while not _flock_nonblock(fd):
            if time.monotonic() >= deadline:
                raise _LockBusy(
                    "lock held by %s; gave up after %gs" % (_holder_summary(path), float(timeout))
                )
            time.sleep(_POLL_SECONDS)
        # Winner: clear any stale record from a previous (dead) owner, then
        # optionally write our own identity record.
        os.ftruncate(fd, 0)
        if owner_pid is not None or owner_comm is not None:
            record = json.dumps({
                "pid": int(owner_pid) if owner_pid is not None else os.getpid(),
                "comm": owner_comm or "",
            })
            os.lseek(fd, 0, os.SEEK_SET)
            os.write(fd, record.encode("utf-8") + b"\n")
    except LifecycleError:
        os.close(fd)
        raise
    except OSError as e:
        os.close(fd)
        raise LifecycleError("acquire failed: %s" % e)
    return fd


def _record_from_fd(fd):
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        data = os.read(fd, 4096)
    except OSError:
        return None
    try:
        rec = json.loads(data.decode("utf-8", "replace").strip() or "null")
    except ValueError:
        return None
    return rec if isinstance(rec, dict) else None


def release(fd, owner_pid=None, owner_comm=None):
    """Release the lock on fd and close the descriptor.

    If the lock file carries an identity record (acquire with owner_pid)
    and the caller claims an identity, the claim must match the record;
    otherwise the release is refused (the descriptor is left open).
    """
    try:
        st = os.fstat(fd)
    except OSError as e:
        raise LifecycleError("descriptor is not open: %s" % e)
    if not stat.S_ISREG(st.st_mode):
        raise LifecycleError("descriptor is not a regular file")
    try:
        st_p = os.lstat(_lock_path())
    except OSError:
        raise LifecycleError("lock path unavailable; refusing to release")
    if (st_p.st_dev, st_p.st_ino) != (st.st_dev, st.st_ino):
        raise LifecycleError("descriptor does not refer to the lifecycle lock")
    if not _flock_nonblock(fd):
        raise LifecycleError("descriptor does not hold the lifecycle lock")
    rec = _record_from_fd(fd)
    if rec is not None:
        if owner_pid is not None and rec.get("pid") != owner_pid:
            raise LifecycleError(
                "release refused: claimed pid %s does not match lock record (pid %s)"
                % (owner_pid, rec.get("pid"))
            )
        if owner_comm is not None and rec.get("comm") and rec.get("comm") != owner_comm:
            raise LifecycleError(
                "release refused: claimed comm %r does not match lock record" % owner_comm
            )
        try:
            os.ftruncate(fd, 0)
        except OSError:
            pass
    os.close(fd)


def ownership_from_env():
    """Report lock ownership inherited via FD_ENV.

    Returns ("borrowed", fd) when FD_ENV names an open descriptor that refers
    to the lock file and holds the lock; ("none", None) otherwise.  Never
    raises — a missing/invalid value simply means "not the owner".
    """
    raw = os.environ.get(FD_ENV)
    if raw is None:
        return ("none", None)
    try:
        fd = int(raw)
    except (TypeError, ValueError):
        return ("none", None)
    try:
        st = os.fstat(fd)
    except OSError:
        return ("none", None)
    if not stat.S_ISREG(st.st_mode):
        return ("none", None)
    try:
        st_p = os.lstat(_lock_path())
    except OSError:
        return ("none", None)
    if (st_p.st_dev, st_p.st_ino) != (st.st_dev, st.st_ino):
        return ("none", None)
    if not _flock_nonblock(fd):
        return ("none", None)
    return ("borrowed", fd)


def ownership_env(fd):
    """Env entries that hand the lock to a child we are about to exec.

    Clears CLOEXEC on fd so the descriptor survives the exec, and returns
    {FD_ENV: str(fd)} to merge into the child environment.  The child's
    ownership_from_env() will then report "borrowed".
    """
    try:
        st = os.fstat(fd)
    except OSError as e:
        raise LifecycleError("descriptor is not open: %s" % e)
    if not stat.S_ISREG(st.st_mode):
        raise LifecycleError("descriptor is not a regular file")
    try:
        flags = fcntl.fcntl(fd, fcntl.F_GETFD)
        fcntl.fcntl(fd, fcntl.F_SETFD, flags & ~fcntl.FD_CLOEXEC)
    except OSError as e:
        raise LifecycleError("cannot set descriptor flags: %s" % e)
    return {FD_ENV: str(fd)}


# ---------------------------------------------------------------------------
# State / generation
# ---------------------------------------------------------------------------

def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _new_generation():
    return secrets.token_hex(16)


def _missing_state():
    return {"generation": None, "status": "unknown", "operation": None, "updated_at": None}


def _state_path():
    return os.path.join(_state_dir(), STATE_FILENAME)


def read_state():
    """Return the state dict.  A missing file reads as status "unknown"; a
    corrupt file is a data error (LifecycleError)."""
    p = _state_path()
    try:
        with open(p, "r") as f:
            raw = f.read()
    except FileNotFoundError:
        return _missing_state()
    except OSError as e:
        raise LifecycleError("state file unreadable: %s" % e)
    try:
        data = json.loads(raw)
    except ValueError:
        raise LifecycleError("state file is corrupt: %s" % p)
    if not isinstance(data, dict) or "generation" not in data or "status" not in data:
        raise LifecycleError("state file is corrupt: %s" % p)
    return {
        "generation": data.get("generation"),
        "status": data.get("status"),
        "operation": data.get("operation"),
        "updated_at": data.get("updated_at"),
    }


def _atomic_write_state(path, state):
    d = os.path.dirname(path) or "."
    fd = None
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(prefix=".state-", suffix=".tmp", dir=d)
        with os.fdopen(fd, "w") as f:
            fd = None  # fdopen owns it now
            json.dump(state, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
            os.fchmod(f.fileno(), 0o644)
        os.replace(tmp, path)
    except OSError as e:
        raise LifecycleError("cannot write state file: %s" % e)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def ensure_state():
    """Create the state dir (0755) and state file (0644, status "idle") if
    absent.  Idempotent: never rotates an existing generation."""
    d = _state_dir()
    try:
        os.makedirs(d, exist_ok=True)
        os.chmod(d, 0o755)
    except OSError as e:
        raise LifecycleError("state dir unavailable: %s" % e)
    p = _state_path()
    try:
        if not os.path.exists(p):
            _atomic_write_state(p, {
                "generation": _new_generation(),
                "status": "idle",
                "operation": None,
                "updated_at": _now_iso(),
            })
    except LifecycleError:
        raise
    except OSError as e:
        raise LifecycleError("cannot create state file: %s" % e)
    return read_state()


def init_runtime():
    """Rotate the runtime generation at start-up (spec §4.4, plan Task 8).

    A wake request is bound to the generation that was idle when it was
    admitted; an old-runtime generation must not survive a runtime restart,
    or a wake queued before the restart could execute as a delayed wake
    after it (the queue itself lives on a persistent volume).  Idle state
    therefore rotates to a fresh generation.  An active/unsafe marker is a
    maintenance record, not runtime ephemera: it survives untouched and
    keeps inhibiting wake until an operator runs acknowledge-maintenance.
    """
    ensure_state()
    # R2 (Sol review): the old read-then-rotate ran WITHOUT lifecycle
    # ownership.  A concurrent actor could acquire the real flock and
    # publish active/unsafe inside the read-modify-write window; the
    # resumed initializer then wrote `idle` over a live transaction (the
    # sticky guard only refuses leaving `unsafe`, so `active` was
    # clobbered).  Initialization is now serialized: escalate any
    # abandoned marker, reread UNDER ownership, and rotate only when the
    # state is idle there.  If the lock stays busy past the bounded
    # deadline, skip the rotation — never overwrite a concurrent
    # active/unsafe marker (wake admission already fails closed on those).
    init_timeout = float(os.environ.get(
        "PALWARDEN_INIT_ACQUIRE_TIMEOUT_S", "5"))
    try:
        fd = acquire(timeout=init_timeout)
    except _LockBusy:
        sys.stderr.write(
            "palwarden_lifecycle: init-runtime skipped the rotation; the "
            "lifecycle lock is held by a live transaction\n")
        return read_state()
    try:
        escalate_abandoned()
        state = read_state()
        if state["status"] == "idle":
            return write_state("idle", rotate=True)
        return state
    finally:
        try:
            release(fd)
        except LifecycleError:
            pass


def escalate_abandoned():
    """Escalate an abandoned `active` marker to `unsafe` (Sol review R1).

    Call this immediately AFTER acquiring the lock, before publishing your
    own transaction.  Every normal completer writes idle/unsafe *before*
    the lock is released (the bash EXIT trap runs before exit; jobd and
    restore mark before releasing), so finding `active` on a freshly
    acquired lock proves the previous holder died mid-transaction without
    completing.  Escalating to `unsafe` makes that abandoned transaction
    sticky: the new transaction may proceed (the lock serializes it), but
    its completion writes are refused by the sticky guard and the marker
    survives until acknowledge-maintenance.  Best-effort; returns True if
    an escalation happened.
    """
    try:
        if read_state()["status"] != "active":
            return False
        write_state("unsafe")
        return True
    except LifecycleError:
        return False


def begin_transaction(operation=None):
    """Establish persistent wake inhibition BEFORE mutation, under ownership.

    Only a fresh owner calls this; borrowers and socket leases do not. Return
    True for a newly published active transaction, False for preserved unsafe
    state. Publication/escalation failures propagate: a readable old idle file
    survives failed atomic replacement and must never authorize maintenance.
    """
    if operation is not None and operation not in _OPERATION_CLASSES:
        raise LifecycleError("invalid operation class %r" % (operation,))
    current = ensure_state()
    if current["status"] == "active":
        # Unlike best-effort escalate_abandoned(), failure MUST propagate.
        current = write_state("unsafe", operation=current["operation"])
    if current["status"] == "unsafe":
        return False  # deliberate recovery is allowed; acknowledgement is not
    if current["status"] != "idle":
        raise LifecycleError("unknown lifecycle status; maintenance refused")
    write_state("active", operation=operation, rotate=True)
    return True


def write_state(status, operation=None, rotate=False, force=False):
    """Atomically publish a new status (optionally rotating the generation).
    Invalid status/operation values are rejected before touching the file.

    Sticky unsafe (F2): while the current status is `unsafe`, ordinary
    writers (active/idle) are refused with UnsafeMaintenanceError — only
    acknowledge-maintenance (force=True) may leave the marker, and
    unsafe -> unsafe escalation stays allowed.
    """
    if status not in _STATUSES:
        raise LifecycleError("invalid status %r" % (status,))
    if operation is not None and operation not in _OPERATION_CLASSES:
        raise LifecycleError("invalid operation class %r" % (operation,))
    current = read_state()
    if current["status"] == "unsafe" and status != "unsafe" and not force:
        raise UnsafeMaintenanceError(
            "refusing to overwrite the unsafe maintenance marker with %r; "
            "run acknowledge-maintenance --confirm to recover" % (status,))
    generation = current["generation"]
    if rotate or generation is None:
        generation = _new_generation()
    state = {
        "generation": generation,
        "status": status,
        "operation": operation,
        "updated_at": _now_iso(),
    }
    _atomic_write_state(_state_path(), state)
    return state


# ---------------------------------------------------------------------------
# Idempotent start (idle-shutdown/knock-wake spec §4.3, §6.2, §6.3)
# ---------------------------------------------------------------------------
#
# PRECONDITION for every function here that touches state/generation: the
# caller holds the lifecycle lock (borrowed or acquired).  start_if_down()
# enforces it for the wake path by acquiring nonblocking ownership itself.

S6_DIR_ENV = "PALWARDEN_S6_SVC_DIR"
API_BIN_ENV = "PALWORLD_API_BIN"
COOLDOWN_FILE_ENV = "PALWORLD_KNOCK_COOLDOWN_FILE"
DEFAULT_COOLDOWN_PATH = "/var/lib/palwarden-ops/knock.cooldown"
NOTIFY_HELPER = os.environ.get("PALWARDEN_NOTIFY_HELPER", "/usr/local/lib/palworld-notify")
SERVICE_STATES = (
    "running", "starting", "stopping", "stopped",
    "crash-backoff", "no-supervisor", "unknown",
)
# A cooldown timestamp may lead the clock by this much (clock skew) before it
# is treated as corrupt-and-fail-closed rather than merely recent.
COOLDOWN_FUTURE_SKEW_MS = 60_000


def _s6_service_dir(service=None):
    svc_dir = os.environ.get(S6_DIR_ENV) or "/run/service"
    svc = (service or os.environ.get("PALWARDEN_LIFECYCLE_SERVICE") or DEFAULT_SERVICE)
    if svc == DEFAULT_SERVICE:
        svc = "palworld-server"  # the s6-rc service name in the image
    else:
        svc = svc.removesuffix(".service")
    return os.path.join(svc_dir, svc)


def service_state(service=None):
    """Classify the game service into one of SERVICE_STATES.

    Container branch (PALWARDEN_CONTAINER=1) reads s6's machine-readable
    actual state (s6-svstat) AND the wanted-down marker file (``<svcdir>/down``
    — MEASURED on s6-overlay v3 that s6-svc maintains NO such file, so every
    container stop path in this repo creates it and every start path removes
    it; see lib/palwarden-lifecycle-bash).  Wanted state is never inferred
    from process absence.  The bare-metal branch asks systemd (is-active +
    is-enabled).  Anything unresolvable is "unknown"/"no-supervisor", which
    callers must treat as refuse, never as eligible.
    """
    if os.environ.get("PALWARDEN_CONTAINER"):
        return _service_state_s6(_s6_service_dir(service))
    return _service_state_systemd(service)


def _service_state_s6(svcdir):
    if not os.path.isdir(svcdir):
        return "no-supervisor"
    try:
        r = subprocess.run(["s6-svstat", svcdir],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    out = (r.stdout or "").strip()
    up = out.startswith("up")
    if r.returncode not in (0, 1) or not (up or out.startswith("down")):
        return "unknown"
    wanted_down = os.path.exists(os.path.join(svcdir, "down"))
    if up:
        if "(no pid)" in out:
            return "starting"
        return "stopping" if wanted_down else "running"
    return "stopped" if wanted_down else "crash-backoff"


def _service_state_systemd(service=None):
    svc_bin = os.environ.get("PALWARDEN_SYSTEMCTL_BIN") or "systemctl"
    if shutil.which(svc_bin) is None:
        return "no-supervisor"
    svc = service or DEFAULT_SERVICE
    try:
        r = subprocess.run([svc_bin, "is-active", svc],
                           capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    state = (r.stdout or "").strip()
    if state == "active":
        return "running"
    if state in ("activating", "reloading"):
        return "starting"
    if state == "deactivating":
        return "stopping"
    if state != "inactive":
        return "unknown"
    try:
        r = subprocess.run([svc_bin, "is-enabled", svc],
                           capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    # An enabled unit that is merely inactive still WANTS to be up (crash
    # auto-restart pending): starting it is the supervisor's job, not ours.
    return "stopped" if (r.stdout or "").strip() == "disabled" else "crash-backoff"


def cooldown_path():
    return os.environ.get(COOLDOWN_FILE_ENV) or DEFAULT_COOLDOWN_PATH


def read_cooldown(path=None):
    """Return the stored wake timestamp (ms), or None if missing.

    Raises ValueError on corrupt, non-integer, negative, or future-beyond-
    skew content: callers must fail closed, never treat garbage as "no
    previous wake".
    """
    path = path or cooldown_path()
    try:
        with open(path, "r") as f:
            raw = f.read().strip()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise ValueError("cooldown file unreadable: %s" % e)
    try:
        value = int(raw)
    except ValueError:
        raise ValueError("cooldown file is not an integer timestamp: %r" % raw[:40])
    if value < 0:
        raise ValueError("cooldown timestamp is negative")
    if value > int(time.time() * 1000) + COOLDOWN_FUTURE_SKEW_MS:
        raise ValueError("cooldown timestamp is in the future")
    return value


def write_cooldown(path=None, at_ms=None):
    """Atomically record the wake time BEFORE the start is attempted."""
    path = path or cooldown_path()
    at_ms = int(time.time() * 1000) if at_ms is None else int(at_ms)
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".knock.cooldown.")
    try:
        os.write(fd, ("%d\n" % at_ms).encode())
        os.fchmod(fd, 0o640)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)
    return at_ms


def cooldown_status(path=None, cooldown_s=600, now_ms=None):
    """(state, age_ms): missing | active | expired | invalid."""
    path = path or cooldown_path()
    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    try:
        last = read_cooldown(path)
    except ValueError:
        return ("invalid", None)
    if last is None:
        return ("missing", None)
    age = now_ms - last
    if age < 0:  # beyond the read skew but still computable
        return ("invalid", age)
    if age < int(cooldown_s) * 1000:
        return ("active", age)
    return ("expired", age)


def _start_service(fd, service=None):
    """Start via the existing service machinery, under our ownership.

    Never restart, never down.  The starter inherits the lifecycle
    descriptor (so the container systemctl shim reuses the transaction
    instead of re-acquiring): CLOEXEC is cleared on the descriptor only for
    the duration of this spawn and restored immediately after, so unrelated
    later subprocesses (readiness polls, notify) never inherit the lock.
    wake/start_if_down are single-threaded, so no other spawn can observe
    the cleared flag.
    """
    svc_bin = os.environ.get("PALWARDEN_SYSTEMCTL_BIN") or "systemctl"
    svc = service or DEFAULT_SERVICE
    env = dict(os.environ)
    env[FD_ENV] = str(fd)
    flags = fcntl.fcntl(fd, fcntl.F_GETFD)
    fcntl.fcntl(fd, fcntl.F_SETFD, flags & ~fcntl.FD_CLOEXEC)
    try:
        # pass_fds is MANDATORY, not belt-and-braces: subprocess defaults to
        # close_fds=True, which closes every non-std fd in the child
        # regardless of CLOEXEC. Without it the shim sees FD_ENV pointing at a
        # dead descriptor and refuses (measured in Docker acceptance, Task 11)
        # — the wake could never start the service.
        r = subprocess.run([svc_bin, "start", svc], env=env, pass_fds=(fd,),
                           capture_output=True, text=True, timeout=60)
    finally:
        fcntl.fcntl(fd, fcntl.F_SETFD, flags)
    if r.returncode != 0:
        detail = (r.stderr or r.stdout or "starter exited %d" % r.returncode).strip()
        raise LifecycleError("starter failed: %s" % detail[:300])


# Fixed shell code (never interpolated): source the helper, then CALL its
# function. The shipped lib/palworld-notify is function-only — executing it
# merely defines palworld_notify() and exits (F9, review follow-up).
_NOTIFY_SH = ('source "$1" 2>/dev/null || exit 0; '
              "declare -F palworld_notify >/dev/null || exit 0; "
              'palworld_notify "$2" "$3"')


def _notify(kind, text):
    """Optional shell notify helper: source it and invoke its function.

    Missing helper, missing function or failing helper is nonfatal (spec
    §6.3); kind and message travel as ARGUMENTS ($2/$3), never interpolated
    into shell text — metacharacters in a message stay literal.
    """
    try:
        subprocess.run(["bash", "-c", _NOTIFY_SH, "palwarden-notify",
                        NOTIFY_HELPER, kind, text],
                       capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


def _readiness(api_bin=None, timeout_s=None, poll_s=None):
    """Poll the existing REST client for at most timeout_s (spec §6.2).

    Returns healthy | unverified | failed.  Exit 2 means REST unconfigured:
    started but NOT verified — never reported as healthy.
    """
    api = api_bin or os.environ.get(API_BIN_ENV) or "/usr/local/sbin/palworld-api"
    if timeout_s is None:
        timeout_s = float(os.environ.get("PALWARDEN_WAKE_READY_TIMEOUT_S", "180"))
    if poll_s is None:
        poll_s = float(os.environ.get("PALWARDEN_WAKE_POLL_INTERVAL_S", "2"))
    deadline = time.monotonic() + max(0.0, timeout_s)
    while True:
        try:
            r = subprocess.run([api, "metrics"],
                               capture_output=True, text=True, timeout=10)
            rc = r.returncode
        except (OSError, subprocess.SubprocessError):
            rc = None
        if rc == 0:
            return "healthy"
        if rc == 2:
            return "unverified"
        if time.monotonic() >= deadline:
            return "failed"
        time.sleep(max(0.05, poll_s))


def start_if_down(fd, reason="explicit", config=None, service=None):
    """The one truthful idempotent start (spec §4.3).  Caller holds `fd`.

    Rechecks state, config, and cooldown under ownership; starts ONLY a
    confirmed stopped/wanted-down service; never restarts, never downs,
    never queues a delayed wake.  Returns a dict:
      status: started | already-running | cooldown | refused | error
      readiness: healthy | unverified | failed (started only)
      message: operator-facing text (never contains the knock token)
    """
    if config is None:
        try:
            import palwarden_ops
            config = palwarden_ops.resolve()
        except Exception as e:
            return {"status": "error", "message": "config unreadable, refusing to wake: %s" % e}
    cooldown_s = int(config.get("KNOCK_COOLDOWN", 600))

    # Spec §4.4: an interrupted/unsafe maintenance marker inhibits AUTOMATIC
    # wake until explicit operator recovery. The fenced re-check above covers
    # API-minted wakes; this closes the unfenced paths (UDP knock, manual
    # `wake`) — under OUR ownership, any non-idle status means a crashed or
    # unacknowledged maintenance transaction, and starting the game into it
    # is exactly what the marker exists to prevent. Unreadable state is
    # unknown: refuse blind.
    try:
        lstate = read_state()
    except LifecycleError as e:
        return {"status": "error",
                "message": "lifecycle state unreadable, refusing to wake blind: %s" % e}
    if lstate["status"] != "idle":
        return {"status": "refused",
                "message": "lifecycle status is %s, not idle; automatic wake "
                           "inhibited until acknowledge-maintenance after "
                           "operator recovery" % lstate["status"]}

    state = service_state(service)
    if state in ("running", "starting"):
        return {"status": "already-running",
                "message": "service is %s; no action taken" % state}
    if state == "crash-backoff":
        return {"status": "refused",
                "message": "service is down but wanted-up (crash-backoff); "
                           "the supervisor is still trying — wake refused"}
    if state == "stopping":
        return {"status": "refused",
                "message": "service is stopping; wake refused (retry after the stop completes)"}
    if state == "no-supervisor":
        return {"status": "refused", "message": "no service supervisor found; wake refused"}
    if state != "stopped":
        return {"status": "refused",
                "message": "service state is unknown; wake refused (never start blind)"}

    cd, age = cooldown_status(cooldown_path(), cooldown_s)
    if cd == "invalid":
        return {"status": "error",
                "message": "cooldown file %s is corrupt or carries a future "
                           "timestamp; failing closed — inspect or remove it "
                           "(bounded warning, see spec §6.2)" % cooldown_path()}
    if cd == "active":
        return {"status": "cooldown",
                "message": "cooldown active: last wake %.0fs ago (<%ds); no action taken"
                           % ((age or 0) / 1000.0, cooldown_s)}

    write_cooldown()  # BEFORE start (spec §6.2): a crash mid-start still cools down
    # R9 (Sol review): spec §6.3 requires a truthful failure post on the
    # wake path. These early failures used to return silently; post exactly
    # ONE bounded notification (message truncated, helper nonfatal). Quiet
    # no-ops (already-running/cooldown/refused) return earlier and stay
    # silent per §6.3.
    def _fail(msg):
        _notify("wake", "wake (%s): %s" % (reason, msg[:200]))
        return {"status": "error", "message": msg}
    try:
        _start_service(fd, service)
    except (OSError, subprocess.SubprocessError, LifecycleError) as e:
        return _fail("start failed: %s" % e)
    # s6-svc -u returns as soon as the request lands; supervise spawns the
    # process moments later, so ONE immediate state read races the spawn
    # (measured in Docker acceptance, Task 11: wake reported "start issued
    # but the service is not running" while the game started fine seconds
    # later). Poll briefly before declaring the start a lie.
    start_deadline = time.monotonic() + float(
        os.environ.get("PALWARDEN_WAKE_START_TIMEOUT_S", "10"))
    while service_state(service) != "running":
        if time.monotonic() >= start_deadline:
            return _fail("start issued but the service is not running")
        time.sleep(0.25)
    # R5b (Sol review): the start is confirmed — rotate the generation so
    # sibling wakes fenced against the old generation die at their own
    # fence check instead of piling onto this one. The marker stays `idle`
    # (the wake path is not a maintenance transaction; start_if_down
    # already refused every non-idle status).
    try:
        write_state("idle", rotate=True)
    except LifecycleError as e:
        sys.stderr.write("palwarden_lifecycle: warning: generation not "
                         "rotated after wake (%s); sibling fences stay "
                         "alive until expiry\n" % e)
    ready = _readiness()
    if ready == "unverified" and service_state(service) != "running":
        return _fail("readiness unconfigured and the service is no longer confirmed running")
    if ready == "healthy":
        _notify("wake", "wake (%s): server started, REST ready" % reason)
    elif ready == "unverified":
        _notify("wake", "wake (%s): server started, readiness UNVERIFIED (REST unconfigured)" % reason)
    else:
        _notify("wake", "wake (%s): server started but readiness check FAILED" % reason)
        return {"status": "error", "readiness": ready,
                "message": "service started but readiness failed within the bound"}
    return {"status": "started", "readiness": ready,
            "message": "service started; readiness %s" % ready}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cmd_acquire(args):
    timeout = 5.0
    command = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--timeout":
            if i + 1 >= len(args):
                sys.stderr.write("palwarden_lifecycle: --timeout needs a value\n")
                return EX_USAGE
            try:
                timeout = float(args[i + 1])
            except ValueError:
                sys.stderr.write("palwarden_lifecycle: --timeout must be a number\n")
                return EX_USAGE
            if timeout < 0:
                sys.stderr.write("palwarden_lifecycle: --timeout must be >= 0\n")
                return EX_USAGE
            i += 2
            continue
        if a == "--":
            command = args[i + 1:]
            break
        sys.stderr.write(USAGE)
        return EX_USAGE
    if command is not None and not command:
        sys.stderr.write("palwarden_lifecycle: 'acquire --' needs a command\n")
        return EX_USAGE
    try:
        fd = acquire(timeout=timeout)
    except _LockBusy as e:
        sys.stderr.write("palwarden_lifecycle: %s\n" % e)
        return EX_BUSY
    except LifecycleError as e:
        sys.stderr.write("palwarden_lifecycle: %s\n" % e)
        return EX_DATAERR
    if command is None:
        print(json.dumps({"acquired": True, "lock": _lock_path()}, indent=2))
        os.close(fd)
        return 0
    # Mandatory publication: failed replacement may leave an old readable idle
    # generation. Never run the controller unless wake inhibition is durable.
    try:
        begin_transaction()
    except LifecycleError as e:
        os.close(fd)
        sys.stderr.write("palwarden_lifecycle: maintenance refused: cannot "
                         "publish transaction state (%s); nothing executed\n" % e)
        return EX_DATAERR
    # Re-exec bridge: replace ourselves so argv, exit code and signal
    # handling are the command's own.  The lock fd survives (CLOEXEC
    # cleared) and is released by the kernel when the command exits.
    env = dict(os.environ)
    env.update(ownership_env(fd))
    env[TXN_ENV] = "1"  # the owner script's EXIT trap closes the transaction
    try:
        os.execvpe(command[0], [command[0]] + command[1:], env)
    except (OSError, ValueError) as e:
        # Nothing ever ran: no service change happened, so the transaction
        # can be closed as idle right here (the rotated generation still
        # kills any in-flight wake fence).  Loud, but no operator ack needed.
        try:
            write_state("idle")
        except LifecycleError:
            pass
        sys.stderr.write("palwarden_lifecycle: cannot exec %r: %s\n" % (command[0], e))
        os.close(fd)
        return 72  # EX_NOENT


def _cmd_release(args):
    if args:
        sys.stderr.write(USAGE)
        return EX_USAGE
    kind, fd = ownership_from_env()
    if kind != "borrowed":
        sys.stderr.write(
            "palwarden_lifecycle: no inherited lock descriptor (%s not set or not valid)\n" % FD_ENV
        )
        return EX_NODESC
    try:
        release(fd)
    except LifecycleError as e:
        sys.stderr.write("palwarden_lifecycle: %s\n" % e)
        return EX_DATAERR
    print("released")
    return 0


def _cmd_borrowed(args):
    if args:
        sys.stderr.write(USAGE)
        return EX_USAGE
    kind, _fd = ownership_from_env()
    if kind != "borrowed":
        return EX_NODESC
    return 0


def _cmd_state(args):
    for a in args:
        if a != "--json":
            sys.stderr.write(USAGE)
            return EX_USAGE
    try:
        data = read_state()
    except LifecycleError as e:
        sys.stderr.write("palwarden_lifecycle: %s\n" % e)
        return EX_DATAERR
    print(json.dumps(data, indent=2, sort_keys=True))
    return 0


def _cmd_init_runtime(args):
    for a in args:
        if a != "--json":
            sys.stderr.write(USAGE)
            return EX_USAGE
    try:
        data = init_runtime()
    except LifecycleError as e:
        sys.stderr.write("palwarden_lifecycle: %s\n" % e)
        return EX_DATAERR
    print(json.dumps(data, indent=2, sort_keys=True))
    return 0


def acknowledge_maintenance(confirm=False, timeout=5.0):
    """Root-only recovery: clear an unsafe marker (spec §4.4).  Returns a
    process exit code; prints nothing on success."""
    if not confirm:
        sys.stderr.write("palwarden_lifecycle: acknowledge-maintenance requires --confirm\n")
        return EX_USAGE
    if os.geteuid() != 0:
        sys.stderr.write("palwarden_lifecycle: acknowledge-maintenance requires root\n")
        return EX_NOTPERM
    try:
        fd = acquire(timeout=timeout)
    except _LockBusy as e:
        sys.stderr.write("palwarden_lifecycle: %s\n" % e)
        return EX_BUSY
    except LifecycleError as e:
        sys.stderr.write("palwarden_lifecycle: %s\n" % e)
        return EX_DATAERR
    # F7 (review follow-up): "is-active == inactive" alone is not proof the
    # operator got the server back down — an enabled unit in systemd crash
    # backoff also reports inactive while the supervisor still wants the game
    # up.  Acknowledgement requires the CONFIRMED wanted-down state from
    # service_state() (systemd: inactive + disabled; s6: down + wanted-down
    # marker).  This path only ever reads supervisor state; it never starts
    # the game.
    service = os.environ.get("PALWARDEN_LIFECYCLE_SERVICE") or DEFAULT_SERVICE
    state = service_state(service)
    try:
        if state != "stopped":
            sys.stderr.write(
                "palwarden_lifecycle: refusing: %s is not confirmed "
                "stopped/wanted-down (service_state=%r)\n" % (service, state)
            )
            try:
                release(fd)
            except LifecycleError:
                pass
            return EX_BUSY
        # force=True: ack is the one operator-sanctioned exit from unsafe.
        write_state("idle", rotate=True, force=True)
    except LifecycleError as e:
        sys.stderr.write("palwarden_lifecycle: %s\n" % e)
        try:
            os.close(fd)
        except OSError:
            pass
        return EX_DATAERR
    try:
        release(fd)
    except LifecycleError:
        pass
    return 0


def _cmd_complete(args):
    """Close an outer transaction: `complete <rc>` -> idle (0) / unsafe (!0).

    Called from the owner script's EXIT trap (lib/palwarden-lifecycle-bash).
    Best-effort and sticky-unsafe-safe: an unacknowledged marker is never
    cleared here, and a failure to record completion is loud but must not
    alter the controller's own exit code (the trap discards ours).
    """
    if len(args) != 1:
        sys.stderr.write(USAGE)
        return EX_USAGE
    try:
        rc = int(args[0])
    except ValueError:
        sys.stderr.write("palwarden_lifecycle: complete needs an integer exit code\n")
        return EX_USAGE
    try:
        write_state("idle" if rc == 0 else "unsafe")
    except UnsafeMaintenanceError:
        pass  # sticky: recovery stays explicit; nothing to warn about
    except LifecycleError as e:
        sys.stderr.write("palwarden_lifecycle: warning: completion not "
                         "recorded (%s); wake stays fenced until ack\n" % e)
    return 0


def _cmd_acknowledge(args):
    confirm = False
    for a in args:
        if a == "--confirm":
            confirm = True
        else:
            sys.stderr.write(USAGE)
            return EX_USAGE
    return acknowledge_maintenance(confirm=confirm)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        sys.stderr.write(USAGE)
        return EX_USAGE
    verb, rest = argv[0], argv[1:]
    if verb == "acquire":
        return _cmd_acquire(rest)
    if verb == "release":
        return _cmd_release(rest)
    if verb == "borrowed":
        return _cmd_borrowed(rest)
    if verb == "state":
        return _cmd_state(rest)
    if verb == "init-runtime":
        return _cmd_init_runtime(rest)
    if verb == "complete":
        return _cmd_complete(rest)
    if verb == "acknowledge-maintenance":
        return _cmd_acknowledge(rest)
    sys.stderr.write(USAGE)
    return EX_USAGE


if __name__ == "__main__":
    sys.exit(main())
