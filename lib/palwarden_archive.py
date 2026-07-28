# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
"""Shared rules for the world-save archives the backup panel exports and imports.

Export is ours; **import is not**. The bytes arrive over HTTP from a browser and
are ultimately unpacked by *root* (the unprivileged web process only stores the
upload; `palwarden-jobd` runs the restore), so every rule about what an archive
may contain lives here once and is imported by both sides rather than copied into
each tool, where the two copies would drift and only one would get the next fix.

Import is deliberately **round-trip only**: the only archives we accept are ones
this project itself wrote. That makes `ARCHIVE_RE` the primary control — a name
that palworld-backup could not have produced is refused before a single byte is
read. The member rules and `filter="data"` are defence in depth behind it, for the
case where an operator-supplied archive carries the right name and hostile
contents: `..` traversal, absolute paths, symlinks or hardlinks aimed outside the
destination, devices and FIFOs, setuid bits, or a decompression bomb.

The *archive file itself* is attacker-influenced too, which is why
`open_archive_fd` exists instead of a plain `open()`: it may be a symlink pointing
at something root should not read, or a FIFO, which makes the `open()` itself
block forever. This repo has already lost a root poll loop to a planted FIFO once
(see `_read_job_text` in palwarden_jobs), hence the same shape here — let the
kernel decide at the moment of use, and never re-open a name we have checked.
"""

from __future__ import annotations

import fcntl
import os
import re
import stat
import tarfile

# Exactly what palworld-backup writes: `palworld-save-<UTC stamp>.tar.gz`.
ARCHIVE_RE = re.compile(r"^palworld-save-[0-9]{8}T[0-9]{6}Z\.tar\.gz$")

# The only two trees a save archive may contain. Everything else — including a
# member at the archive root — is not something we produced.
ALLOWED_TOPLEVEL = ("SaveGames", "Config")


def env_int(name: str, default: int) -> int:
    """A positive int from the environment, falling back to `default`.

    Both caps are ceilings, so a malformed or non-positive override must not be
    able to *lower* one to zero (which would refuse every archive) or turn a
    typo into "no limit". A bad value is simply the default.

    Generic enough that other tools reuse it (`palworld-restore`'s upload-size
    and free-space ceilings), which is why it is public rather than a private
    helper reached into from outside this module.
    """
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


# Kept as an alias, not just renamed: nothing outside this module used the old
# name, but the alias costs one line and avoids hunting for a straggler import.
_env_int = env_int


# Decompression-bomb ceilings. A save tree is a few thousand files and a few
# hundred MiB, so these are orders of magnitude of headroom over anything
# legitimate; they exist so a 20 KiB upload cannot fill the data volume or spin
# root for hours. Both are enforced while *iterating headers*, before any member
# is written, so hitting a cap costs nothing.
MAX_MEMBERS = env_int("PALWARDEN_ARCHIVE_MAX_MEMBERS", 200000)
MAX_UNCOMPRESSED_BYTES = env_int("PALWARDEN_ARCHIVE_MAX_BYTES", 20 * 1024**3)


class ArchiveError(Exception):
    """An archive we refuse to trust. Every rejection path raises this one type.

    Callers (the web handler, the restore job) turn it into an operator-visible
    message, so a truncated upload or a corrupt gzip stream must arrive here as
    an ArchiveError too, not as a traceback out of tarfile.
    """


class NotARegularFileError(ArchiveError):
    """The path exists but is a FIFO, directory, device, or other non-regular
    entry — raised only by `open_archive_fd`'s `S_ISREG` check.

    A subclass, not a sibling: every existing `except ArchiveError` still
    catches this, so no caller needs to change. It exists so a caller that
    cares about *this specific* refusal (as opposed to "does not exist" or
    "cannot be opened at all") can say so by type instead of pattern-matching
    the message or introspecting `__cause__` — see `palworld-backups`'
    `read_schedule`, which needs exactly that distinction to phrase its own
    warning without borrowing this module's "archive" vocabulary for a file
    that is not one.
    """


def valid_archive_name(name: str) -> bool:
    """True only for a bare filename palworld-backup could have written.

    `fullmatch`, not `match`: a trailing newline or `.bak` suffix must not be
    accepted, and the pattern has no `/` in it, so any directory component or
    leading `..` fails here rather than in a later path join.
    """
    if not isinstance(name, str):
        return False
    return ARCHIVE_RE.fullmatch(name) is not None


def open_archive_fd(path) -> int:
    """Open an archive file for reading, or raise ArchiveError.

    Three properties, all decided by the kernel or by fstat on the descriptor we
    will actually read — never by a check on a name we then re-open:

      * O_NOFOLLOW: a symlink at `path` would otherwise let whoever can create
        that name choose which file root reads and restores from.
      * O_NONBLOCK: this is what stops a planted FIFO blocking *inside* the
        open, before any of our code runs. The S_ISREG check below cannot do it,
        because without O_NONBLOCK it is never reached.
      * S_ISREG: O_NONBLOCK is cleared a few lines below, before tarfile ever
        reads from this descriptor. From that point on, S_ISREG is the *only*
        thing standing between the root worker and an indefinite read: a FIFO
        with a writer that keeps the other end open (never closes, never sends
        EOF) blocks a blocking read forever, exactly like the open() itself
        would without O_NONBLOCK. Rejecting non-regular files here, while the
        descriptor is still non-blocking, is what makes clearing O_NONBLOCK
        safe. It also means the refusal says what is wrong instead of
        surfacing as a mystery gzip error several layers later.

    **Exception contract, part of this function's interface, not an
    implementation detail:** the `os.open` failure branch below always chains
    the original `OSError` via `from exc` — `ENOENT`, `EACCES`, `ELOOP` on a
    symlink, all of them — so `except ... as exc: isinstance(exc.__cause__,
    FileNotFoundError)` is a supported way to ask "did the path simply not
    exist?" The `S_ISREG` refusal is different in kind, not merely in
    wording: the path exists and opened fine, it is just the wrong kind of
    thing, so it raises the `NotARegularFileError` subclass instead, with no
    `__cause__` to inspect. Callers that need to tell "missing" from "wrong
    type" from "everything else" apart should match on cause and on type, not
    on message text.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as exc:
        # ELOOP here is the symlink refusal; ENOENT/EACCES are ordinary.
        raise ArchiveError(f"cannot open archive {path}: {exc}") from exc
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise NotARegularFileError(f"archive is not a regular file; refused: {path}")
        # Drop O_NONBLOCK now the descriptor is known to be a regular file. It
        # was only ever there to survive the open; leaving it set would hand
        # tarfile a descriptor whose reads can in principle short-return, which
        # is a subtlety no reader of this code should have to reason about.
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    except OSError as exc:
        os.close(fd)
        raise ArchiveError(f"cannot inspect archive {path}: {exc}") from exc
    except BaseException:
        os.close(fd)
        raise
    return fd


def _check_member(member: tarfile.TarInfo) -> None:
    """Refuse a member that a palworld-backup archive would never contain.

    Each rule owns exactly one property and deliberately does *not* double as
    another: the top-level rule looks at the first *named* component and leaves
    the leading slash to the absolute-path rule. Overlapping rules feel safer but
    make each one individually unfalsifiable — the suite still passes with one
    deleted — and a check no test can fail is a check that gets deleted by
    accident. They are all mutation-checked in tests/unit/test_archive_rules.sh.
    """
    name = member.name
    # Refused by *type*, before any name reasoning: a symlink or hardlink can
    # point anywhere (including outside the destination, or at a file the
    # restore then overwrites through), and a device or FIFO has no place in a
    # world save at all. We only ever wrote files and directories.
    if not (member.isreg() or member.isdir()):
        raise ArchiveError(f"archive member is not a file or directory: {name!r}")
    if name.startswith("/"):
        raise ArchiveError(f"archive member has an absolute path: {name!r}")
    # Component-wise, not a substring search: a file legitimately called
    # `..sav` is fine, `SaveGames/../../etc` is not.
    if ".." in name.split("/"):
        raise ArchiveError(f"archive member escapes the destination: {name!r}")
    if name.lstrip("/").split("/")[0] not in ALLOWED_TOPLEVEL:
        raise ArchiveError(f"archive member is outside {ALLOWED_TOPLEVEL}: {name!r}")


def validate_archive_fileobj(fh, label, *, max_members: int, max_bytes: int) -> dict:
    """Check every member readable from `fh`, returning {"members", "bytes"}.

    Raises ArchiveError naming the offending member, with `label` (a path or
    anything else identifying the archive to a human) folded into the message.

    **The caller owns proving `fh` is safe to read.** This function trusts the
    descriptor it is given completely — it does no symlink, FIFO, or regular-
    file check of its own. A caller that opens `label` itself with a plain
    `open(path, "rb")` bypasses every one of `open_archive_fd`'s refusals (the
    symlink that lets an unprivileged writer choose what root reads, the FIFO
    that blocks a root process forever) and hands them straight to `tarfile`.
    The only safe way to obtain `fh` is `os.fdopen(open_archive_fd(path), ...)`,
    or a `dup` of a descriptor that itself came from there.
    """
    members = 0
    total = 0
    try:
        with tarfile.open(fileobj=fh, mode="r:gz") as tf:
            # Stream the headers rather than getmembers(): on a bomb we want to
            # stop at the cap, not build a list of every entry first.
            for member in tf:
                _check_member(member)
                members += 1
                if members > max_members:
                    raise ArchiveError(
                        f"archive has more than {max_members} members; refused: {label}")
                # Directories and short reads report 0 or (in a crafted header) a
                # negative size; max() keeps a negative size from crediting back
                # against the running total.
                total += max(member.size, 0)
                if total > max_bytes:
                    raise ArchiveError(
                        f"archive expands to more than {max_bytes} bytes; "
                        f"refused: {label}")
    except ArchiveError:
        raise
    except (tarfile.TarError, OSError, EOFError) as exc:
        # A truncated upload, a corrupt gzip stream or a read error is a clean
        # refusal, not a traceback out of the root worker.
        raise ArchiveError(f"unreadable archive {label}: {exc}") from exc
    return {"members": members, "bytes": total}


def validate_archive(path, max_members=MAX_MEMBERS,
                     max_bytes=MAX_UNCOMPRESSED_BYTES) -> dict:
    """Check every member of `path`, returning {"members", "bytes"}.

    Raises ArchiveError naming the offending member. Reads nothing but headers,
    and writes nothing at all, so it is safe to call on an upload before
    deciding whether to keep it.

    A thin wrapper: it is `open_archive_fd` (the part that refuses a symlink or
    a FIFO by construction) followed by `validate_archive_fileobj`, kept as one
    call so a caller with only a path never has to get the fd-safety obligation
    right themselves.
    """
    fd = open_archive_fd(path)
    try:
        fh = os.fdopen(fd, "rb")
    except OSError as exc:
        os.close(fd)
        raise ArchiveError(f"cannot read archive {path}: {exc}") from exc
    with fh:
        return validate_archive_fileobj(
            fh, path, max_members=max_members, max_bytes=max_bytes)


def extract_archive(path, dest_dir, max_members=MAX_MEMBERS,
                    max_bytes=MAX_UNCOMPRESSED_BYTES) -> dict:
    """Validate `path`, then unpack it under `dest_dir`. Raises ArchiveError.

    The validation pass and the extraction pass run over the **same descriptor**
    (rewound in between) rather than opening the path twice. Re-opening would
    leave a window in which the *name* that was validated is not the *name* that
    gets extracted — and the upload directory is writable by the web process, so
    that window is reachable, not theoretical. This guarantees the name but not
    the bytes: an attacker who rewrites the same inode in place between the two
    passes still gets pass-2 content that pass-1 never saw. The caller carries
    that risk — it must ensure the archive cannot be rewritten between
    validation and extraction, e.g. by only ever extracting from a location the
    unprivileged web process cannot write to.

    `filter="data"` is the kernel-of-last-resort under our own rules: it is what
    strips setuid/setgid bits and refuses links out of the destination even if a
    rule above is ever loosened. Python 3.14 makes `data` the default, but the
    image ships 3.13 where the default is still the unfiltered legacy behaviour,
    so it is passed explicitly.
    """
    # Checked up front, not by catching the TypeError extractall(filter=...)
    # would raise on an old Python: catching it around the whole block would
    # also catch a TypeError raised from *inside* extractall on a crafted
    # archive, and misreport that as an interpreter problem instead of the
    # crafted-archive bug it actually is. Checked before opening anything, so
    # there is no descriptor to leak on the way out.
    if not hasattr(tarfile, "data_filter"):
        raise ArchiveError(
            f"this Python cannot filter tar extraction; refusing to extract {path}")
    fd = open_archive_fd(path)
    try:
        fh = os.fdopen(fd, "rb")
    except OSError as exc:
        os.close(fd)
        raise ArchiveError(f"cannot read archive {path}: {exc}") from exc
    with fh:
        info = validate_archive_fileobj(
            fh, path, max_members=max_members, max_bytes=max_bytes)
        fh.seek(0)
        try:
            with tarfile.open(fileobj=fh, mode="r:gz") as tf:
                tf.extractall(dest_dir, filter="data")
        except (tarfile.TarError, OSError, EOFError) as exc:
            raise ArchiveError(f"failed to extract {path}: {exc}") from exc
    return info
