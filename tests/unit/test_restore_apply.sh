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
mkdir -p "$SAVED.replaced-20260101T000000Z/SaveGames" \
         "$SAVED.replaced-20260102T000000Z/SaveGames"
out="$(run --restore "$NAME" --startup-timeout 5 2>&1)"
assert_eq "$?" "0" "pre-existing replaced trees do not stop a restore"
assert_contains "$out" "2 replaced world tree(s) from earlier restores" \
  "the restore counts the trees left by earlier ones"
assert_contains "$out" "Saved.replaced-20260101T000000Z" "the first stale tree is named"
assert_contains "$out" "Saved.replaced-20260102T000000Z" "the second stale tree is named"
# This restore's own replaced tree is deleted on its confirmed startup; the two
# older ones are named and left exactly where they were.
assert_eq "$(replaced_trees)" "2" "naming the stale trees does not delete them"
rm -rf "$SAVED".replaced-*

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

assert_report
