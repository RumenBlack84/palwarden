#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# These rules are the security boundary for import: root unpacks whatever the
# operator uploads. The name check is the primary control (round-trip only), and
# the member rules are defence in depth. Every refusal below is mutation-checked
# in the task's steps, because a refusal test that cannot fail is worse than none.
#
# Each hostile case is built so that exactly *one* rule refuses it — hence both
# `../escaped.sav` (refused at the archive root) and `SaveGames/../../escaped.sav`
# (a legal top-level, so only the `..` rule can catch it). Overlapping cases pass
# with a rule deleted, which is how an unfalsifiable check survives review.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
LIB="$DIR/../../lib"

WORK="$(mktemp -d)"
# fd 9 is used below to hold a FIFO writer open; close it here too so a failed
# assertion (which does not abort the script, but a stray early exit might)
# can never leak it past this script's lifetime.
trap 'exec 9>&- 2>/dev/null; rm -rf "$WORK"' EXIT

py() { PYTHONPATH="$LIB" python3 -c "$1"; }

# --- name pattern ----------------------------------------------------------
out="$(py '
import palwarden_archive as a
good = "palworld-save-20260727T101500Z.tar.gz"
assert a.valid_archive_name(good), good
bad = [
    "palworld-save-20260727T101500Z.tar",        # wrong extension
    "palworld-save-2026-07-27T101500Z.tar.gz",   # wrong stamp shape
    "palworld-save-20260727T101500Z.tar.gz.bak",
    "../palworld-save-20260727T101500Z.tar.gz",
    "sub/palworld-save-20260727T101500Z.tar.gz",
    "/abs/palworld-save-20260727T101500Z.tar.gz",
    "palworld-save-20260727T101500Z.tar.gz\n",
    "", "palworld-save-.tar.gz", "anything.tar.gz",
]
for name in bad:
    assert not a.valid_archive_name(name), name
assert not a.valid_archive_name(None)
assert not a.valid_archive_name(b"palworld-save-20260727T101500Z.tar.gz")
print("ok")')"
assert_eq "$out" "ok" "the name pattern accepts only what palworld-backup writes"

# --- a legitimate archive validates ---------------------------------------
mkdir -p "$WORK/src/SaveGames/abc" "$WORK/src/Config"
echo save > "$WORK/src/SaveGames/abc/Level.sav"
echo cfg  > "$WORK/src/Config/PalWorldSettings.ini"
tar -C "$WORK/src" -czf "$WORK/good.tar.gz" SaveGames Config
out="$(py "
import palwarden_archive as a
info = a.validate_archive('$WORK/good.tar.gz')
assert info['members'] > 0, info
assert info['bytes'] > 0, info
print('ok')")"
assert_eq "$out" "ok" "a real palworld-backup-shaped archive validates"

# --- hostile members are refused ------------------------------------------
# Built with python tarfile, not tar(1), so each member name is byte-for-byte
# what we intend — tar normalises `..` and leading slashes away. One script
# writes them all: passing python bodies through a heredoc argument (as the plan
# sketched) put the test's own security cases at the mercy of shell quoting.
cat > "$WORK/build_hostile.py" <<'PYEOF'
import io
import sys
import tarfile

out = sys.argv[1]


def build(name, populate):
    with tarfile.open(f"{out}/{name}.tar.gz", "w:gz") as tf:
        populate(tf)


def reg(tf, name, mode=0o644, data=b""):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    tf.addfile(info, io.BytesIO(data))


def special(tf, name, kind, **attrs):
    info = tarfile.TarInfo(name)
    info.type = kind
    for key, value in attrs.items():
        setattr(info, key, value)
    tf.addfile(info)


# `..` at the archive root, and `..` below a legitimate top-level: the second is
# the case that isolates the `..` rule from the top-level rule.
build("traverse", lambda tf: reg(tf, "../escaped.sav"))
build("traverse_inner", lambda tf: reg(tf, "SaveGames/../../escaped.sav"))
# An absolute path nowhere near the save tree, and one whose first *named*
# component is allowed — the latter isolates the absolute-path rule.
build("absolute", lambda tf: reg(tf, "/etc/shadow"))
build("absolute_allowed", lambda tf: reg(tf, "/SaveGames/abc/Level.sav"))
# Member types we never write. All sit under a legal top-level with a clean
# relative name, so only the member-type rule can refuse them.
build("symlink", lambda tf: special(tf, "SaveGames/link", tarfile.SYMTYPE,
                                    linkname="/etc/shadow"))
build("hardlink", lambda tf: special(tf, "SaveGames/hard", tarfile.LNKTYPE,
                                     linkname="../../../etc/shadow"))
build("device", lambda tf: special(tf, "SaveGames/dev", tarfile.CHRTYPE,
                                   devmajor=1, devminor=3))
build("fifo_member", lambda tf: special(tf, "SaveGames/pipe", tarfile.FIFOTYPE))
# A clean relative regular file in a tree we never back up.
build("outside", lambda tf: reg(tf, "Elsewhere/thing.sav"))
# Passes every rule above; only filter="data" stops the setuid bit landing.
build("setuid", lambda tf: reg(tf, "SaveGames/abc/evil.sav", mode=0o4755,
                              data=b"hi"))
PYEOF
python3 "$WORK/build_hostile.py" "$WORK" || fail "could not build the hostile archives"

for kind in traverse traverse_inner absolute absolute_allowed symlink hardlink \
            device fifo_member outside; do
  out="$(py "
import palwarden_archive as a
try:
    a.validate_archive('$WORK/$kind.tar.gz'); print('ACCEPTED')
except a.ArchiveError as e:
    print('refused')" 2>/dev/null)"
  assert_eq "$out" "refused" "refuses a $kind member"
done

# --- caps ------------------------------------------------------------------
out="$(py "
import palwarden_archive as a
try:
    a.validate_archive('$WORK/good.tar.gz', max_members=1); print('ACCEPTED')
except a.ArchiveError:
    print('refused')")"
assert_eq "$out" "refused" "refuses an archive over the member cap"
out="$(py "
import palwarden_archive as a
try:
    a.validate_archive('$WORK/good.tar.gz', max_bytes=1); print('ACCEPTED')
except a.ArchiveError:
    print('refused')")"
assert_eq "$out" "refused" "refuses an archive over the uncompressed-size cap"

# The caps are ceilings: a junk or non-positive override must not silently
# become "refuse everything" or "no limit".
out="$(PALWARDEN_ARCHIVE_MAX_MEMBERS=0 PALWARDEN_ARCHIVE_MAX_BYTES=nope \
  PYTHONPATH="$LIB" python3 -c "
import palwarden_archive as a
print(a.MAX_MEMBERS, a.MAX_UNCOMPRESSED_BYTES)")"
assert_eq "$out" "200000 21474836480" "a bad cap override falls back to the default"
out="$(PALWARDEN_ARCHIVE_MAX_MEMBERS=5 PYTHONPATH="$LIB" python3 -c "
import palwarden_archive as a
print(a.MAX_MEMBERS)")"
assert_eq "$out" "5" "the member cap is overridable from the environment"

# --- non-regular and symlinked archive files ------------------------------
ln -s "$WORK/good.tar.gz" "$WORK/link.tar.gz"
out="$(py "
import palwarden_archive as a
try:
    a.validate_archive('$WORK/link.tar.gz'); print('ACCEPTED')
except a.ArchiveError:
    print('refused')")"
assert_eq "$out" "refused" "refuses a symlinked archive file"

mkfifo "$WORK/fifo.tar.gz"
out="$(timeout 5 env PYTHONPATH="$LIB" python3 -c "
import palwarden_archive as a
try:
    a.validate_archive('$WORK/fifo.tar.gz'); print('ACCEPTED')
except a.ArchiveError as e:
    print('refused:', e)"; echo "rc=$?")"
assert_contains "$out" "refused" "refuses a FIFO promptly instead of blocking forever"
assert_not_contains "$out" "rc=124" "did not hang on the FIFO"
# The *reason* matters, not just the refusal: a FIFO reads as EOF, so without the
# S_ISREG check it would still be refused — as an unreadable gzip stream, several
# layers later. Pinning the message is what makes that check falsifiable.
assert_contains "$out" "not a regular file" "the FIFO is refused by the S_ISREG check itself"

# The case above has no writer, so a FIFO open reads EOF almost immediately even
# without S_ISREG catching it — that is *not* the case this check exists for.
# The dangerous case is a writer that stays open: once O_NONBLOCK is cleared,
# nothing but S_ISREG stands between that and a read() that never returns. Hold
# the write end open for the whole call so there is no EOF to rescue a
# regression that drops the S_ISREG branch.
mkfifo "$WORK/fifo_held.tar.gz"
exec 9<>"$WORK/fifo_held.tar.gz"
# Real (valid) gzip magic plus a few header/deflate bytes — enough for gzip to
# commit to decompressing rather than fail fast on bad magic, and not enough to
# finish, so a read with no S_ISREG guard has to wait for bytes that never come.
head -c 20 "$WORK/good.tar.gz" >&9
out="$(timeout 5 env PYTHONPATH="$LIB" python3 -c "
import palwarden_archive as a
try:
    a.validate_archive('$WORK/fifo_held.tar.gz'); print('ACCEPTED')
except a.ArchiveError as e:
    print('refused:', e)"; echo "rc=$?")"
exec 9>&-
assert_not_contains "$out" "rc=124" \
  "does not hang on a FIFO whose writer stays open the whole call"
assert_contains "$out" "not a regular file" \
  "the writer-held FIFO is refused by S_ISREG, not by an eventual EOF"

# A directory at the archive path is the same class of mistake and must not
# surface as a traceback either.
mkdir "$WORK/dir.tar.gz"
out="$(py "
import palwarden_archive as a
try:
    a.validate_archive('$WORK/dir.tar.gz'); print('ACCEPTED')
except a.ArchiveError:
    print('refused')")"
assert_eq "$out" "refused" "refuses a directory at the archive path"

# A truncated upload is a clean refusal, not a traceback out of tarfile.
head -c 40 "$WORK/good.tar.gz" > "$WORK/truncated.tar.gz"
out="$(py "
import palwarden_archive as a
try:
    a.validate_archive('$WORK/truncated.tar.gz'); print('ACCEPTED')
except a.ArchiveError:
    print('refused')" 2>&1)"
assert_eq "$out" "refused" "refuses a truncated archive without a traceback"

# --- extraction writes nothing outside dest -------------------------------
mkdir -p "$WORK/dest"
out="$(py "
import palwarden_archive as a
info = a.extract_archive('$WORK/good.tar.gz', '$WORK/dest')
print('ok' if info['members'] > 0 else 'bad')")"
assert_eq "$out" "ok" "a good archive extracts"
assert_file_exists "$WORK/dest/SaveGames/abc/Level.sav" "extraction produced the save"
assert_file_exists "$WORK/dest/Config/PalWorldSettings.ini" "extraction produced the config"

for kind in traverse traverse_inner; do
  rm -rf "$WORK/dest2"; mkdir -p "$WORK/dest2"
  out="$(py "
import palwarden_archive as a
try:
    a.extract_archive('$WORK/$kind.tar.gz', '$WORK/dest2'); print('ACCEPTED')
except a.ArchiveError:
    print('refused')")"
  assert_eq "$out" "refused" "extraction refuses a $kind member"
  assert_path_absent "$WORK/escaped.sav" "nothing was written outside dest ($kind)"
done

# --- filter="data" is the last line of defence ----------------------------
# The setuid member satisfies every rule above, so if extraction ever ran
# unfiltered the bit would land on disk. Python 3.14 makes `data` the default,
# but the image ships 3.13 where it is not.
mkdir -p "$WORK/dest3"
out="$(py "
import palwarden_archive as a
a.extract_archive('$WORK/setuid.tar.gz', '$WORK/dest3')
print('ok')")"
assert_eq "$out" "ok" "the setuid-bearing archive extracts (its name breaks no rule)"
out="$(py "
import os, stat
mode = os.stat('$WORK/dest3/SaveGames/abc/evil.sav').st_mode
print('stripped' if not mode & (stat.S_ISUID | stat.S_ISGID) else oct(mode))")"
assert_eq "$out" "stripped" "extraction strips setuid/setgid bits"

assert_report
