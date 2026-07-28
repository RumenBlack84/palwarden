#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# `palworld-restore --import` promotes an upload out of the web-writable staging
# directory into the root-owned backups directory.
#
# The property this suite exists for is the **order** of the two passes.
# Validating the staged file and then copying it looks equivalent and is not: the
# unprivileged web process owns the staging file, so it can rewrite that *inode*
# in place (O_WRONLY without O_TRUNC, or pwrite) after our validation read and
# before our copy read. Holding a descriptor defeats a rename; it does not defeat
# a write. So the tool copies first and validates the copy, in a directory the web
# process cannot write — and the test below has to be able to tell the two
# orderings apart, or it is not testing this task at all.
#
# Every refusal here is pinned by *reason* where a weaker check would refuse the
# same input for a different reason (the symlink case, the separator case). That
# is the lesson of test_archive_rules.sh's FIFO case: a refusal test that still
# passes with the check deleted is worse than no test.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
LIB="$DIR/../../lib"
SBIN="$DIR/../../sbin"
RESTORE="$SBIN/palworld-restore"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UP="$WORK/uploads"
BK="$WORK/backups"
NAME="palworld-save-20260727T101500Z.tar.gz"

# One invocation shape for every case: the two directory overrides plus the lib
# on PYTHONPATH (the installed layout finds palwarden_archive in /usr/local/lib).
run() {
  PYTHONPATH="$LIB" PALWARDEN_UPLOAD_DIR="$UP" PALWARDEN_SAVE_BACKUP_DIR="$BK" \
    python3 "$RESTORE" "$@"
}

# Number of entries in the backups dir — dotfiles included, because the whole
# point of several assertions below is that no *temp* file is left behind either.
bk_entries() { find "$BK" -mindepth 1 2>/dev/null | wc -l | tr -d ' '; }

reset_dirs() {
  rm -rf "$UP" "$BK"
  mkdir -p "$UP" "$BK"
}

# A legitimately shaped archive, deliberately incompressible and ~200 KB, so it
# is comfortably longer than the hostile archive that gets pwritten over it in
# the ordering test below (leftover tail bytes past the hostile gzip member are
# never reached: tar stops at its end-of-archive blocks).
mkdir -p "$WORK/src/SaveGames/abc" "$WORK/src/Config"
head -c 200000 /dev/urandom > "$WORK/src/SaveGames/abc/Level.sav"
echo cfg > "$WORK/src/Config/PalWorldSettings.ini"
tar -C "$WORK/src" -czf "$WORK/good.tar.gz" SaveGames Config \
  || fail "could not build the good archive"

# The traversing tarball from Task 1's suite, built with python tarfile so the
# member name is byte-for-byte what we intend (tar(1) normalises `..` away).
cat > "$WORK/build_hostile.py" <<'PYEOF'
import io
import sys
import tarfile

out = sys.argv[1]
with tarfile.open(out, "w:gz") as tf:
    info = tarfile.TarInfo("../escaped.sav")
    data = b"pwned"
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PYEOF
python3 "$WORK/build_hostile.py" "$WORK/hostile.tar.gz" \
  || fail "could not build the hostile archive"

# --- argparse surface -------------------------------------------------------
run --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"
run --nonsense >/dev/null 2>&1
assert_ne "$?" "0" "an unknown flag exits non-zero"
run >/dev/null 2>&1
assert_ne "$?" "0" "no mode at all exits non-zero"

# --- the happy path ---------------------------------------------------------
reset_dirs
cp "$WORK/good.tar.gz" "$UP/$NAME"
out="$(run --import "$NAME" 2>"$WORK/err")"
rc=$?
assert_eq "$rc" "0" "a good staged archive is promoted (stderr: $(cat "$WORK/err"))"
assert_eq "$out" "$BK/$NAME" "the promoted path is printed on stdout"
assert_file_exists "$BK/$NAME" "the archive landed in the backups dir"
assert_path_absent "$UP/$NAME" "the staged file is removed on success"
assert_eq "$(bk_entries)" "1" "no temp file is left in the backups dir"
assert_eq "$(stat -c %a "$BK/$NAME")" "644" "the promoted archive is 0644"
assert_eq "$(cmp -s "$WORK/good.tar.gz" "$BK/$NAME" && echo same)" "same" \
  "the promoted bytes are the staged bytes"

# --- THE ordering property --------------------------------------------------
# Drive the tool's own functions and rewrite the staged inode *between* the two
# passes, which is exactly what the web process can do and what a
# validate-then-copy implementation would not survive. Nothing is stubbed out:
# the real copy and the real authoritative validation both run, the wrapper only
# interleaves the attacker's write.
cat > "$WORK/harness_rewrite.py" <<'PYEOF'
import importlib.machinery
import importlib.util
import os
import sys

restore_path, staged, hostile_path = sys.argv[1:4]

loader = importlib.machinery.SourceFileLoader("palworld_restore_under_test", restore_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

with open(hostile_path, "rb") as fh:
    hostile = fh.read()

original_copy = mod._copy_fd_to_temp


def rewriting_copy(fd, tmp_path, cap):
    # The staging directory belongs to the unprivileged web process. O_WRONLY
    # with no O_TRUNC keeps the same inode, so the descriptor the tool is holding
    # now refers to different bytes than the ones it just validated.
    wfd = os.open(staged, os.O_WRONLY)
    try:
        os.pwrite(wfd, hostile, 0)
    finally:
        os.close(wfd)
    return original_copy(fd, tmp_path, cap)


mod._copy_fd_to_temp = rewriting_copy
print("rc=%d" % mod.main(["--import", os.path.basename(staged)]))
PYEOF

reset_dirs
cp "$WORK/good.tar.gz" "$UP/$NAME"
out="$(PYTHONPATH="$LIB" PALWARDEN_UPLOAD_DIR="$UP" PALWARDEN_SAVE_BACKUP_DIR="$BK" \
  python3 "$WORK/harness_rewrite.py" "$RESTORE" "$UP/$NAME" "$WORK/hostile.tar.gz" 2>&1)"
assert_not_contains "$out" "rc=0" \
  "an archive rewritten in place between the passes is refused"
assert_contains "$out" "escaped.sav" \
  "the refusal names the member the *promoted copy* contains, not the staged one"
assert_eq "$(bk_entries)" "0" \
  "nothing at all is left in the backups dir after the rewrite is caught"
assert_file_exists "$UP/$NAME" "the rewritten staged file is left for inspection"

# --- an invalid name is refused before anything is touched ------------------
reset_dirs
cp "$WORK/good.tar.gz" "$UP/anything.tar.gz"
out="$(run --import "anything.tar.gz" 2>&1)"
rc=$?
assert_ne "$rc" "0" "a name palworld-backup could not have written is refused"
assert_file_exists "$UP/anything.tar.gz" "the staging file is untouched"
assert_eq "$(bk_entries)" "0" "the backups dir is untouched"
assert_path_absent "$BK/anything.tar.gz" "nothing was promoted under the bad name"

for bad in "palworld-save-20260727T101500Z.tar" \
           "palworld-save-2026-07-27T101500Z.tar.gz" \
           "$NAME.bak" "" "anything.tar.gz"; do
  run --import "$bad" >/dev/null 2>&1
  assert_ne "$?" "0" "refuses the staged name '$bad'"
done

# A separator is refused by its *own* check, ahead of the pattern. The pattern
# would also refuse these (it contains no `/`), so only pinning the reason keeps
# the separator guard falsifiable rather than dead weight the suite cannot see.
for bad in "sub/$NAME" "../$NAME" "/abs/$NAME" "sub\\$NAME"; do
  out="$(run --import "$bad" 2>&1)"
  assert_ne "$?" "0" "refuses a staged name containing a separator: '$bad'"
  assert_contains "$out" "bare file name" \
    "'$bad' is refused by the separator check itself"
done

# --- a hostile archive under a legitimate name ------------------------------
reset_dirs
cp "$WORK/hostile.tar.gz" "$UP/$NAME"
out="$(run --import "$NAME" 2>&1)"
rc=$?
assert_ne "$rc" "0" "a traversing archive under a valid name is refused"
assert_contains "$out" "escaped.sav" "the refusal names the offending member on stderr"
assert_file_exists "$UP/$NAME" "a refused archive is left in staging for inspection"
assert_eq "$(bk_entries)" "0" "a refused promotion leaves no temp file behind"
assert_path_absent "$WORK/escaped.sav" "nothing was written outside the backups dir"

# --- a symlink in the staging dir ------------------------------------------
# The reason is pinned: without the explicit is_symlink() refusal, O_NOFOLLOW
# would still refuse this — as an ELOOP open error, which is both a worse message
# and a check this test could not tell apart from the one it means to cover.
reset_dirs
cp "$WORK/good.tar.gz" "$WORK/elsewhere.tar.gz"
ln -s "$WORK/elsewhere.tar.gz" "$UP/$NAME"
out="$(run --import "$NAME" 2>&1)"
rc=$?
assert_ne "$rc" "0" "a symlink in the staging dir is refused"
assert_contains "$out" "must not be a symlink" \
  "the symlink is refused by the is_symlink check itself"
assert_eq "$(bk_entries)" "0" "the symlink promoted nothing"

# A FIFO is the other non-regular case, and the one that can hang a root
# process; open_archive_fd owns it, but the tool must not defeat that by
# statting first.
reset_dirs
mkfifo "$UP/$NAME"
out="$(timeout 5 env PYTHONPATH="$LIB" PALWARDEN_UPLOAD_DIR="$UP" \
  PALWARDEN_SAVE_BACKUP_DIR="$BK" python3 "$RESTORE" --import "$NAME" 2>&1; echo "rc=$?")"
assert_not_contains "$out" "rc=124" "does not hang on a FIFO in the staging dir"
assert_contains "$out" "not a regular file" "a FIFO in staging is refused as such"

# A missing staged file is an ordinary clean refusal, not a traceback.
reset_dirs
out="$(run --import "$NAME" 2>&1)"
assert_ne "$?" "0" "a missing staged file is refused"
assert_not_contains "$out" "Traceback" "a missing staged file is not a traceback"

# --- never overwrite an existing archive -----------------------------------
reset_dirs
cp "$WORK/good.tar.gz" "$UP/$NAME"
printf 'EXISTING BACKUP DO NOT CLOBBER\n' > "$BK/$NAME"
# Hashed, not cat'd: on failure the "actual" side is a 200 KB gzip and would
# spray binary through the test output.
before="$(md5sum < "$BK/$NAME")"
out="$(run --import "$NAME" 2>&1)"
rc=$?
assert_ne "$rc" "0" "promotion refuses to overwrite an existing archive"
assert_eq "$(md5sum < "$BK/$NAME")" "$before" "the existing archive's bytes are unchanged"
assert_eq "$(bk_entries)" "1" "the refused promotion left no temp file"
assert_file_exists "$UP/$NAME" "the staged file survives a refused overwrite"

# --- free space -------------------------------------------------------------
# A web process that can fill the backups volume by uploading is a denial of
# service against palworld-backup itself, so the copy is refused before it starts
# when the headroom is not there.
reset_dirs
cp "$WORK/good.tar.gz" "$UP/$NAME"
out="$(PYTHONPATH="$LIB" PALWARDEN_UPLOAD_DIR="$UP" PALWARDEN_SAVE_BACKUP_DIR="$BK" \
  PALWARDEN_IMPORT_FREE_HEADROOM=$((1 << 60)) python3 "$RESTORE" --import "$NAME" 2>&1)"
rc=$?
assert_ne "$rc" "0" "promotion is refused when the backups volume lacks free space"
assert_contains "$out" "free space" "the refusal says the volume is too full"
assert_eq "$(bk_entries)" "0" "no partial copy was made when space was refused"
assert_file_exists "$UP/$NAME" "the staged file survives a free-space refusal"

# The compressed-size cap bounds what a single upload can cost. There are *two*
# enforcement points and they cover different attacks, so each is pinned by its
# own message — the up-front fstat check alone would still be "refused" by the
# in-copy cap and vice versa, which would leave both individually unfalsifiable.
reset_dirs
cp "$WORK/good.tar.gz" "$UP/$NAME"
out="$(PYTHONPATH="$LIB" PALWARDEN_UPLOAD_DIR="$UP" PALWARDEN_SAVE_BACKUP_DIR="$BK" \
  PALWARDEN_IMPORT_MAX_BYTES=1024 python3 "$RESTORE" --import "$NAME" 2>&1)"
assert_ne "$?" "0" "an upload already over the compressed-size cap is refused"
assert_contains "$out" "over the 1024-byte import limit" \
  "the over-cap upload is refused up front, before any copy"
assert_eq "$(bk_entries)" "0" "the over-cap upload left no temp file"

# The other half: a file that is under the cap when we stat it and then *grows*.
# The staging dir belongs to the web process, so an upload that keeps being
# appended to after the size check is a real shape, and only the cap inside the
# copy loop can stop it.
cat > "$WORK/harness_grow.py" <<'PYEOF'
import importlib.machinery
import importlib.util
import os
import sys

restore_path, staged = sys.argv[1:3]

loader = importlib.machinery.SourceFileLoader("palworld_restore_under_test", restore_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

original_copy = mod._copy_fd_to_temp


def growing_copy(fd, tmp_path, cap):
    # Appended after the capacity check has already accepted the smaller size.
    with open(staged, "ab") as fh:
        fh.write(b"\0" * (2 * 1024 * 1024))
    return original_copy(fd, tmp_path, cap)


mod._copy_fd_to_temp = growing_copy
print("rc=%d" % mod.main(["--import", os.path.basename(staged)]))
PYEOF

reset_dirs
cp "$WORK/good.tar.gz" "$UP/$NAME"
# Cap just above the archive's real size, so the up-front check passes and only
# the appended 2 MiB can breach it.
cap=$(( $(stat -c %s "$WORK/good.tar.gz") + 4096 ))
out="$(PYTHONPATH="$LIB" PALWARDEN_UPLOAD_DIR="$UP" PALWARDEN_SAVE_BACKUP_DIR="$BK" \
  PALWARDEN_IMPORT_MAX_BYTES="$cap" \
  python3 "$WORK/harness_grow.py" "$RESTORE" "$UP/$NAME" 2>&1)"
assert_not_contains "$out" "rc=0" "an upload that grows past the cap mid-copy is refused"
assert_contains "$out" "while copying" \
  "the growing upload is refused by the cap inside the copy loop"
assert_eq "$(bk_entries)" "0" "the growing upload left no temp file"

# The load-bearing case above: the free-space check approves a size, and the
# copy must be bounded by *that* size, not by MAX_IMPORT_BYTES. Leave
# MAX_IMPORT_BYTES at its huge default (comfortably above the grown size too),
# so the only thing that can still refuse the grown upload is the copy loop
# being capped at the size _check_capacity actually stat'd and approved. If the
# copy were bounded by MAX_IMPORT_BYTES instead (as it was before this fix),
# this promotion would silently succeed with grown, unapproved bytes on disk.
reset_dirs
cp "$WORK/good.tar.gz" "$UP/$NAME"
out="$(PYTHONPATH="$LIB" PALWARDEN_UPLOAD_DIR="$UP" PALWARDEN_SAVE_BACKUP_DIR="$BK" \
  python3 "$WORK/harness_grow.py" "$RESTORE" "$UP/$NAME" 2>&1)"
assert_not_contains "$out" "rc=0" \
  "with MAX_IMPORT_BYTES left huge, growth past the size the free-space check approved is still refused"
assert_contains "$out" "while copying" \
  "the growth is refused by the in-copy cap, bounded by the approved size"
assert_eq "$(bk_entries)" "0" \
  "no partial or grown copy is left behind when the approved-size cap catches the growth"

# --- the temp file is created O_CREAT|O_EXCL -------------------------------
# The temp name carries 8 bytes of entropy, so a shell test can never plant
# anything at it. Pinning the randomness in a harness is what makes O_EXCL
# falsifiable at all — the alternative is a check no test can fail.
cat > "$WORK/harness_temp.py" <<'PYEOF'
import importlib.machinery
import importlib.util
import os
import sys

restore_path, name, kind, victim = sys.argv[1:5]

loader = importlib.machinery.SourceFileLoader("palworld_restore_under_test", restore_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

# Pin the entropy so the plant below can sit exactly where the tool will write.
mod.secrets.token_hex = lambda _n=8: "deadbeefdeadbeef"
tmp = mod._temp_path(name)
if kind == "file":
    with open(tmp, "w") as fh:
        fh.write("PRE-EXISTING")
else:
    os.symlink(victim, tmp)
print("tmp=%s" % tmp)
print("rc=%d" % mod.main(["--import", name]))
PYEOF

harness_temp() {
  PYTHONPATH="$LIB" PALWARDEN_UPLOAD_DIR="$UP" PALWARDEN_SAVE_BACKUP_DIR="$BK" \
    python3 "$WORK/harness_temp.py" "$RESTORE" "$NAME" "$1" "$2" 2>&1
}

reset_dirs
cp "$WORK/good.tar.gz" "$UP/$NAME"
out="$(harness_temp file "")"
assert_not_contains "$out" "rc=0" \
  "promotion is refused when something already occupies the temp name"
assert_path_absent "$BK/$NAME" "nothing was promoted over an occupied temp name"
assert_eq "$(cat "$BK/.$NAME.import.deadbeefdeadbeef" 2>/dev/null)" "PRE-EXISTING" \
  "the pre-existing temp file was not written through"

reset_dirs
cp "$WORK/good.tar.gz" "$UP/$NAME"
printf 'VICTIM\n' > "$WORK/victim"
out="$(harness_temp symlink "$WORK/victim")"
assert_not_contains "$out" "rc=0" "promotion is refused when the temp name is a symlink"
assert_eq "$(cat "$WORK/victim")" "VICTIM" "the symlink target was not written through"
assert_path_absent "$BK/$NAME" "nothing was promoted through the symlinked temp name"

assert_report
