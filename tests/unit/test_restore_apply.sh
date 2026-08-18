#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# `palworld-restore --restore` turns an archive back into a running world.
#
# The use case is **disaster recovery**, and three of the assertions below exist
# only because of it: nothing may assume `Pal/Saved` exists, an already-stopped
# server is success (while a genuine stop failure must still abort), and the tool
# must work on a host where nothing local has ever run.
#
# Two properties get proved twice, structurally and behaviourally, because they
# are the ones a plausible-looking implementation gets wrong:
#
#   1. **Restore validates the root-owned scratch copy, not the archive in the
#      backups directory.** palworld-backup chowns every archive it writes to the
#      service account and palwarden-webui runs as that account, so an archive in
#      the backups directory is web-writable: validating it in place guarantees
#      the name and not the bytes. Proved structurally (the authoritative
#      validate_archive is called on a scratch path, and pointing the tool back at
#      the backups directory is refused) and behaviourally (the backups-directory
#      archive is rewritten in place between the copy and the extract, and the
#      *originally copied* bytes are what lands).
#   2. **The replaced tree survives every non-confirmed outcome** — start failure,
#      readiness timeout, and REST-not-configured — and is deleted only on a
#      positive confirmation. Deletion must never hang on "no error happened".
#
# Every refusal here is pinned by its own message where a weaker check would
# refuse the same input for a different reason, and every check is mutation-tested
# in the task's steps. A refusal test that still passes with the check deleted is
# worse than no test — this repo has shipped several.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
LIB="$DIR/../../lib"
SBIN_REAL="$DIR/../../sbin"
RESTORE="$SBIN_REAL/palworld-restore"
DOCS="$DIR/../../docs"

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

BK="$WORK/backups"          # PALWARDEN_SAVE_BACKUP_DIR (root-owned in reality)
SC="$WORK/scratch"          # PALWARDEN_RESTORE_SCRATCH (root-only in reality)
SAVED="$WORK/install/Pal/Saved"
PAL="$WORK/install/Pal"
STUBS="$WORK/sbin"          # PALWARDEN_SBIN_DIR
LOGD="$WORK/log"
NAME="palworld-save-20260727T101500Z.tar.gz"

OWNER_USER="$(id -un)"
OWNER_GROUP="$(id -gn)"

# --- stubs ------------------------------------------------------------------
# Each logs its argv so ordering assertions ("the stop never ran") are possible,
# and each takes its exit code from the environment so one stub covers the happy
# path and every failure shape.
mkdir -p "$STUBS"
cat > "$STUBS/palworld-backup" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$STUB_LOG_DIR/backup.log"
rc="${STUB_BACKUP_RC:-0}"
if [ "$rc" != "0" ]; then echo "stub backup: failing on purpose" >&2; exit "$rc"; fi
dest="$STUB_BK/palworld-save-20260101T000000Z.tar.gz"
printf 'stub safety archive\n' > "$dest"
echo "$dest"
EOF
cat > "$STUBS/palworld-graceful-stop" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$STUB_LOG_DIR/stop.log"
rc="${STUB_STOP_RC:-0}"
[ "$rc" = "0" ] || echo "stub stop: failing on purpose" >&2
exit "$rc"
EOF
cat > "$STUBS/palworld-api" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$STUB_LOG_DIR/api.log"
rc="${STUB_API_RC:-0}"
case "$rc" in
  0) echo 'HTTP 200 OK'; echo '{"servername":"stub","version":"v1"}' ;;
  2) echo 'REST API is not enabled in stub settings.env' >&2 ;;
  *) echo 'API request failed: stub' >&2 ;;
esac
exit "$rc"
EOF
# `systemctl`, reached through PALWARDEN_SYSTEMCTL_BIN. is-active defaults to 3
# (inactive), which is the state a server being restored is normally in.
cat > "$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS:%s\n' "$*" >> "$STUB_LOG_DIR/systemctl.log"
case "${1:-}" in
  is-active) exit "${STUB_ACTIVE_RC:-3}" ;;
  start)     exit "${STUB_START_RC:-0}" ;;
  *)         exit 0 ;;
esac
EOF
chmod +x "$STUBS"/*

# --- fixtures ---------------------------------------------------------------
# The good archive is deliberately ~200 KB and incompressible so it is comfortably
# longer than the "evil" archive pwritten over it in the ordering test below;
# leftover tail bytes past the shorter gzip member are never reached, because tar
# stops at its end-of-archive blocks.
mkdir -p "$WORK/src/SaveGames/0" "$WORK/src/Config"
head -c 200000 /dev/urandom > "$WORK/src/SaveGames/0/Level.sav"
printf 'GOOD\n' > "$WORK/src/SaveGames/marker.txt"
printf 'cfg\n' > "$WORK/src/Config/PalWorldSettings.ini"
tar -C "$WORK/src" -czf "$WORK/good.tar.gz" SaveGames Config \
  || fail "could not build the good archive"

# Same legal shape, different contents: a restore that reads the backups-directory
# archive instead of the scratch copy would land EVIL, and would *succeed* while
# doing it, which is why this and not a hostile archive is the behavioural probe.
mkdir -p "$WORK/evil/SaveGames" "$WORK/evil/Config"
printf 'EVIL\n' > "$WORK/evil/SaveGames/marker.txt"
printf 'evil\n' > "$WORK/evil/Config/PalWorldSettings.ini"
tar -C "$WORK/evil" -czf "$WORK/evil.tar.gz" SaveGames Config \
  || fail "could not build the evil archive"

# The traversing tarball from Task 1's suite, built with python tarfile so the
# member name is byte-for-byte what we intend (tar(1) normalises `..` away).
cat > "$WORK/build_hostile.py" <<'PYEOF'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as tf:
    info = tarfile.TarInfo("../escaped.sav")
    data = b"pwned"
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PYEOF
python3 "$WORK/build_hostile.py" "$WORK/hostile.tar.gz" \
  || fail "could not build the hostile archive"

# --- harness ---------------------------------------------------------------
# Module-loads the tool under test (hyphenated name, so SourceFileLoader) and
# interleaves exactly one thing, the way test_restore_import.sh does. Nothing is
# faked out: the real copy, the real validation and the real extraction all run.
cat > "$WORK/harness.py" <<'PYEOF'
import atexit
import importlib.machinery
import importlib.util
import os
import sys

restore_path, mode, mode_arg = sys.argv[1:4]
argv = sys.argv[5:] if len(sys.argv) > 4 else []   # sys.argv[4] is the "--"

loader = importlib.machinery.SourceFileLoader("palworld_restore_under_test", restore_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

if mode == "record":
    # Which path the *authoritative* validation and the extraction actually run
    # against. Both must be the scratch copy.
    #
    # The validation wrapper is on validate_archive_fileobj, which is the door
    # --restore uses (it needs the descriptor back to fstat, so it cannot use the
    # path-taking validate_archive); its `label` argument is the scratch path as
    # spelled. The extraction is reported by *realpath*, because the tool reaches
    # the file through /proc/self/fd/<dirfd>/ so the descriptor cannot be
    # re-resolved to a different directory - realpath is where that lands, which
    # is the thing worth asserting.
    orig_validate_fileobj = mod.archive.validate_archive_fileobj
    orig_extract = mod.archive.extract_archive

    def validate_fileobj(fh, label, *a, **k):
        print("VALIDATE=%s" % label)
        return orig_validate_fileobj(fh, label, *a, **k)

    def extract(path, dest, *a, **k):
        print("EXTRACT=%s" % os.path.realpath(path))
        # The *destination*, also by realpath and for the same reason: it is
        # handed over as /proc/self/fd/<tfd>/., so realpath is what says which
        # directory that descriptor is pinned to - and it is where the staging
        # name's entropy becomes observable.
        print("DEST=%s" % os.path.realpath(dest))
        return orig_extract(path, dest, *a, **k)

    mod.archive.validate_archive_fileobj = validate_fileobj
    mod.archive.extract_archive = extract
elif mode == "substitute":
    # The reviewer's probe against the scratch scheme, and the one an
    # fstat-less implementation loses to: between the authoritative validation
    # and the extraction, unlink the scratch copy and drop a *different but
    # individually valid* archive at exactly the same name. This is what the owner
    # of the scratch directory can do - which, with the pre-fix default of
    # /var/lib/palworld/restore-scratch, was the unprivileged web account.
    #
    # Both passes re-open the copy by name, so without an identity check the
    # extraction happily unpacks bytes nothing ever validated and the restore
    # reports success. The refusal must name the substitution.
    with open(mode_arg, "rb") as fh:
        replacement = fh.read()
    orig_validate_fileobj = mod.archive.validate_archive_fileobj

    def substituting_validate(fh, label, *a, **k):
        info = orig_validate_fileobj(fh, label, *a, **k)
        for entry in os.listdir(mod.SCRATCH_DIR):
            target = os.path.join(str(mod.SCRATCH_DIR), entry)
            os.unlink(target)
            with open(target, "wb") as out:
                out.write(replacement)
        return info

    mod.archive.validate_archive_fileobj = substituting_validate
elif mode == "swapdir":
    # The *backups* directory entry swapped while root's descriptor is open:
    # open_archive_fd hands back a descriptor on the good archive, then the entry
    # is renamed over with the evil one. A copy that reads from the descriptor
    # lands the good bytes; a copy that resolves `src` a second time (a
    # `shutil.copy(str(src), ...)`, say) lands the evil ones.
    #
    # This is a different attack from `rewrite` below and catches a different
    # mistake: rewrite swaps the *inode contents* after the copy has finished, so
    # a by-name copy would still have read the good bytes and pass.
    orig_open = mod.archive.open_archive_fd

    def swapping_open(path):
        fd = orig_open(path)
        # Only the backups-directory source, and only once: open_archive_fd is
        # also how the scratch copy is later read, and those calls must be left
        # alone.
        if os.path.dirname(str(path)) == str(mod.BACKUP_DIR) and os.path.exists(mode_arg):
            os.rename(mode_arg, str(path))
        return fd

    mod.archive.open_archive_fd = swapping_open
elif mode == "rewrite":
    # The attacker's write, landing *after* the scratch copy is taken and before
    # the extraction reads it. The backups directory is root-owned, so the name
    # cannot be swapped — but palworld-backup handed the archive itself to the
    # service account, so the web process can rewrite this inode in place.
    with open(mode_arg, "rb") as fh:
        replacement = fh.read()
    orig_copy = mod._scratch_copy

    def rewriting_copy(src, dfd):
        scratch = orig_copy(src, dfd)
        wfd = os.open(str(src), os.O_WRONLY)   # no O_TRUNC: same inode
        try:
            os.pwrite(wfd, replacement, 0)
        finally:
            os.close(wfd)
        return scratch

    mod._scratch_copy = rewriting_copy
elif mode == "nocopy":
    # The regression this task exists to prevent: skip the copy and hand the
    # backups-directory path straight to the validation.
    mod._scratch_copy = lambda src, dfd: src
elif mode == "swaptree":
    # The reviewer's working exploit against the *destination*, which the scratch
    # copy says nothing about. `SAVED_DIR.parent` (`.../Pal`) is owned by the
    # service account, so the account palwarden-webui runs as can rename the
    # staging tree root just created aside and drop a symlink at the same name.
    # A restore that extracts to the *name* then unpacks the archive wherever
    # that link points, as root, renames the link into place as the live world,
    # and _chown_tree walks through it - all with rc=0 and "the REST API is
    # healthy". The interleaving happens in _check_scratch_identity, which is
    # the last call before the extraction and has nothing to do with the
    # destination, so nothing under test is stubbed out.
    orig_ident = mod._check_scratch_identity

    def swapping_ident(scratch, dfd, ident):
        orig_ident(scratch, dfd, ident)
        parent = str(mod.SAVED_DIR.parent)
        prefix = mod.SAVED_DIR.name + ".restore-"
        for entry in sorted(os.listdir(parent)):
            if entry.startswith(prefix):
                staged = os.path.join(parent, entry)
                os.rename(staged, staged + ".moved")
                os.symlink(mode_arg, staged)

    mod._check_scratch_identity = swapping_ident
elif mode == "linkroot":
    # The same swap, but landed: the live world *is* a symlink by the time the
    # ownership pass runs. os.walk(followlinks=False) does not help here - it
    # governs descending into symlinked subdirectories, while the directory
    # os.walk is handed is followed unconditionally - so this is the shape that
    # has root chowning an attacker-chosen tree to the service account.
    orig_chown = mod._chown_tree

    def linking_chown(root):
        aside = str(root) + ".aside"
        os.rename(str(root), aside)
        os.symlink(mode_arg, str(root))
        return orig_chown(root)

    mod._chown_tree = linking_chown
elif mode == "swapfail":
    # A failure partway through the contents swap. A `rename` of the directory
    # made this state unreachable — it either happened or it did not — and moving
    # entries one at a time makes it reachable, so the report is the mitigation and
    # this is what tests it. `mode_arg` picks the phase:
    #
    #   "out" — fails on the very first entry of the previous world, so nothing has
    #           moved: the live world is intact and the staging tree is pure debris.
    #   "in"  — fails after one entry of the restored world has landed, so the live
    #           tree is genuinely mixed and the staging tree holds the rest of it.
    #
    # The direction is read off the *destination*, which is the only thing that
    # distinguishes the two loops.
    orig_move = mod._move_entry
    landed = []

    def failing_move(name, src_fd, dst_fd, src_display, dst_display, **kw):
        into_live = str(dst_display) == str(mod.SAVED_DIR)
        if mode_arg == "out" and not into_live:
            raise OSError(5, "stub move failure")
        if mode_arg == "in" and into_live:
            landed.append(name)
            if len(landed) > 1:
                raise OSError(5, "stub move failure")
        return orig_move(name, src_fd, dst_fd, src_display, dst_display, **kw)

    mod._move_entry = failing_move
elif mode in ("copies", "exdev"):
    # The copy fallback, which no tier reached before. `_move_entry` renames first
    # and copies only on EXDEV, and an unprivileged suite cannot create the mount
    # point that produces one — so the *kernel's answer* is what is faked, at the
    # one call site that asks for it, and nothing about the tool's own decision is
    # stubbed: it still branches on errno, still classifies by lstat, still writes
    # through the pinned destination.
    #
    #   mode "copies" — count the copies, renames left alone. A same-filesystem
    #                   swap must perform none, which is the only thing that makes
    #                   "rename first" falsifiable: with the rename attempt deleted
    #                   everything copies and every other assertion still passes.
    #   mode "exdev"  — every per-entry rename returns EXDEV, so the copy branch
    #                   runs end to end. `mode_arg` adds the attacker:
    #                     "plant:<path>" — plant a symlink at the destination name
    #                                      during the out-phase, which is the C1
    #                                      privilege escalation.
    counts = {"copytree": 0, "copy2": 0, "copyfileobj": 0}

    def counting(kind, fn):
        def wrapper(*a, **k):
            counts[kind] += 1
            return fn(*a, **k)
        return wrapper

    mod.shutil.copytree = counting("copytree", mod.shutil.copytree)
    mod.shutil.copy2 = counting("copy2", mod.shutil.copy2)
    mod.shutil.copyfileobj = counting("copyfileobj", mod.shutil.copyfileobj)

    if mode == "exdev":
        real_rename = os.rename

        def crossing_rename(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
            # Only the descriptor-to-descriptor form, which is `_move_entry`'s and
            # nothing else's in this tool: the scratch copy's own rename, and
            # `_open_live_dir`'s move-aside, must keep working.
            if src_dir_fd is not None and dst_dir_fd is not None:
                raise OSError(18, "Invalid cross-device link")
            return real_rename(src, dst, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd)

        os.rename = crossing_rename

    if mode_arg.startswith("hardlink:"):
        # The same window, aimed at the *ownership* pass rather than the copy.
        # `_chown_tree` used to walk a tree root had just created and renamed into
        # place, so nothing could inject into it; it now walks SAVED_DIR, which the
        # service account can write for the whole restore. A directory planted
        # mid-swap that contains a HARDLINK to a root-owned file is not fixed by
        # walking with descriptors - a name resolves to its target inode either way -
        # so it has to be refused.
        victim = mode_arg[len("hardlink:"):]
        orig_move_hl = mod._move_entry

        def linking_move(name, src_fd, dst_fd, src_display, dst_display, **kw):
            result = orig_move_hl(name, src_fd, dst_fd, src_display, dst_display, **kw)
            if str(dst_display) != str(mod.SAVED_DIR):
                planted = os.path.join(str(mod.SAVED_DIR), "zz-planted")
                if not os.path.exists(planted):
                    os.mkdir(planted)
                    os.link(victim, os.path.join(planted, "root-file"))
                    print("PLANTED=%s" % planted)
            return result

        mod._move_entry = linking_move

    if mode_arg.startswith("plant:"):
        # The attacker is the account that owns Pal/Saved - the one palwarden-webui
        # runs as. Its window is the whole out-phase, because the live directory's
        # entries are snapshotted once before it: a name planted after that snapshot
        # is never moved aside and is still sitting there when the in-phase copies
        # onto it. So this plants after the first entry has moved out, which is
        # inside the window and needs no race to be won.
        victim = mode_arg[len("plant:"):]
        orig_move = mod._move_entry

        def planting_move(name, src_fd, dst_fd, src_display, dst_display, **kw):
            result = orig_move(name, src_fd, dst_fd, src_display, dst_display, **kw)
            if str(dst_display) != str(mod.SAVED_DIR):
                link = os.path.join(str(mod.SAVED_DIR), "Config")
                if not os.path.lexists(link):
                    os.symlink(victim, link)
                    print("PLANTED=%s" % link)
            return result

        mod._move_entry = planting_move

    atexit.register(lambda: print("COPIES=%d copytree=%d copy2=%d copyfileobj=%d" % (
        sum(counts.values()), counts["copytree"], counts["copy2"],
        counts["copyfileobj"])))
elif mode == "extractfail":
    # A partial extraction. Writes into the staging tree, then fails.
    def failing_extract(path, dest, *a, **k):
        with open(os.path.join(dest, "partial.sav"), "w") as fh:
            fh.write("half a world")
        raise mod.archive.ArchiveError("stub extraction failure")

    mod.archive.extract_archive = failing_extract
else:
    raise SystemExit("unknown harness mode %r" % mode)

print("rc=%d" % mod.main(argv))
PYEOF

# --- invocation -------------------------------------------------------------
env_args() {
  printf '%s\n' \
    "PYTHONPATH=$LIB" \
    "PALWARDEN_SAVE_BACKUP_DIR=$BK" \
    "PALWARDEN_RESTORE_SCRATCH=${SCRATCH_OVERRIDE:-$SC}" \
    "PALWARDEN_SBIN_DIR=$STUBS" \
    "PALWARDEN_SYSTEMCTL_BIN=$STUBS/systemctl" \
    "PALWORLD_SAVED_DIR=$SAVED" \
    "PALWORLD_USER=${OWNER_USER}" \
    "PALWORLD_GROUP=${OWNER_GROUP}" \
    "PALWARDEN_RESTORE_POLL_SECONDS=1" \
    "STUB_LOG_DIR=$LOGD" \
    "STUB_BK=$BK"
}

run() { mapfile -t e < <(env_args); env "${e[@]}" python3 "$RESTORE" "$@"; }
harness() {
  local mode="$1" arg="$2"; shift 2
  mapfile -t e < <(env_args)
  env "${e[@]}" python3 "$WORK/harness.py" "$RESTORE" "$mode" "$arg" -- "$@"
}

reset_all() {
  chmod -R u+rwX "$WORK/install" 2>/dev/null
  rm -rf "$BK" "$SC" "$WORK/install" "$LOGD"
  mkdir -p "$BK" "$LOGD" "$PAL"
  # Created deliberately loose: the tool must tighten it to 0700 itself, so an
  # install that predates Task 8's 0700 does not silently leave the one directory
  # the integrity argument rests on readable by the service account.
  mkdir -p "$SC"
  chmod 755 "$SC"
  : > "$LOGD/backup.log"; : > "$LOGD/stop.log"
  : > "$LOGD/api.log"; : > "$LOGD/systemctl.log"
  unset STUB_BACKUP_RC STUB_STOP_RC STUB_API_RC STUB_START_RC STUB_ACTIVE_RC \
        SCRATCH_OVERRIDE PALWARDEN_MODE 2>/dev/null || true
}

# A world that is already there, with a file no archive contains — so "the live
# tree was replaced" and "the live tree was left alone" are distinguishable.
populate_world() {
  mkdir -p "$SAVED/SaveGames"
  printf 'PREVIOUS\n' > "$SAVED/SaveGames/old.sav"
}

stage() { cp "${1:-$WORK/good.tar.gz}" "$BK/$NAME"; }

count_glob() { local n=0 p; for p in "$@"; do [ -e "$p" ] && n=$((n + 1)); done; printf '%s' "$n"; }
replaced_trees() { count_glob "$SAVED".replaced-*; }
staging_trees() { count_glob "$SAVED".restore-*; }
scratch_entries() { find "$SC" -mindepth 1 2>/dev/null | wc -l | tr -d ' '; }

# ===========================================================================
# argparse surface
# ===========================================================================
reset_all
out="$(run --help 2>&1)"
assert_eq "$?" "0" "--help exits 0"
assert_contains "$out" "--restore" "--restore is a documented mode"
run --restore "$NAME" --import "$NAME" >/dev/null 2>&1
assert_ne "$?" "0" "--import and --restore together are refused"
out="$(run --import "$NAME" --wait 30 2>&1)"
assert_ne "$?" "0" "--wait is refused alongside --import"
assert_contains "$out" "--restore only" "the --wait/--import clash names the reason"

# ===========================================================================
# the happy path
# ===========================================================================
reset_all
populate_world
stage
out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"
rc=$?
assert_eq "$rc" "0" "a good archive restores cleanly (output: $out)"
assert_file_contains "$LOGD/backup.log" "ARGS:" "the pre-restore safety backup ran"
assert_file_contains "$LOGD/stop.log" "ARGS:" "the graceful stop ran"
assert_file_contains "$LOGD/systemctl.log" "start palworld.service" "the server was started"
assert_file_contains "$LOGD/api.log" "info" "readiness was checked with palworld-api info"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" \
  "the world now holds the archive's contents"
assert_file_exists "$SAVED/Config/PalWorldSettings.ini" "the archive's Config tree landed too"
assert_path_absent "$SAVED/SaveGames/old.sav" "the previous world is gone from the live tree"
assert_eq "$(replaced_trees)" "0" "the replaced tree is deleted on a confirmed startup"
assert_eq "$(staging_trees)" "0" "no staging tree is left beside the target"
assert_eq "$(scratch_entries)" "0" "the scratch copy is deleted on success"
assert_eq "$(stat -c %a "$SC")" "700" "the scratch directory is tightened to 0700"
assert_contains "$out" "cleaned up: removed the replaced world" \
  "the output says the replaced tree was removed"
# Pinned on the closing report's own wording, not on the bare archive name: the
# `safety backup: <name>` progress line printed earlier already contains the name,
# so asserting the name alone passed with this whole report deleted. Same shape the
# failure-path reports above were fixed for, third instance in this feature.
assert_contains "$out" "safety archive retained: palworld-save-20260101T000000Z.tar.gz" \
  "the closing report records the safety archive by name"

# ===========================================================================
# the swap moves CONTENTS, not the directory
# ===========================================================================
# The regression that shipped: the swap was `rename(Pal/Saved, Saved.replaced-…)`
# followed by `rename(Saved.restore-…, Pal/Saved)`, and `Pal/Saved` is a **mount
# point** in every Docker deployment — a named volume in `docker/compose.yaml`, a
# bind mount in `docker/compose.live.yaml` — where `rename(2)` returns EBUSY
# (errno 16, reproduced). So `--restore` could not finish in any container, and
# nothing noticed: this suite points PALWORLD_SAVED_DIR at a plain `mktemp -d`, and
# the integration scenario that runs a genuine end-to-end restore mounted only
# `/opt/palworld/server`, leaving `Pal/Saved` an ordinary subdirectory. The swap had
# never met a mount point in any tier.
#
# An unprivileged suite cannot create a mount point, and faking one would prove
# nothing about the syscall. So this asserts the *observable that distinguishes the
# two strategies*: renaming the directory replaces its inode, moving its children
# does not. tests/integration/test_docker.sh scenario N runs the real thing against
# a real mount point, which is where the EBUSY itself is pinned.
reset_all
populate_world
stage
saved_ino_before="$(stat -c %i "$SAVED")"
out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"
assert_eq "$?" "0" "the contents swap restores cleanly (output: $out)"
assert_eq "$(stat -c %i "$SAVED")" "$saved_ino_before" \
  "Pal/Saved is still the same directory afterwards - its own inode is unchanged"
# ...and it really restored, so the inode assertion cannot be satisfied by a tool
# that did nothing at all. Both halves are needed; either alone is passable.
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" \
  "...while the contents of that same directory are now the archive's"
assert_path_absent "$SAVED/SaveGames/old.sav" \
  "...and the previous world's file is no longer in it"
# The replaced tree, by contrast, IS a new sibling directory and must stay one: it
# is not a mount point, so creating and later removing it is free, and the recovery
# instructions printed on every failure path name it as a real path.
assert_eq "$(replaced_trees)" "0" "the replaced sibling is still removed on success"

# ===========================================================================
# a swap that fails partway says exactly what state the tree is in
# ===========================================================================
# The honest cost of moving entries instead of the directory. A directory rename
# could not fail halfway; this can, and the resulting tree is mixed. A partial
# recovery the operator cannot diagnose from the job output is this project's worst
# outcome, so the report is part of the contract and is pinned here.
#
# Phase 1: the failure lands before anything moves. The live world is untouched,
# which the message must say rather than leaving the operator to guess.
reset_all
populate_world
stage
out="$(harness swapfail out --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=1" "a swap that fails before anything moves fails the restore"
assert_contains "$out" "Nothing was moved" "...and says nothing was moved"
assert_contains "$out" "complete and untouched" "...that the previous world is intact"
assert_eq "$(cat "$SAVED/SaveGames/old.sav" 2>/dev/null)" "PREVIOUS" \
  "...and the previous world really is still there"
assert_path_absent "$SAVED/SaveGames/marker.txt" "...with no part of the archive in it"
# Nothing of the new world landed, so the staging tree is debris and is discarded
# rather than left as an unreported world save. This is the leak: the `except`
# around the swap sat outside the `_discard_staging` try, so every containerised
# restore attempt — all of which failed, on EBUSY — leaked a full world silently.
assert_eq "$(staging_trees)" "0" \
  "the staging tree is discarded when the swap failed before touching the world"
assert_contains "$out" "the pre-restore safety archive is" \
  "...and the safety archive is still named as a route back"

# Phase 2: the failure lands after one entry of the restored world is in. This is
# the state that did not exist before, and the only defence is that it is described
# precisely.
reset_all
populate_world
stage
out="$(harness swapfail in --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=1" "a swap that fails partway through fails the restore"
assert_contains "$out" "stopped PARTWAY" "...and says the restore stopped partway"
assert_contains "$out" "MIXED tree" "...that the live tree is mixed"
assert_contains "$out" "must NOT be started on it" \
  "...and that the server must not be started on it"
# Both routes back, by path, in the same output: the replaced tree holding the
# whole previous world, and the durable archive.
assert_contains "$out" "the previous world is complete in $SAVED.replaced-" \
  "...naming the replaced tree that holds the whole previous world"
assert_contains "$out" "the pre-restore safety archive is" \
  "...and naming the safety archive as the durable route"
assert_eq "$(replaced_trees)" "1" "the replaced tree is kept after a partial swap"
# Kept, not discarded, and *named*: it holds the entries that never landed, so an
# operator reassembling the tree needs it — but an unreported world save is what
# this task was fixing, so it must be mentioned either way.
assert_eq "$(staging_trees)" "1" "the staging tree is kept when it still holds entries"
assert_contains "$out" "the extracted world is left at $SAVED.restore-" \
  "...and the output names it rather than leaking it silently"

# ===========================================================================
# the copy fallback: taken only on EXDEV, and it never writes through a name
# ===========================================================================
# Nothing in any tier reached this branch before. `_move_entry` renames first and
# copies only on `EXDEV`, an unprivileged suite cannot create the mount point that
# produces one, and integration scenario N runs on a layout where the rename
# succeeds — so deleting the `os.rename` attempt outright left the whole suite
# green while turning every restore into a copy. Both halves are pinned here: the
# rename is preferred where it can work, and the copy is correct where it cannot.
#
# The harness fakes the *kernel's answer* at the one call that asks for it (the
# descriptor-to-descriptor `os.rename`), never the tool's decision: the branch on
# errno, the lstat classification and the pinned destination are all the real code.
# Deliberately not an st_dev comparison, here or in the tool — two bind mounts off
# one host filesystem report the same device and the rename is refused anyway.

# A same-filesystem swap must perform NO copy. This is what makes "rename first"
# falsifiable; without it the rename is unfalsifiable preference.
reset_all
populate_world
stage
out="$(harness copies "" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=0" "a same-filesystem swap restores cleanly (output: $out)"
assert_contains "$out" "COPIES=0 " \
  "a same-filesystem swap copies nothing at all - every entry is renamed"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" \
  "...and it really restored, so COPIES=0 is not the count of a tool that did nothing"

# EXDEV on every entry: the copy branch end to end. The world must land exactly as
# the rename path lands it.
reset_all
populate_world
stage
out="$(harness exdev "" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=0" "a cross-mount swap restores cleanly too (output: $out)"
assert_not_contains "$out" "COPIES=0 " "...by copying, since no rename could serve"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" \
  "...and the copied world holds the archive's contents"
assert_file_exists "$SAVED/Config/PalWorldSettings.ini" \
  "...including the archive's Config tree"
assert_eq "$(wc -c < "$SAVED/SaveGames/0/Level.sav" | tr -d ' ')" "200000" \
  "...and a nested 200 KB save file arrives whole"
assert_path_absent "$SAVED/SaveGames/old.sav" "...with the previous world gone from it"
assert_eq "$(replaced_trees)" "0" "...and the replaced tree still removed on success"
assert_eq "$(staging_trees)" "0" "...and no staging tree left behind"

# ===========================================================================
# C1: the copy branch must not write through a symlink planted at the destination
# ===========================================================================
# The privilege escalation this section exists for, reproduced end to end before it
# was fixed: `rc=0`, "the REST API is healthy", and the victim file's contents
# replaced with the archive's bytes while `Pal/Saved/Config` was still a symlink to
# it. Targets are whatever root can write — `/root/.ssh/authorized_keys`,
# `/etc/cron.d/*`, `/etc/ld.so.preload`.
#
# Every link of the chain is in the shipped code, which is why this is a test and
# not a note. `_check_member` is "first component in ALLOWED_TOPLEVEL" plus
# "isreg() or isdir()", so an archive whose ONLY member is a *regular file named
# Config* validates, imports, and restores — and it selects the one exploitable
# branch. The live directory's entries are snapshotted once before the out-phase,
# so a name planted after that snapshot is never moved aside and is still there
# when the in-phase copies onto it: the window is the whole out-phase, not a race.
# The old spelling was `shutil.copy2(src, dst, follow_symlinks=False)`, where
# `follow_symlinks=False` governs the SOURCE; `shutil.copyfile` opens the
# destination with `open(dst, "wb")`, which follows a symlink at the final
# component. `_at` pins the directory half of that path and nothing pinned the
# last component, which `SAVED_DIR`'s owner - the account palwarden-webui runs as -
# controls.
reset_all
populate_world
printf 'SAFE\n' > "$WORK/victim"
# The archive: one member, a regular file, named exactly `Config`.
python3 - "$BK/$NAME" <<'PYEOF'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as tf:
    data = b"PWNED\n"
    info = tarfile.TarInfo("Config")
    info.size = len(data)
    info.mode = 0o644
    tf.addfile(info, io.BytesIO(data))
PYEOF
out="$(harness exdev "plant:$WORK/victim" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "PLANTED=$SAVED/Config" "the symlink really was planted at the destination name"
assert_contains "$out" "rc=1" "a symlink at the destination name fails the restore"
assert_eq "$(cat "$WORK/victim")" "SAFE" \
  "the victim file outside the world is untouched - root did not write through the link"
assert_eq "$(readlink "$SAVED/Config")" "$WORK/victim" \
  "...and the planted link is still a link, so it was refused rather than replaced"
# Pinned on the errno, because that is the whole mechanism: the destination is
# created with O_CREAT|O_EXCL|O_NOFOLLOW through the destination descriptor, so an
# occupied name is EEXIST out of the syscall rather than a check of our own that
# could be raced.
assert_contains "$out" "File exists" "the refusal is EEXIST from the create itself"
assert_contains "$out" "MIXED tree" "...and the mid-swap state is reported as usual"
assert_contains "$out" "the previous world is complete in $SAVED.replaced-" \
  "...naming the route back"

# ===========================================================================
# the copy branch's other two types
# ===========================================================================
# A symlink in the LIVE world is legal — the game and operators write that tree —
# so the copy branch must reproduce it as a link rather than duplicating its
# target. `copy2` with the default `follow_symlinks=True` would copy the target's
# bytes, which for a link into the install tree means silently inflating the
# replaced world by however large that target is.
reset_all
populate_world
printf 'TARGET\n' > "$WORK/linktarget"
ln -s "$WORK/linktarget" "$SAVED/zz-link"
stage
# API exit 2 keeps the replaced tree, which is the only place the moved-out link
# can be inspected.
out="$(STUB_API_RC=2 harness exdev "" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=0" "a live-world symlink does not stop a cross-mount swap (output: $out)"
moved_link="$(echo "$SAVED".replaced-*/zz-link)"
assert_eq "$(readlink "$moved_link")" "$WORK/linktarget" \
  "the moved-aside symlink is still a symlink to its original target"
assert_eq "$(cat "$WORK/linktarget")" "TARGET" "...and its target was not disturbed"

# Anything that is neither file, directory nor symlink is refused rather than
# guessed at — and the refusal is the reviewer's unprivileged DoS, so the state
# report is what makes it survivable. A FIFO named to sort AFTER a real entry means
# the out-phase has already moved something when it aborts, so the previous world
# is left split across two directories. The tool `lstat`s rather than opening, so a
# FIFO cannot hang it.
reset_all
populate_world
mkfifo "$SAVED/zz-fifo"
stage
out="$(harness exdev "" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=1" "a FIFO in the live world fails a cross-mount swap"
assert_contains "$out" "neither a regular file, a directory nor a symbolic link" \
  "...naming why that entry could not be copied"
assert_contains "$out" "$SAVED/zz-fifo" "...and naming the entry itself"
assert_contains "$out" "SPLIT ACROSS THE TWO" \
  "...and reporting the previous world as split, because an earlier entry had moved"
assert_contains "$out" "SaveGames" "...naming which entries are where, not just how many"
assert_path_absent "$SAVED/SaveGames/marker.txt" "...with no part of the archive landed"

# ===========================================================================
# a cross-mount swap that will not fit is refused BEFORE anything moves
# ===========================================================================
# `--import` has had a statvfs precheck since it shipped; the swap had none, and
# the fallback is what made that expensive: in docker/compose.yaml the replaced
# tree and the staging tree both land on the *server* volume while the new world is
# copied into the *Saved* volume, so a containerised restore needs roughly twice
# the world free on the server volume. ENOSPC is therefore the most likely mid-swap
# failure, and a mid-swap ENOSPC produces exactly the mixed tree everything else
# here is about avoiding.
#
# The free space is driven by inflating the headroom rather than by filling a disk:
# the same PALWARDEN_IMPORT_FREE_HEADROOM the import check already honours, so the
# arithmetic under test is the real arithmetic.
reset_all
populate_world
stage
out="$(PALWARDEN_IMPORT_FREE_HEADROOM=$(( 1 << 60 )) harness exdev "" \
        --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=1" "a cross-mount swap with no room is refused"
assert_contains "$out" "needs about" "...saying how much space it needed"
assert_contains "$out" "crosses a mount boundary" \
  "...and why a copy, not a rename, is what needs it"
assert_contains "$out" "Nothing was moved" "...before anything moved"
assert_eq "$(cat "$SAVED/SaveGames/old.sav" 2>/dev/null)" "PREVIOUS" \
  "...so the previous world is complete and untouched"
assert_eq "$(staging_trees)" "0" "...and the staging tree is discarded, not leaked"

# The same impossible headroom must NOT refuse a swap that renames, because a
# rename consumes no space. This is the assertion that stops the precheck being
# turned into an unconditional one - which would refuse restores on bare metal
# that work perfectly.
reset_all
populate_world
stage
out="$(PALWARDEN_IMPORT_FREE_HEADROOM=$(( 1 << 60 )) harness copies "" \
        --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=0" \
  "a same-filesystem swap ignores the free-space check entirely (output: $out)"
assert_contains "$out" "COPIES=0 " "...because it copied nothing"

# ===========================================================================
# a failed copy leaves no debris at the destination
# ===========================================================================
# `shutil.copytree` copies what it can and THEN raises, so "a failure leaves the
# entry where it was" was true of the source only. The recovery instructions tell
# the operator to move whole entries back from the replaced tree; a half copy
# sitting at the destination is what makes that `mv` collide or silently merge over
# a good tree. The dangling symlink below makes the *source* unreadable partway
# through the tree, which is how a real ENOSPC/EIO presents.
reset_all
populate_world
mkdir -p "$SAVED/SaveGames/sub"
ln -s "$WORK/definitely-not-there" "$SAVED/SaveGames/sub/broken"
chmod 000 "$SAVED/SaveGames/sub"
stage
out="$(harness exdev "" --restore "$NAME" --startup-timeout 5 2>&1)"
chmod 755 "$SAVED/SaveGames/sub" 2>/dev/null
assert_contains "$out" "rc=1" "a copy that fails partway fails the restore"
assert_contains "$out" "only whole entries" \
  "...and the report says the partial destination entry was removed"
assert_eq "$(count_glob "$SAVED".replaced-*/SaveGames)" "0" \
  "...and the half-copied SaveGames really is gone from the replaced tree"

# ===========================================================================
# the ownership pass refuses a hardlink planted in the live tree
# ===========================================================================
# `_chown_tree` walked a root-created staging tree that had just been renamed into
# place, so nothing could inject during the walk. It now walks `Pal/Saved`, which
# the service account owns for the whole restore, and `lchown` on a hardlink to a
# root-owned file hands that file to the service account -
# `/etc/shadow`, a systemd unit, anything root can read. Descriptors do not fix it:
# a name resolves to its target inode through `dir_fd` exactly as through a path.
# `fs.protected_hardlinks=1` would, but that is a host sysctl this project neither
# sets nor verifies, so the link count is checked instead. A world this tool
# extracted cannot contain one - `_check_member` refuses hardlink members by type.
reset_all
populate_world
printf 'ROOT OWNED\n' > "$WORK/rootfile"
stage
out="$(harness copies "hardlink:$WORK/rootfile" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "PLANTED=$SAVED/zz-planted" "the hardlink really was planted in the live tree"
assert_contains "$out" "rc=1" "a hardlink in the tree being chowned fails the restore"
assert_contains "$out" "hard links" "...naming the link count as the reason"
assert_contains "$out" "zz-planted/root-file" "...and naming the offending path"
assert_contains "$out" "$SAVED holds the restored world" \
  "...and saying the world is already restored, since this refusal is after the swap"
assert_eq "$(cat "$WORK/rootfile")" "ROOT OWNED" "the linked file's contents are untouched"

# --wait is forwarded to the stop tool, which is where the player warning lives.
reset_all
populate_world
stage
run --restore "$NAME" --wait 42 --startup-timeout 5 >/dev/null 2>&1
assert_eq "$?" "0" "--restore accepts --wait"
assert_file_contains "$LOGD/stop.log" "--wait 42" "--wait is forwarded to the graceful stop"
run --restore "$NAME" --wait -1 >/dev/null 2>&1
assert_ne "$?" "0" "a negative --wait is refused"

# ===========================================================================
# an invalid archive aborts before anything is stopped or replaced
# ===========================================================================
reset_all
populate_world
stage "$WORK/hostile.tar.gz"
out="$(run --restore "$NAME" 2>&1)"
rc=$?
assert_ne "$rc" "0" "a traversing archive under a valid name is refused"
assert_contains "$out" "escaped.sav" "the refusal names the offending member"
assert_eq "$(cat "$LOGD/stop.log")" "" "nothing was stopped: the stop log is empty"
assert_eq "$(cat "$LOGD/backup.log")" "" "no safety backup was taken either"
assert_eq "$(cat "$LOGD/systemctl.log")" "" "the service was never touched"
assert_eq "$(cat "$SAVED/SaveGames/old.sav")" "PREVIOUS" "the live tree is untouched"
assert_eq "$(replaced_trees)" "0" "nothing was moved aside"
assert_eq "$(staging_trees)" "0" "no staging tree was created"
assert_eq "$(scratch_entries)" "0" "the scratch copy is deleted on failure too"
assert_path_absent "$WORK/escaped.sav" "nothing was written outside the destination"

# A name palworld-backup could not have written never reaches the filesystem.
reset_all
populate_world
for bad in "palworld-save-20260727T101500Z.tar" \
           "palworld-save-2026-07-27T101500Z.tar.gz" \
           "$NAME.bak" "" "anything.tar.gz"; do
  run --restore "$bad" >/dev/null 2>&1
  assert_ne "$?" "0" "refuses the backup name '$bad'"
done
# Pinned by reason: the pattern would refuse these too (it contains no `/`), so
# only asserting the message keeps the separator guard falsifiable.
for bad in "sub/$NAME" "../$NAME" "/abs/$NAME"; do
  out="$(run --restore "$bad" 2>&1)"
  assert_ne "$?" "0" "refuses a backup name containing a separator: '$bad'"
  assert_contains "$out" "bare file name" "'$bad' is refused by the separator check itself"
done
assert_eq "$(cat "$LOGD/stop.log")" "" "no bad name got as far as the stop"

# A missing archive is a clean refusal, not a traceback out of a root process.
reset_all
populate_world
out="$(run --restore "$NAME" 2>&1)"
assert_ne "$?" "0" "a backup that is not there is refused"
assert_not_contains "$out" "Traceback" "a missing archive is not a traceback"
assert_eq "$(cat "$LOGD/stop.log")" "" "a missing archive stopped nothing"

# ===========================================================================
# fresh install: no Pal/Saved at all
# ===========================================================================
reset_all
rm -rf "$PAL"
stage
out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"
rc=$?
assert_eq "$rc" "0" "a restore onto a host with no world at all succeeds (output: $out)"
assert_contains "$out" "safety backup: skipped" "stdout records that the safety backup was skipped"
assert_eq "$(cat "$LOGD/backup.log")" "" "no safety backup was attempted with nothing to preserve"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" "the world was created from the archive"
assert_eq "$(replaced_trees)" "0" "there was nothing to move aside"

# An existing but empty Pal/Saved is the other shape of "nothing to preserve".
reset_all
mkdir -p "$SAVED"
stage
out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"
assert_eq "$?" "0" "a restore over an empty Pal/Saved succeeds"
assert_contains "$out" "safety backup: skipped" "an empty world also skips the safety backup"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" "the empty world was replaced"

# A safety backup that *fails* is different from one that is not needed: there is
# a world to lose, so the restore must not proceed.
reset_all
populate_world
stage
out="$(STUB_BACKUP_RC=1 run --restore "$NAME" 2>&1)"
assert_ne "$?" "0" "a failed safety backup aborts the restore"
assert_contains "$out" "no way back" "the refusal says why a failed safety backup is fatal"
assert_eq "$(cat "$LOGD/stop.log")" "" "a failed safety backup stopped nothing"
assert_eq "$(cat "$SAVED/SaveGames/old.sav")" "PREVIOUS" "the world survives a failed safety backup"

# ===========================================================================
# already stopped is success; a genuine stop failure is not
# ===========================================================================
reset_all
populate_world
stage
out="$(STUB_STOP_RC=3 STUB_ACTIVE_RC=3 run --restore "$NAME" --startup-timeout 5 2>&1)"
rc=$?
assert_eq "$rc" "0" "a stop that failed with nothing running is treated as success (output: $out)"
assert_contains "$out" "already stopped" "the output says which case occurred"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" "the restore proceeded past an already-stopped server"

reset_all
populate_world
stage
out="$(STUB_STOP_RC=3 STUB_ACTIVE_RC=0 run --restore "$NAME" 2>&1)"
rc=$?
assert_ne "$rc" "0" "a stop that failed with the server still running aborts"
assert_contains "$out" "still active" "the abort names the running server as the reason"
assert_eq "$(cat "$SAVED/SaveGames/old.sav")" "PREVIOUS" "the world is not replaced under a running server"
assert_eq "$(replaced_trees)" "0" "nothing was moved aside under a running server"
assert_eq "$(staging_trees)" "0" "no staging tree survives the aborted restore"

# ===========================================================================
# the replaced tree survives every outcome that is not a positive confirmation
# ===========================================================================
# (1) the start command itself fails
reset_all
populate_world
stage
out="$(STUB_START_RC=1 run --restore "$NAME" --startup-timeout 5 2>&1)"
rc=$?
assert_ne "$rc" "0" "a failed start is a failed restore"
assert_eq "$(replaced_trees)" "1" "a failed start keeps the replaced tree"
# Pinned on the *recovery report's* own wording, not just on the path: the swap
# already printed the path as progress, so asserting the bare path would pass with
# the whole recovery report deleted. (It did, until this suite's mutation pass.)
assert_contains "$out" "the replaced world is kept at $SAVED.replaced-" \
  "the failure report names the replaced tree's path"
assert_contains "$out" "the pre-restore safety archive is palworld-save-20260101T000000Z.tar.gz" \
  "the failure report names the safety archive too, so there are two routes back"
assert_eq "$(scratch_entries)" "0" "the scratch copy is still cleaned up"
# The undo really is a rename: the replaced tree still holds the old world.
rep="$(printf '%s' "$SAVED".replaced-*)"
assert_eq "$(cat "$rep/SaveGames/old.sav" 2>/dev/null)" "PREVIOUS" \
  "the kept tree is the previous world, ready to be moved back"

# (2) the server starts but readiness never arrives
reset_all
populate_world
stage
out="$(STUB_API_RC=1 run --restore "$NAME" --startup-timeout 0 2>&1)"
rc=$?
assert_ne "$rc" "0" "a readiness timeout is a failed restore"
assert_contains "$out" "not become ready" "the failure says readiness timed out"
assert_eq "$(replaced_trees)" "1" "a readiness timeout keeps the replaced tree"
assert_contains "$out" "the replaced world is kept at $SAVED.replaced-" \
  "the timeout report names the replaced tree's path"
assert_contains "$out" "the pre-restore safety archive is palworld-save-20260101T000000Z.tar.gz" \
  "the timeout report names the safety archive too"

# The other half of the recovery report: with no world to preserve there is no
# safety archive, and saying so is more use than saying nothing.
reset_all
rm -rf "$PAL"
stage
out="$(STUB_START_RC=1 run --restore "$NAME" --startup-timeout 5 2>&1)"
assert_ne "$?" "0" "a failed start on a fresh install is still a failed restore"
assert_contains "$out" "no pre-restore safety archive was taken" \
  "the report says plainly that there is no safety archive to fall back on"
assert_eq "$(replaced_trees)" "0" "there was no tree to keep either"

# (3) REST is not configured, so readiness cannot be checked at all. The world is
# restored (exit 0) but the startup is NOT confirmed, so the tree stays.
reset_all
populate_world
stage
out="$(STUB_API_RC=2 run --restore "$NAME" --startup-timeout 5 2>&1)"
rc=$?
assert_eq "$rc" "0" "REST not being configured does not fail the restore (output: $out)"
assert_contains "$out" "readiness could NOT be verified" "the output says readiness was unverifiable"
assert_eq "$(replaced_trees)" "1" "an unverifiable startup keeps the replaced tree"
assert_contains "$out" "because the startup could not be confirmed" \
  "the output says the tree was kept *because* readiness was unverifiable"
# Exit 2 is terminal, not a state worth waiting through.
assert_eq "$(grep -c 'ARGS:info' "$LOGD/api.log")" "1" \
  "an exit-2 palworld-api is probed once, not polled to the timeout"

# ===========================================================================
# extract-then-swap: a partial extraction never touches the live tree
# ===========================================================================
reset_all
populate_world
stage
out="$(harness extractfail "" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_not_contains "$out" "rc=0" "a failed extraction is a failed restore"
assert_eq "$(cat "$SAVED/SaveGames/old.sav")" "PREVIOUS" "a failed extraction leaves the live tree intact"
assert_path_absent "$SAVED/SaveGames/marker.txt" "no part of the archive reached the live tree"
assert_eq "$(staging_trees)" "0" "the half-extracted staging tree is cleaned up"
assert_eq "$(replaced_trees)" "0" "nothing was moved aside before the extraction succeeded"
assert_eq "$(cat "$LOGD/systemctl.log")" "" "a failed extraction never starts the server"

# The same property without any monkeypatching: an unwritable parent makes the
# staging tree impossible, and the live tree still has to survive it.
if [ "$(id -u)" = "0" ]; then
  echo "  (note: running as root; skipping the unwritable-parent case)"
else
  reset_all
  populate_world
  stage
  chmod 500 "$PAL"
  out="$(run --restore "$NAME" 2>&1)"; rc=$?
  chmod 755 "$PAL"
  assert_ne "$rc" "0" "a staging tree that cannot be created aborts the restore"
  assert_contains "$out" "cannot create the staging tree" \
    "the refusal names the staging tree"
  assert_eq "$(cat "$SAVED/SaveGames/old.sav")" "PREVIOUS" "the live tree survives it"
fi

# ===========================================================================
# PROPERTY 1: the scratch copy is what gets validated and extracted
# ===========================================================================
# Structurally: the authoritative validate_archive, and the extraction, both run
# against a path inside the scratch directory and never inside the backups one.
reset_all
populate_world
stage
out="$(harness record "" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=0" "the recording harness restores cleanly (output: $out)"
assert_contains "$out" "VALIDATE=$SC/" "the authoritative validation runs on a scratch path"
assert_not_contains "$out" "VALIDATE=$BK/" "the authoritative validation never runs on the backups directory"
assert_contains "$out" "EXTRACT=$SC/" "the extraction runs on the same scratch path"
assert_not_contains "$out" "EXTRACT=$BK/" "the extraction never runs on the backups directory"

# And the guard that makes that a property of the code: hand the tool the
# backups-directory path (the regression) and it refuses by name.
reset_all
populate_world
stage
out="$(harness nocopy "" --restore "$NAME" 2>&1)"
assert_not_contains "$out" "rc=0" "validating the backups-directory archive is refused"
assert_contains "$out" "not inside the restore scratch directory" \
  "the refusal is the scratch-directory guard itself"
assert_eq "$(cat "$LOGD/stop.log")" "" "the guard fires before anything is stopped"

# A scratch directory misconfigured to sit inside the backups directory is the
# other way to lose the property, and has its own message.
reset_all
populate_world
stage
out="$(SCRATCH_OVERRIDE="$BK/scratch" run --restore "$NAME" 2>&1)"
assert_ne "$?" "0" "a scratch directory inside the backups directory is refused"
assert_contains "$out" "inside the backups directory" \
  "the refusal names the misconfiguration rather than failing obscurely"

# Behaviourally: rewrite the backups-directory archive in place *between* the copy
# and the extract — exactly what the web process can do to an archive
# palworld-backup handed it. The originally copied bytes must be what lands.
reset_all
populate_world
stage
out="$(harness rewrite "$WORK/evil.tar.gz" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=0" "the restore completes despite the archive being rewritten (output: $out)"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" \
  "the bytes that were copied are the bytes that were extracted"
assert_file_exists "$SAVED/SaveGames/0/Level.sav" \
  "the whole copied archive landed, not the rewritten one"
assert_eq "$(cat "$SAVED/Config/PalWorldSettings.ini" 2>/dev/null)" "cfg" \
  "the rewritten archive's Config never reached the world"
assert_eq "$(scratch_entries)" "0" "the scratch copy is still removed"

# The same interleaving with a *hostile* rewrite: an implementation that re-read
# the backups directory would refuse the restore naming the traversing member, so
# a clean success is itself the evidence the scratch copy was used.
reset_all
populate_world
stage
out="$(harness rewrite "$WORK/hostile.tar.gz" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=0" "a hostile in-place rewrite cannot affect the restore"
assert_not_contains "$out" "escaped.sav" "the traversing member never reached validation"
assert_path_absent "$PAL/escaped.sav" "nothing was written outside the restored tree"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" "the good world landed"

# The copy must come from the held descriptor, and this is what makes that a
# behaviour rather than a docstring: `open_archive_fd` returns a descriptor on the
# good archive and the *directory entry* is then renamed over with the evil one
# while it is open. A descriptor-based copy still lands GOOD; replacing the copy
# loop with `shutil.copy(str(src), str(tmp_path))` lands EVIL and fails here.
# (The `rewrite` case above cannot catch that: it swaps the inode's contents after
# the copy is finished, so a by-name copy would have read the good bytes too.)
reset_all
populate_world
stage
cp "$WORK/evil.tar.gz" "$WORK/evil.swap.tar.gz"
out="$(harness swapdir "$WORK/evil.swap.tar.gz" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=0" "the restore completes with the source entry swapped (output: $out)"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" \
  "the copy read the descriptor, not the swapped-in directory entry"
assert_file_exists "$SAVED/SaveGames/0/Level.sav" \
  "the whole archive the descriptor pointed at landed"
assert_eq "$(tar -xzOf "$BK/$NAME" SaveGames/marker.txt 2>/dev/null)" "EVIL" \
  "the swap really did put a different archive at the source name"

# ===========================================================================
# PROPERTY 1a: the scratch directory itself is verified, not just created
# ===========================================================================
# The reviewer's probe: substitute a *different but individually valid* archive at
# the scratch copy's name between the authoritative validation and the extraction.
# Both passes re-open by name, so nothing but an identity check stands between the
# operator and an extracted world that was never validated - and with the pre-fix
# default under /var/lib/palworld (0755, service-account-owned) the account that
# could do this was the untrusted web account.
reset_all
populate_world
stage
out="$(harness substitute "$WORK/evil.tar.gz" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_not_contains "$out" "rc=0" "a scratch copy substituted after validation is refused"
assert_contains "$out" "was replaced between validation and extraction" \
  "the refusal is the identity check itself, naming the substitution"
assert_ne "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "EVIL" \
  "the substituted archive never reached the world"
assert_eq "$(cat "$SAVED/SaveGames/old.sav" 2>/dev/null)" "PREVIOUS" \
  "the live world survives the substitution attempt"
assert_eq "$(staging_trees)" "0" "no staging tree survives the refusal"
assert_eq "$(replaced_trees)" "0" "nothing was moved aside"
assert_eq "$(cat "$LOGD/systemctl.log")" "" "the server was never started"

# And the check that makes the probe unreachable in production in the first place:
# a scratch directory owned by *another* account is refused outright, because
# mkdir(exist_ok=True), O_DIRECTORY|O_NOFOLLOW and fchmod all succeed on a
# directory someone else owns - chmod does not change ownership. /tmp is a
# convenient stand-in: root-owned, and we are not root.
if [ "$(id -u)" = "0" ]; then
  echo "  (note: running as root; skipping the foreign-owned scratch case)"
else
  reset_all
  populate_world
  stage
  out="$(SCRATCH_OVERRIDE="/tmp" run --restore "$NAME" 2>&1)"
  assert_ne "$?" "0" "a scratch directory owned by another account is refused"
  assert_contains "$out" "is owned by uid" \
    "the refusal is the ownership check itself, not a mode or a path complaint"
  assert_eq "$(cat "$LOGD/stop.log")" "" "the ownership check fires before anything is stopped"
  assert_eq "$(cat "$SAVED/SaveGames/old.sav")" "PREVIOUS" "the world is untouched"
fi

# ===========================================================================
# a world-writable *parent* is refused too
# ===========================================================================
# Owning the scratch dir and 0700 is not enough: write permission on any parent
# lets another account rename our directory aside and substitute its own. This is
# exactly why the default under /var/lib/palworld was unsound - the service
# account owns that tree - so the guarantee has to be checked, not inherited from
# the default path being correct.
reset_all
populate_world
stage
PARENT_WW="$WORK/ww-parent"
mkdir -p "$PARENT_WW/scratch"
chmod 0777 "$PARENT_WW"
out="$(SCRATCH_OVERRIDE="$PARENT_WW/scratch" run --restore "$NAME" 2>&1)"
assert_ne "$?" "0" "a scratch dir under a world-writable parent is refused"
assert_contains "$out" "writable by other accounts" \
  "the refusal names the parent, not the scratch dir itself"
assert_eq "$(cat "$LOGD/stop.log")" "" "the parent check fires before anything is stopped"
assert_eq "$(cat "$SAVED/SaveGames/old.sav")" "PREVIOUS" "the world is untouched"

# ...and a sticky world-writable parent (/tmp) is NOT refused on that ground:
# the sticky bit is precisely what stops one account renaming another's entry.
reset_all
populate_world
stage
STICKY_SCRATCH="$(mktemp -d)/scratch"
out="$(SCRATCH_OVERRIDE="$STICKY_SCRATCH" run --restore "$NAME" 2>&1)"
assert_not_contains "$out" "writable by other accounts" \
  "a sticky parent is not treated as writable by others"

# ===========================================================================
# PROPERTY 1b: the *destination* is pinned too, not just the archive
# ===========================================================================
# The scratch scheme protects the bytes root reads. It says nothing about the
# directory root writes - and `Pal/` is owned by the service account, which is the
# account palwarden-webui runs as. So the staging tree root creates can be renamed
# aside and replaced with a symlink at any moment after the mkdir. A reviewer's
# exploit did exactly that and got rc=0, "the REST API is healthy", a `Pal/Saved`
# that was a symlink, and root chowning the link's target.
#
# Three things stop it and each is asserted on its own below: the destination is
# opened O_DIRECTORY|O_NOFOLLOW and written through /proc/self/fd/<tfd>/ (so the
# extraction cannot follow a link planted afterwards), the name is re-checked
# against that descriptor before the rename (so a swapped name is not renamed into
# place), and the staging name carries entropy (so the name cannot be predicted and
# pre-placed at all).
reset_all
populate_world
stage
ATTACK="$WORK/attacker-target"
rm -rf "$ATTACK"; mkdir -p "$ATTACK"
printf 'ATTACKER\n' > "$ATTACK/keep.txt"
out="$(harness swaptree "$ATTACK" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_not_contains "$out" "rc=0" "a staging tree swapped for a symlink is refused"
assert_contains "$out" "was replaced after it was extracted" \
  "the refusal is the staging-identity check itself, naming the swap"
# The heart of it: nothing may be unpacked through the planted link. This is what
# fails if the extraction is pointed at the staging *name* instead of the held
# descriptor.
assert_path_absent "$ATTACK/SaveGames" "nothing was extracted through the planted symlink"
assert_path_absent "$ATTACK/Config" "not even the archive's Config reached the link target"
assert_eq "$(cat "$ATTACK/keep.txt")" "ATTACKER" "the link target is exactly as it was"
# ...and the live world is untouched, because the refusal lands before the swap.
assert_eq "$(cat "$SAVED/SaveGames/old.sav" 2>/dev/null)" "PREVIOUS" \
  "the live world survives the destination swap"
assert_eq "$(replaced_trees)" "0" "the live world was never moved aside"
assert_eq "$(cat "$LOGD/systemctl.log")" "" "the server was never started"
assert_eq "$(scratch_entries)" "0" "the scratch copy is still cleaned up"

# The ownership pass refuses a symlink at the root of its walk. Reached here by
# landing the swap outright - which the two checks above are what prevent - because
# this is the last line of defence and has to be falsifiable on its own.
reset_all
populate_world
stage
rm -rf "$ATTACK"; mkdir -p "$ATTACK/SaveGames"
printf 'ATTACKER\n' > "$ATTACK/SaveGames/keep.sav"
link_group=""
link_primary="$(id -gn)"
for g in $(id -Gn); do
  if [ "$g" != "$link_primary" ]; then link_group="$g"; break; fi
done
out="$(OWNER_GROUP="${link_group:-$link_primary}" harness linkroot "$ATTACK" \
        --restore "$NAME" --startup-timeout 5 2>&1)"
assert_not_contains "$out" "rc=0" "a symlink at the root of the restored tree is refused"
assert_contains "$out" "is a symbolic link" \
  "the refusal is the link check in the ownership pass"
assert_not_contains "$out" "ownership: " "no ownership was handed out at all"
assert_eq "$(cat "$ATTACK/SaveGames/keep.sav")" "ATTACKER" "the link target's contents are untouched"
if [ -n "$link_group" ]; then
  assert_eq "$(stat -c %G "$ATTACK/SaveGames/keep.sav")" "$link_primary" \
    "the link target was not chowned to the service account"
  assert_eq "$(stat -c %G "$ATTACK/SaveGames")" "$link_primary" \
    "nor was a directory under it"
else
  echo "  (note: $OWNER_USER has only one group; skipping the link-target chown check)"
fi

# The staging name carries entropy, so it cannot be predicted a second in advance.
reset_all
populate_world
stage
out="$(harness record "" --restore "$NAME" --startup-timeout 5 2>&1)"
assert_contains "$out" "rc=0" "the recording harness still restores cleanly (output: $out)"
dest="$(printf '%s\n' "$out" | sed -n 's/^DEST=//p' | head -n 1)"
if [[ "$dest" =~ \.restore-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]]; then ent="yes"; else ent="no"; fi
assert_eq "$ent" "yes" \
  "the staging tree name carries 16 hex characters of entropy after the stamp (got '$dest')"

# Behaviourally: pre-place a symlink at every name a second-resolution stamp could
# produce over the next few seconds - which is what the service account can do,
# since it owns Pal/. With entropy those names are not the one used, so the restore
# succeeds and the planted links are never touched. Without it, os.mkdir hits one
# of them (EEXIST) and the restore is dead on a name an attacker chose.
reset_all
populate_world
stage
rm -rf "$ATTACK"; mkdir -p "$ATTACK"
printf 'ATTACKER\n' > "$ATTACK/keep.txt"
now="$(date -u +%s)"
for off in 0 1 2 3 4 5; do
  ln -s "$ATTACK" "$SAVED.restore-$(date -u -d "@$((now + off))" +%Y%m%dT%H%M%SZ)" 2>/dev/null \
    || ln -s "$ATTACK" "$SAVED.restore-$(TZ=UTC date -r "$((now + off))" +%Y%m%dT%H%M%SZ)" 2>/dev/null
done
out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"
rc=$?
assert_eq "$rc" "0" "a symlink at every predictable staging name does not stop the restore (output: $out)"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" "the world was restored anyway"
assert_path_absent "$ATTACK/SaveGames" "nothing was extracted through a pre-placed link"
assert_eq "$(cat "$ATTACK/keep.txt")" "ATTACKER" "the pre-placed links' target is untouched"
rm -f "$SAVED".restore-*

# ===========================================================================
# external mode: the service question has no truthful answer, so refuse
# ===========================================================================
# In PALWARDEN_MODE=external the game runs on another host: there is no
# palworld-server s6 service, so the systemctl shim falls through to `pgrep -f
# PalServer-Linux-Shipping` and finds nothing. A failed stop against a *live*
# external server would then read as "not active" and the restore would replace
# Pal/Saved underneath it - the one thing that code path exists to prevent.
reset_all
populate_world
stage
out="$(PALWARDEN_MODE=external run --restore "$NAME" 2>&1)"
assert_ne "$?" "0" "--restore is refused in external mode"
assert_contains "$out" "not supported in PALWARDEN_MODE=external" \
  "the refusal names the mode as the reason"
assert_contains "$out" "cannot tell whether it is running" \
  "the refusal says why: the service state is unanswerable here"
assert_eq "$(cat "$LOGD/stop.log")" "" "nothing was stopped in external mode"
assert_eq "$(cat "$LOGD/systemctl.log")" "" "the service was never touched in external mode"
assert_eq "$(cat "$SAVED/SaveGames/old.sav")" "PREVIOUS" "the external world is untouched"
assert_eq "$(scratch_entries)" "0" "no scratch copy was even taken"

# embedded (and bare metal, where the variable is unset) are unaffected.
reset_all
populate_world
stage
out="$(PALWARDEN_MODE=embedded run --restore "$NAME" --startup-timeout 5 2>&1)"
assert_eq "$?" "0" "embedded mode restores normally (output: $out)"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" "the embedded restore landed"

# ===========================================================================
# pre-existing replaced trees are named, so they stop being invisible
# ===========================================================================
# Every unverifiable-readiness restore leaves one of these beside the target
# forever. Nothing ever mentioned them again, so they accumulate at a full world
# save each; listing them at the start is the whole fix (no du, no deleting).
reset_all
populate_world
stage
# Both kinds. A `.restore-*` tree is a full world save exactly as much as a
# `.replaced-*` one is, and it can now outlive a restore *by design* — a swap that
# fails after it has started moving entries in keeps its staging tree on purpose,
# because it holds the entries that never landed. The glob used to cover
# `.replaced-*` only, so the kind this feature made survivable was the kind that
# went unreported.
mkdir -p "$SAVED.replaced-20260101T000000Z/SaveGames" \
         "$SAVED.replaced-20260102T000000Z/SaveGames" \
         "$SAVED.restore-20260103T000000Z/SaveGames"
out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"
assert_eq "$?" "0" "pre-existing leftover trees do not stop a restore"
assert_contains "$out" "3 leftover world tree(s) from earlier restores" \
  "the restore counts the trees left by earlier ones"
assert_contains "$out" "Saved.replaced-20260101T000000Z" "the first stale tree is named"
assert_contains "$out" "Saved.replaced-20260102T000000Z" "the second stale tree is named"
assert_contains "$out" "Saved.restore-20260103T000000Z" \
  "a leftover staging tree is named too, not just the replaced ones"
# This restore's own replaced tree is deleted on its confirmed startup; the older
# ones are named and left exactly where they were.
assert_eq "$(replaced_trees)" "2" "naming the stale trees does not delete them"
assert_eq "$(staging_trees)" "1" "...and the stale staging tree is left alone as well"
rm -rf "$SAVED".replaced-* "$SAVED".restore-*

# With none there, no note is printed - so the note cannot be a constant string.
reset_all
populate_world
stage
out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"
assert_not_contains "$out" "from earlier restores" \
  "a first restore says nothing about trees that are not there"

# ===========================================================================
# ownership
# ===========================================================================
# Asserted on a *secondary* group: the primary group is what files get at
# creation, so asserting on it would pass whether or not the chown ran at all.
sec_group=""
primary="$(id -gn)"
for g in $(id -Gn); do
  if [ "$g" != "$primary" ]; then sec_group="$g"; break; fi
done
if [ -z "$sec_group" ]; then
  echo "  (note: $OWNER_USER has only one group; skipping the ownership check)"
else
  reset_all
  populate_world
  stage
  OWNER_GROUP="$sec_group"
  out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"; rc=$?
  OWNER_GROUP="$(id -gn)"
  assert_eq "$rc" "0" "the restore succeeds while chowning to a secondary group (output: $out)"
  assert_eq "$(stat -c %G "$SAVED")" "$sec_group" "the restored tree's root is chowned"
  assert_eq "$(stat -c %G "$SAVED/SaveGames/marker.txt")" "$sec_group" "a restored file is chowned"
  assert_eq "$(stat -c %G "$SAVED/SaveGames/0")" "$sec_group" "a restored subdirectory is chowned"
  assert_eq "$(stat -c %G "$SAVED/SaveGames/0/Level.sav")" "$sec_group" "a nested restored file is chowned"
fi

# An unresolvable account warns and does not abort: a world owned by root is
# fixable, a restore refused at the last step is not.
reset_all
populate_world
stage
OWNER_USER="definitely-no-such-user-palwarden"
OWNER_GROUP="definitely-no-such-group-palwarden"
out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"
rc=$?
OWNER_USER="$(id -un)"; OWNER_GROUP="$(id -gn)"
assert_eq "$rc" "0" "an unresolvable service account does not fail the restore"
# Pinned on the account name too: a bare "does not exist" is also in
# _safety_backup's skip message, so the loose form would pass for the wrong reason
# on any run where the world happened to be missing.
assert_contains "$out" "user 'definitely-no-such-user-palwarden' does not exist" \
  "the unresolvable user is warned about, not swallowed"
assert_contains "$out" "group 'definitely-no-such-group-palwarden' does not exist" \
  "the unresolvable group is warned about separately"
assert_eq "$(cat "$SAVED/SaveGames/marker.txt" 2>/dev/null)" "GOOD" "the world was still restored"

# ===========================================================================
# docs
# ===========================================================================
assert_file_contains "$DOCS/tools.md" "palworld-restore" \
  "docs/tools.md documents palworld-restore"
assert_file_contains "$DOCS/tools.md" "--restore" \
  "docs/tools.md documents the --restore mode"
assert_file_contains "$DOCS/tools.md" "--import" \
  "docs/tools.md documents the --import mode"
# The space requirement, which is a deployment fact an operator cannot derive from
# the tool's own output: the cross-mount fallback holds the staging tree and the
# replaced tree on the server volume at once, so a containerised restore needs
# roughly twice the world free there.
assert_file_contains "$DOCS/tools.md" "2× the world" \
  "docs/tools.md states the free-space requirement of the copy fallback"

assert_report
