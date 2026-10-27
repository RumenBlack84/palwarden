#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
"""Shared configuration contract for idle-shutdown / knock-wake.

Single owner of the five idle-shutdown knobs so the bash ops job, the
config API, and the Web UI never drift apart. Resolution order is
canonical ops file, then environment, then built-in default; the token is
always explicit (empty means no knock endpoint).

The file format is one canonical JSON-quoted string value per line, keys
exactly once in schema order. Strings are JSON data, never shell:
json.dumps()/json.loads() both sides, so values are inert data on disk
and in memory. The writer is atomic (same-directory temp + rename),
validates before writing, never follows symlinks, and leaves the previous
file byte-identical on failure.

See docs/superpowers/specs/2026-10-18-idle-shutdown-knock-wake.md §7.1.
"""

import grp
import json
import os
import re
import secrets
import stat
import sys
import unicodedata
from pathlib import Path

__all__ = [
    "ConfigError",
    "KEYS",
    "DEFAULTS",
    "FILE_MODE",
    "TOKEN_MAX_BYTES",
    "OPS_FILE",
    "canonical",
    "typed",
    "resolve",
    "render",
    "parse_file",
    "merge",
    "public_view",
    "write_config",
    "seed_if_absent",
]


class ConfigError(ValueError):
    """Invalid config value, malformed file, or unsafe write target."""


# (key, kind, lo, hi, default) — order is the file schema order.
SCHEMA = (
    ("IDLE_TIMEOUT", "int", 0, 10_080, 0),
    ("IDLE_CHECK_INTERVAL", "int", 1, 3_600, 60),
    ("KNOCK_ENABLED", "bool", None, None, True),
    ("KNOCK_COOLDOWN", "int", 1, 86_400, 600),
    ("KNOCK_TOKEN", "token", None, None, ""),
)
KEYS = tuple(key for key, *_ in SCHEMA)
SPEC = {key: (kind, lo, hi, dflt) for key, kind, lo, hi, dflt in SCHEMA}
DEFAULTS = {key: dflt for key, _, _, _, dflt in SCHEMA}

TOKEN_MAX_BYTES = 512
FILE_MODE = 0o640
OPS_FILE = Path(os.environ.get("PALWARDEN_OPS_FILE", "/etc/palworld/palwarden.env"))

_INT_RE = re.compile(r"0|[1-9][0-9]*")
_LINE_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")


def canonical(key, value):
    """Coerce API/env input to the canonical string stored on disk.

    Canonical ints are ``0`` or ``[1-9][0-9]*`` within range; bools are the
    strict strings ``true``/``false``; tokens are non-empty-checked UTF-8
    within TOKEN_MAX_BYTES with no C0/C1 control characters. Raises
    ConfigError naming the key on any violation.
    """
    try:
        kind, lo, hi, _ = SPEC[key]
    except KeyError:
        raise ConfigError(f"unknown config key: {key}") from None
    if kind == "int":
        if isinstance(value, bool):
            raise ConfigError(f"{key}: expected an integer, got a boolean")
        if isinstance(value, int):
            value = str(value)
        if not isinstance(value, str) or _INT_RE.fullmatch(value) is None:
            raise ConfigError(f"{key}: not a canonical integer: {value!r}")
        n = int(value)
        if not lo <= n <= hi:
            raise ConfigError(f"{key}: out of range {lo}..{hi}: {n}")
        return value
    if kind == "bool":
        if isinstance(value, bool):
            return "true" if value else "false"
        if value in ("true", "false"):
            return value
        raise ConfigError(f'{key}: expected strict "true"/"false": {value!r}')
    # token
    if not isinstance(value, str):
        raise ConfigError(f"{key}: expected a string, got {type(value).__name__}")
    size = len(value.encode("utf-8"))
    if size > TOKEN_MAX_BYTES:
        raise ConfigError(f"{key}: exceeds {TOKEN_MAX_BYTES} bytes: {size}")
    for ch in value:
        if unicodedata.category(ch) == "Cc":
            raise ConfigError(f"{key}: contains a control character {ord(ch):#x}")
    return value


def typed(key, value):
    """Coerce input to the in-memory type (int/bool/str); validates."""
    canon = canonical(key, value)
    kind = SPEC[key][0]
    if kind == "int":
        return int(canon)
    if kind == "bool":
        return canon == "true"
    return canon


def _full(config, label="config"):
    """Validate that config covers every key exactly once; return typed."""
    if not isinstance(config, dict):
        raise ConfigError(f"{label} must be a mapping")
    keys = set(config)
    if keys != set(KEYS):
        detail = []
        missing = ", ".join(k for k in KEYS if k not in keys)
        extra = ", ".join(k for k in keys if k not in KEYS)
        if missing:
            detail.append(f"missing: {missing}")
        if extra:
            detail.append(f"unexpected: {extra}")
        raise ConfigError(f"{label} is not complete ({'; '.join(detail)})")
    return {k: typed(k, config[k]) for k in KEYS}


def parse_file(path):
    """Parse and validate the canonical data file; return raw string values.

    Strict: UTF-8, one line per key, every value a JSON-quoted string that
    is canonical under json.dumps (no surrounding whitespace), keys exactly
    once in schema order, all values in range. Raises ConfigError otherwise.
    """
    path = Path(path)
    try:
        st = os.lstat(path)
    except OSError as exc:
        raise ConfigError(
            f"cannot read config file {path}: {exc.strerror or exc}"
        ) from None
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        raise ConfigError(f"config path is not a regular file: {path}")
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise ConfigError(
            f"cannot read config file {path}: {exc.strerror or exc}"
        ) from None
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise ConfigError(f"config file is not valid UTF-8: {path}") from None
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines or any(line == "" for line in lines):
        raise ConfigError(f"config file is empty or has a blank line: {path}")
    seen = {}
    for idx, line in enumerate(lines, 1):
        m = _LINE_RE.match(line)
        if m is None:
            raise ConfigError(
                f"config line {idx} is not KEY=<JSON string>: {path}"
            )
        key, val = m.group(1), m.group(2)
        if key not in SPEC:
            raise ConfigError(f"unknown config key: {key}")
        if key in seen:
            raise ConfigError(f"duplicate config key: {key}")
        try:
            canon = json.loads(val)
        except ValueError:
            raise ConfigError(
                f"config value for {key} is not a JSON string: {path}"
            ) from None
        if not isinstance(canon, str):
            raise ConfigError(f"config value for {key} is not a JSON string: {path}")
        if json.dumps(canon, ensure_ascii=True) != val:
            raise ConfigError(f"config value for {key} is not canonical: {path}")
        seen[key] = canon
    if list(seen) != list(KEYS):
        raise ConfigError(
            f"config keys must appear exactly once in schema order: {path}"
        )
    for key in KEYS:
        typed(key, seen[key])
    return seen


def resolve(path=None, env=None):
    """Resolve the five knobs to typed values.

    Order: data file (if it exists), else env, else default. A present
    file is authoritative and fully validated — an invalid file raises
    ConfigError (fail closed) rather than falling back. Empty env values
    select the built-in default for non-secret keys; KNOCK_TOKEN is always
    explicit.
    """
    if path is None:
        path = OPS_FILE
    path = Path(path)
    env = os.environ if env is None else env
    filevals = None
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        st = None
    if st is not None:
        filevals = parse_file(path)
    out = {}
    for key in KEYS:
        kind, _lo, _hi, dflt = SPEC[key]
        if filevals is not None:
            out[key] = typed(key, filevals[key])
            continue
        raw = env.get(key)
        if key == "KNOCK_TOKEN":
            out[key] = typed(key, "" if raw is None else raw)
        elif raw is None or raw == "":
            out[key] = dflt
        else:
            out[key] = typed(key, raw)
    return out


def render(config, *, label="config"):
    """Render a full config to exact canonical file bytes (ASCII)."""
    c = _full(config, label)
    return "".join(
        f"{k}={json.dumps(canonical(k, c[k]), ensure_ascii=True)}\n" for k in KEYS
    )


def merge(current, supplied):
    """Merge a partial API payload against the current full typed config.

    Omitted keys keep current values (in particular KNOCK_TOKEN is not
    clobbered when absent). Validates every supplied value.
    """
    cur = _full(current, "current config")
    if not isinstance(supplied, dict):
        raise ConfigError("supplied config must be a mapping")
    out = dict(cur)
    for key, value in supplied.items():
        if key not in SPEC:
            raise ConfigError(f"unknown config key: {key}")
        out[key] = typed(key, value)
    return out


def public_view(config):
    """Four non-secret fields plus token_configured; never the token."""
    c = _full(config, "config")
    return {
        "IDLE_TIMEOUT": c["IDLE_TIMEOUT"],
        "IDLE_CHECK_INTERVAL": c["IDLE_CHECK_INTERVAL"],
        "KNOCK_ENABLED": c["KNOCK_ENABLED"],
        "KNOCK_COOLDOWN": c["KNOCK_COOLDOWN"],
        "token_configured": c["KNOCK_TOKEN"] != "",
    }


def _resolve_gid(group):
    if group is None:
        group = os.environ.get("PALWORLD_GROUP", "palworld")
    try:
        return grp.getgrnam(group).gr_gid
    except KeyError:
        raise ConfigError(f"cannot resolve config group: {group}") from None


def write_config(path, config, *, group=None):
    """Atomically write a validated config as 0640 creator:group.

    Refuses symlink targets, non-regular targets, and symlinked or missing
    parents; creates a same-directory temp file, writes, fsyncs, fchmods,
    fchowns, then renames. On any failure the previous file is left
    byte-identical and a ConfigError is raised.
    """
    text = render(config).encode("utf-8")
    gid = _resolve_gid(group)
    path = Path(path)
    parent = path.parent
    try:
        pst = os.lstat(parent)
    except OSError:
        raise ConfigError(f"config parent directory missing: {parent}") from None
    if stat.S_ISLNK(pst.st_mode) or not stat.S_ISDIR(pst.st_mode):
        raise ConfigError(f"config parent is not a directory: {parent}")
    try:
        tst = os.lstat(path)
    except FileNotFoundError:
        tst = None
    if tst is not None and (
        stat.S_ISLNK(tst.st_mode) or not stat.S_ISREG(tst.st_mode)
    ):
        raise ConfigError(f"config target is not a regular file: {path}")
    tmp = parent / f".{path.name}.{secrets.token_hex(8)}.tmp"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        raise ConfigError(f"config temp file already exists: {tmp}") from None
    except OSError as exc:
        raise ConfigError(
            f"cannot create config file {path}: {exc.strerror or exc}"
        ) from None
    try:
        try:
            os.write(fd, text)
            os.fchmod(fd, FILE_MODE)
            os.fchown(fd, -1, gid)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise ConfigError(
            f"cannot write config file {path}: {exc.strerror or exc}"
        ) from None
    try:
        dfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass  # directory fsync is best-effort


def seed_if_absent(path=None, config=None):
    """Create the ops file only if it does not exist; True when created."""
    if path is None:
        path = OPS_FILE
    path = Path(path)
    if os.path.lexists(path):
        return False
    write_config(path, config if config is not None else DEFAULTS)
    return True


# ---------------------------------------------------------------------------
# CLI (plan Task 10): the container entrypoint's seed path.  The module is the
# single renderer of the five keys (spec §7.1), so the entrypoint shells out to
# `python3 -m palwarden_ops seed` instead of re-serializing them in bash.
# ---------------------------------------------------------------------------

USAGE = """\
usage: python3 -m palwarden_ops <verb>

verbs:
  seed
      Seed the ops file IF ABSENT from the environment (IDLE_TIMEOUT,
      IDLE_CHECK_INTERVAL, KNOCK_ENABLED, KNOCK_COOLDOWN, KNOCK_TOKEN),
      writing the complete validated file through the shared writer.
      An existing file is never re-rendered (changed seeds do not
      override saved values) but IS validated: an invalid or unsafe
      existing file fails visibly and stays byte-identical, so a
      corrupt config can never boot silently into a half-applied
      state.  Exits 0 on success, 64 on a bad verb, 65 on invalid
      data (bad seed, invalid/unsafe file).
"""

EX_USAGE = 64
EX_DATAERR = 65


def _cmd_seed():
    path = OPS_FILE
    # lexists() is True for a dangling or pointing symlink; the writer
    # would refuse it anyway, but saying so here turns a silent
    # "seed_if_absent skipped it" into a visible boot failure.
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        st = None
    if st is not None and not stat.S_ISREG(st.st_mode):
        sys.stderr.write(
            "palwarden-ops: refusing unsafe ops file target (not a regular "
            "file): %s\n" % path
        )
        return EX_DATAERR
    try:
        config = resolve()  # env seeds when absent; validates an existing file
        created = seed_if_absent(path, config)
    except ConfigError as exc:
        sys.stderr.write("palwarden-ops: %s\n" % exc)
        return EX_DATAERR
    sys.stdout.write("seeded %s\n" % path if created else "exists %s\n" % path)
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv == ["seed"]:
        return _cmd_seed()
    sys.stderr.write(USAGE)
    return EX_USAGE


if __name__ == "__main__":
    sys.exit(main())
