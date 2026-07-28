#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palworld-backups owns the archive *collection*: explicit deletion, retention
# pruning, and the schedule tick. The two removal paths have deliberately
# different safety rules, and most of this suite exists to hold that asymmetry in
# place, because it is exactly the kind of difference a later "unification" erases:
#
#   * --prune has a floor. It keeps the newest BACKUP_KEEP_MIN whatever their age,
#     and never empties the directory whatever the settings say.
#   * --delete has no floor. The operator passed three confirmations in the UI, so
#     deleting the only archive is allowed.
#
# A test that asserted only "deletion works" and "pruning works" would stay green
# with either rule copied onto the other.
#
# Assertion style note, learned three times the hard way on this feature: an
# assertion on a bare archive name can pass off an earlier *progress* line that
# happens to contain the same name, so deleting the behaviour under test changes
# nothing. Here the load-bearing assertions are on the filesystem
# (assert_file_exists / assert_path_absent / a count of what is left) and on
# wording distinctive to one specific message.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
TOOL="$DIR/../../sbin/palworld-backups"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BACKUPS="$WORK/backups"
SCHED="$WORK/backup.env"
STUB="$WORK/sbin"
LOG="$WORK/backup-invoked.log"
mkdir -p "$BACKUPS" "$STUB"

# Stands in for the real sbin/palworld-backup: records the argv it was called with
# and produces an archive named the way the real tool names one, so the *effect* of
# --if-due is observable and so a composed `--if-due --prune` prunes a collection
# that really does include the new archive.
cat > "$STUB/palworld-backup" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$0" "\$@" >> "$LOG"
dest="$BACKUPS/palworld-save-\$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
printf 'stub-archive\n' > "\$dest"
echo "\$dest"
STUBEOF
chmod +x "$STUB/palworld-backup"

backups() {  # backups <args...>
  env PALWARDEN_SAVE_BACKUP_DIR="$BACKUPS" \
      PALWARDEN_SBIN_DIR="$STUB" \
      PALWORLD_BACKUP_SCHEDULE="$SCHED" \
      python3 "$TOOL" "$@"
}

reset_dir() { rm -rf "$BACKUPS" "$LOG"; mkdir -p "$BACKUPS"; }
reset_sched() { rm -f "$SCHED"; }

# mk <days-ago> -> echoes the archive name it created.
# The name's UTC stamp and the file's mtime are both derived from the same
# days-ago value, so name order and age order agree — which is what lets one
# fixture exercise both the name-ordered floor and the mtime-based age test.
mk() {
  local days="$1" stamp name
  stamp="$(date -u -d "$days days ago" +%Y%m%dT%H%M%SZ)"
  name="palworld-save-$stamp.tar.gz"
  printf 'archive\n' > "$BACKUPS/$name"
  touch -d "$days days ago" "$BACKUPS/$name"
  echo "$name"
}

count() { find "$BACKUPS" -maxdepth 1 -name 'palworld-save-*.tar.gz' | wc -l | tr -d ' '; }

# --- argv surface -------------------------------------------------------------
# --help must exit 0 while a bare invocation must not: a mode-less run that
# silently did nothing is how a broken timer stays invisible.
assert_rc 0 backups --help
assert_rc 2 backups
assert_rc 2 backups --frobnicate

# --delete and --show-schedule are exclusive with everything; --if-due and --prune
# are designed to COMPOSE, because that is the argv the periodic service runs.
reset_dir
only="$(mk 1)"
assert_rc 2 backups --delete "$only" --prune
assert_rc 2 backups --show-schedule --prune
assert_rc 0 backups --if-due --prune

# --- --delete removes exactly the named archive ------------------------------
reset_dir; reset_sched
a="$(mk 9)"; b="$(mk 6)"; c="$(mk 3)"
out="$(backups --delete "$b" 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--delete of a real archive succeeds"
assert_path_absent "$BACKUPS/$b" "--delete removed the named archive"
assert_file_exists "$BACKUPS/$a" "--delete left the older archive alone"
assert_file_exists "$BACKUPS/$c" "--delete left the newer archive alone"
assert_eq "$(count)" "2" "--delete removed exactly one archive"
assert_contains "$out" "deleted backup" "--delete reports the removal"
assert_eq "$(wc -c < "$WORK/err" | tr -d ' ')" "0" "a successful delete is silent on stderr"

# --- --delete refusals: nothing is removed in any case -----------------------
# Each refusal asserts on wording distinctive to *that* message, not merely on a
# non-zero exit: several of these guards overlap in effect (a symlink is also not
# a regular file), so the exit code alone cannot tell them apart and would stay
# green with the more specific guard deleted.
reset_dir
a="$(mk 9)"; b="$(mk 6)"

assert_rc 1 backups --delete "not-a-backup.tar.gz"
backups --delete "not-a-backup.tar.gz" 2>"$WORK/err" >/dev/null
assert_file_contains "$WORK/err" "is not a name palworld-backup could have written" \
  "a name outside the pattern is refused as one palworld-backup could not have written"
assert_eq "$(count)" "2" "a pattern refusal removes nothing"

# A real file in the backups directory whose name is not an archive name. Without
# the pattern check this one is genuinely unlinked, so the assertion is about an
# effect and not only about a message: the tool must not become a way to delete an
# arbitrary file out of a root-owned directory.
printf 'operator notes\n' > "$BACKUPS/keepme.txt"
backups --delete "keepme.txt" 2>"$WORK/err" >/dev/null; rc=$?
assert_ne "$rc" "0" "a non-archive file in the backups directory is not deletable"
assert_file_exists "$BACKUPS/keepme.txt" "and it is still there afterwards"
rm -f "$BACKUPS/keepme.txt"

backups --delete "sub/$b" 2>"$WORK/err" >/dev/null; rc=$?
assert_ne "$rc" "0" "a name with a separator is refused"
assert_file_contains "$WORK/err" "must be a bare file name" \
  "the separator refusal says the name must be bare"
backups --delete "../$b" 2>"$WORK/err2" >/dev/null
assert_file_contains "$WORK/err2" "must be a bare file name" \
  "and a traversal is refused the same way"
assert_eq "$(count)" "2" "separator refusals remove nothing"

# A symlink wearing a perfectly valid archive name. The backups directory is
# root-owned, but every archive in it is chowned to the service account that the
# web process runs as, so a planted link is the shape to refuse — and it must be
# refused by *name*, with a message that says symlink, rather than surfacing as
# some later error.
printf 'VICTIM\n' > "$WORK/victim"
linkname="palworld-save-$(date -u -d '2 days ago' +%Y%m%dT%H%M%SZ).tar.gz"
ln -s "$WORK/victim" "$BACKUPS/$linkname"
backups --delete "$linkname" 2>"$WORK/err" >/dev/null; rc=$?
assert_ne "$rc" "0" "a symlink under a valid archive name is refused"
assert_file_contains "$WORK/err" "is a symlink" \
  "the symlink refusal names the actual problem rather than a generic one"
if [ -L "$BACKUPS/$linkname" ]; then pass; else fail "the refused symlink was removed"; fi
assert_file_exists "$WORK/victim" "and its target is untouched"
rm -f "$BACKUPS/$linkname"

# A FIFO wearing a valid archive name. This is what makes the regular-file
# requirement falsifiable on its own: the symlink guard above does not see a FIFO,
# and `os.unlink` removes one perfectly happily — so without the S_ISREG test the
# tool would report "deleted backup" for something that was never an archive.
# Found by mutation testing: the symlink and regular-file checks were shielding
# each other, and either could have been deleted with the suite still green.
fifoname="palworld-save-$(date -u -d '4 days ago' +%Y%m%dT%H%M%SZ).tar.gz"
mkfifo "$BACKUPS/$fifoname"
backups --delete "$fifoname" 2>"$WORK/err" >/dev/null; rc=$?
assert_ne "$rc" "0" "a FIFO under a valid archive name is refused"
assert_file_contains "$WORK/err" "not a regular file" \
  "the refusal says the entry is not a regular file"
if [ -p "$BACKUPS/$fifoname" ]; then pass; else fail "the refused FIFO was unlinked"; fi
rm -f "$BACKUPS/$fifoname"

missing="palworld-save-19990101T000000Z.tar.gz"
backups --delete "$missing" 2>"$WORK/err" >/dev/null; rc=$?
assert_ne "$rc" "0" "a valid name that does not exist is an error, not a silent success"
assert_file_contains "$WORK/err" "no such backup" \
  "the missing-archive refusal says so"
assert_eq "$(count)" "2" "every refusal above left both archives in place"

# --- --delete has NO floor ---------------------------------------------------
# The operator passed three confirmations in the UI to get here. Refusing would
# override a decision they stated three times, so the only archive may go. This is
# the asymmetry against --prune below; a change that gave --delete a floor for
# safety's sake must fail here.
reset_dir
only="$(mk 1)"
out="$(backups --delete "$only" 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--delete of the ONLY archive succeeds"
assert_path_absent "$BACKUPS/$only" "the only archive really is gone"
assert_eq "$(count)" "0" "--delete left the directory empty, as asked"
assert_not_contains "$out" "last remaining" "--delete does not invoke prune's floor"
assert_file_not_contains "$WORK/err" "last remaining" "not on stderr either"

# --- --prune: age past the window, with the newest KEEP_MIN kept regardless ---
reset_dir
printf 'BACKUP_RETENTION_DAYS=14\nBACKUP_KEEP_MIN=3\n' > "$SCHED"
old1="$(mk 40)"; old2="$(mk 30)"; old3="$(mk 20)"
new1="$(mk 10)"; new2="$(mk 5)"; new3="$(mk 1)"
out="$(backups --prune 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--prune succeeds"
assert_path_absent "$BACKUPS/$old1" "an archive past the retention window is pruned"
assert_path_absent "$BACKUPS/$old2" "so is the next one past it"
assert_path_absent "$BACKUPS/$old3" "and the third"
assert_file_exists "$BACKUPS/$new1" "an archive inside the window survives"
assert_file_exists "$BACKUPS/$new2" "as does the next"
assert_file_exists "$BACKUPS/$new3" "and the newest"
assert_eq "$(count)" "3" "--prune deleted exactly the three archives past the window"
assert_contains "$out" "pruned" "--prune reports what it removed"

# The KEEP_MIN floor on its own: every archive is far past the window, so age alone
# would empty the directory. A host powered off for a month must not wake with
# nothing, so the newest BACKUP_KEEP_MIN stay whatever their age.
reset_dir
printf 'BACKUP_RETENTION_DAYS=14\nBACKUP_KEEP_MIN=3\n' > "$SCHED"
p1="$(mk 40)"; p2="$(mk 35)"; p3="$(mk 30)"; p4="$(mk 25)"
backups --prune >/dev/null 2>&1
assert_path_absent "$BACKUPS/$p1" "the oldest archive beyond the floor is still pruned"
assert_file_exists "$BACKUPS/$p2" "the third-newest is kept by BACKUP_KEEP_MIN despite its age"
assert_file_exists "$BACKUPS/$p3" "the second-newest too"
assert_file_exists "$BACKUPS/$p4" "and the newest"
assert_eq "$(count)" "3" "BACKUP_KEEP_MIN archives survive an all-expired collection"

# --- list_archives' filters, driven through --prune, not merely shielded ------
# Every fixture above puts only well-named regular archives in the directory, so
# none of them can tell a filtered entry from an unfiltered one apart. These do,
# by planting the two things list_archives is supposed to keep OUT of the
# collection, old enough that they would be prune candidates if they got in.
reset_dir
printf 'BACKUP_RETENTION_DAYS=14\nBACKUP_KEEP_MIN=3\n' > "$SCHED"
old1="$(mk 40)"; old2="$(mk 30)"; old3="$(mk 20)"
new1="$(mk 10)"; new2="$(mk 5)"; new3="$(mk 1)"
# An operator file that happens to live in the backups directory. Without the
# valid_archive_name filter this is a genuine, aged prune candidate, which would
# make --prune a way to delete an arbitrary file out of a root-owned directory.
printf 'operator notes\n' > "$BACKUPS/keepme.txt"
touch -d '90 days ago' "$BACKUPS/keepme.txt"
# palworld-restore's in-flight import temp: same directory, aged, and named so it
# would sort as an ordinary prune candidate too. Without the filter, --prune can
# destroy a promotion that is mid-copy.
importtmp=".${new1}.import.deadbeefcafef00d"
printf 'in-flight promotion\n' > "$BACKUPS/$importtmp"
touch -d '50 days ago' "$BACKUPS/$importtmp"
before="$(count)"
out="$(backups --prune 2>"$WORK/err")"
assert_file_exists "$BACKUPS/keepme.txt" \
  "a foreign non-archive file survives --prune untouched"
assert_file_exists "$BACKUPS/$importtmp" \
  "an in-flight --import temp file survives --prune untouched"
assert_eq "$(count)" "3" "--prune removed exactly the three expired archives, no more"
assert_eq "$((before - $(count)))" "3" \
  "the archive count dropped by exactly the number of expired archives"

# The guard-inversion shape: "zz-notes.txt" sorts AFTER every "palworld-save-…"
# name (ASCII 'z' > 'p'). If a foreign name like this were ever counted as an
# archive, it would occupy the lexically-newest slot instead of the real archive,
# which flips which one BACKUP_KEEP_MIN and the never-empty guard protect. One
# real, old archive plus one such foreign file is the minimal case where that
# flip is observable: the guard must still protect the ARCHIVE, not the note.
reset_dir; reset_sched
printf 'BACKUP_RETENTION_DAYS=1\nBACKUP_KEEP_MIN=1\n' > "$SCHED"
lone="$(mk 90)"
printf 'zz notes\n' > "$BACKUPS/zz-notes.txt"
touch -d '90 days ago' "$BACKUPS/zz-notes.txt"
backups --prune >/dev/null 2>&1
assert_file_exists "$BACKUPS/$lone" \
  "the sole real archive survives even with a lexically-later foreign name present"
assert_file_exists "$BACKUPS/zz-notes.txt" \
  "the foreign file is never a --prune candidate at all"
assert_eq "$(count)" "1" \
  "the never-empty guard still protects the real archive, not the note"

# An old symlink under a valid archive name, its own timestamp aged (not just its
# target's), pointing outside the directory. The backups directory is root-owned
# but every archive in it is chowned to the service account, so a planted link is
# exactly the shape to refuse — here via list_archives, since --prune never
# names an individual entry the way --delete does.
reset_dir; reset_sched
printf 'BACKUP_RETENTION_DAYS=1\nBACKUP_KEEP_MIN=1\n' > "$SCHED"
lone="$(mk 90)"
printf 'VICTIM\n' > "$WORK/prune-victim"
linkname="palworld-save-$(date -u -d '95 days ago' +%Y%m%dT%H%M%SZ).tar.gz"
ln -s "$WORK/prune-victim" "$BACKUPS/$linkname"
touch -h -d '95 days ago' "$BACKUPS/$linkname"
backups --prune >/dev/null 2>&1
if [ -L "$BACKUPS/$linkname" ]; then pass; else fail "an archive-named symlink was removed by --prune"; fi
assert_file_exists "$WORK/prune-victim" "and its target is untouched"
assert_file_exists "$BACKUPS/$lone" "the real archive it would have displaced is still here"
rm -f "$BACKUPS/$linkname"

# --- --prune does NOT delete by count ----------------------------------------
# A burst of restores (each taking a pre-restore safety archive) must not push out
# an older archive that is still inside the retention window. Eight archives, all
# recent, KEEP_MIN=3: a count-based implementation keeps three and this fails.
reset_dir
printf 'BACKUP_RETENTION_DAYS=14\nBACKUP_KEEP_MIN=3\n' > "$SCHED"
for d in 1 2 3 4 5 6 7 8; do mk "$d" >/dev/null; done
out="$(backups --prune 2>"$WORK/err")"
assert_eq "$(count)" "8" "every archive inside the retention window survives, however many there are"
assert_contains "$out" "nothing to prune" "--prune says it did nothing rather than staying silent"

# --- --prune never empties the directory -------------------------------------
# Through the CLI this is the KEEP_MIN floor doing the work (the schedule reader
# clamps BACKUP_KEEP_MIN to >= 1), which is exactly why the guard is also driven
# directly below.
reset_dir
printf 'BACKUP_RETENTION_DAYS=1\nBACKUP_KEEP_MIN=1\n' > "$SCHED"
lone="$(mk 100)"
backups --prune >/dev/null 2>&1
assert_file_exists "$BACKUPS/$lone" \
  "--prune keeps the last archive even at RETENTION_DAYS=1 and KEEP_MIN=1"
assert_eq "$(count)" "1" "the directory is never emptied by retention"

# The never-empty guard on its own terms. prune_archives is called directly with
# keep_min=0 — a value read_schedule can never produce, deliberately bypassing the
# clamp, because the clamp is what makes this guard unreachable from the CLI. A
# guard whose only defence is another guard has no test of its own, and this one is
# precisely what has to survive a bug in the clamp: retention that can empty the
# backups directory is a data-loss bug.
reset_dir
g1="$(mk 200)"; g2="$(mk 100)"
guard="$(env PALWARDEN_SAVE_BACKUP_DIR="$BACKUPS" python3 - "$TOOL" 2>/dev/null <<'EOF'
import contextlib, importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("backups_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

# The tool's progress lines go to stderr here so the only thing on stdout is the
# count: an assertion that had to match a number *inside* a page of progress output
# is exactly the shape that passes for the wrong reason.
with contextlib.redirect_stdout(sys.stderr):
    deleted = mod.prune_archives(retention_days=1, keep_min=0)
print(len(deleted))
EOF
)"
assert_eq "$guard" "1" "with keep_min=0 the guard stops after deleting all but one"
assert_path_absent "$BACKUPS/$g1" "the older of the two expired archives is pruned"
assert_file_exists "$BACKUPS/$g2" "the last remaining archive survives keep_min=0"
assert_eq "$(count)" "1" "prune_archives cannot empty the directory even when asked to"

# --- the due decision, as pure logic -----------------------------------------
# Driven as a function so the interval can be crossed without waiting real hours,
# and so the boundary case (age exactly equal to the interval) is pinned.
due="$(python3 - "$TOOL" <<'EOF'
import importlib.machinery, importlib.util, sys

loader = importlib.machinery.SourceFileLoader("backups_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)

now = 1_000_000.0
h = 3600.0
print(mod.backup_due(None, now, 24),
      mod.backup_due(now - 23 * h, now, 24),
      mod.backup_due(now - 25 * h, now, 24),
      mod.backup_due(now - 24 * h, now, 24),
      mod.backup_due(now - 2 * h, now, 1))
EOF
)"
assert_eq "$due" "True False True True True" \
  "due with no archive, not due inside the interval, due past it, due exactly on it"

# --- --if-due through the CLI ------------------------------------------------
# BACKUP_ENABLED=false is what lets the periodic service stay enabled while the
# operator turns backups off from the browser, so it must create nothing at all.
reset_dir
printf 'BACKUP_ENABLED=false\n' > "$SCHED"
out="$(backups --if-due 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--if-due exits 0 when backups are disabled"
assert_path_absent "$LOG" "BACKUP_ENABLED=false invokes palworld-backup not at all"
assert_eq "$(count)" "0" "and creates no archive"
assert_contains "$out" "disabled" "--if-due says why it did nothing"

# BACKUP_ENABLED=false stops *creating*, and does NOT stop retention. Both
# directions are asserted because neither was, and the wrong half of the pair was
# what config/backup.env used to promise: an operator reading "master switch" turned
# backups off to freeze a known-good set, and every tick kept pruning it.
#
# The composition is what makes this reachable — the timer and the s6 service both
# run `--if-due --prune` in ONE invocation, and --prune is unconditional on purpose
# (a full volume is the likeliest reason a create fails, and retention is what frees
# the space). So this is the shipped behaviour, and it is now what the file says.
reset_dir
printf 'BACKUP_ENABLED=false\nBACKUP_RETENTION_DAYS=14\nBACKUP_KEEP_MIN=1\n' > "$SCHED"
expired="$(mk 40)"; fresh="$(mk 1)"
out="$(backups --if-due --prune 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--if-due --prune exits 0 with backups disabled"
assert_path_absent "$LOG" "nothing was created while backups are switched off"
assert_path_absent "$BACKUPS/$expired" \
  "the expired archive is still pruned with BACKUP_ENABLED=false"
assert_file_exists "$BACKUPS/$fresh" "the in-window archive is left alone"
assert_contains "$out" "creating nothing" "the tick says it created nothing"
assert_contains "$out" "prune: removed 1 archive(s)" "...and says it pruned anyway"

# The other direction, which is the remedy the file now points at: retention is what
# decides what survives, so raising it freezes the set even with backups off.
reset_dir
printf 'BACKUP_ENABLED=false\nBACKUP_RETENTION_DAYS=3650\nBACKUP_KEEP_MIN=100\n' > "$SCHED"
expired="$(mk 40)"; fresh="$(mk 1)"
out="$(backups --if-due --prune 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--if-due --prune exits 0 with retention raised"
assert_file_exists "$BACKUPS/$expired" \
  "raising BACKUP_RETENTION_DAYS is what actually freezes the older archive"
assert_file_exists "$BACKUPS/$fresh" "...and the newer one"
assert_eq "$(count)" "2" "nothing at all was pruned"
assert_contains "$out" "nothing to prune" "the tick says there was nothing to prune"

# And the file has to say it, because the wording is what an operator acts on.
assert_file_contains "$DIR/../../config/backup.env" "does not stop retention" \
  "config/backup.env says BACKUP_ENABLED=false does not stop retention"
assert_file_contains "$DIR/../../config/backup.env" "raise BACKUP_RETENTION_DAYS" \
  "...and names raising retention as the way to freeze a set"

# No archive at all: the first tick on a fresh host must back up.
reset_dir; reset_sched
out="$(backups --if-due 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--if-due succeeds with an empty backups directory"
assert_file_exists "$LOG" "--if-due invoked palworld-backup when nothing exists yet"
assert_eq "$(cat "$LOG")" "$STUB/palworld-backup" \
  "palworld-backup is invoked with a fixed argv and no extra arguments"
assert_eq "$(count)" "1" "and an archive now exists"

# Inside the interval: nothing to do.
reset_dir
printf 'BACKUP_INTERVAL_HOURS=24\n' > "$SCHED"
fresh="$(mk 0)"
out="$(backups --if-due 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--if-due exits 0 when a backup is not due"
assert_path_absent "$LOG" "a backup taken minutes ago does not trigger another"
assert_file_exists "$BACKUPS/$fresh" "and the existing archive is left alone"
assert_contains "$out" "not due" "--if-due says the backup is not due"

# Past the interval: due.
reset_dir
printf 'BACKUP_INTERVAL_HOURS=24\n' > "$SCHED"
stale="$(mk 2)"
backups --if-due >/dev/null 2>&1
assert_file_exists "$LOG" "an archive older than the interval triggers a backup"
assert_file_exists "$BACKUPS/$stale" "--if-due creates, it never removes"
assert_eq "$(count)" "2" "the new archive joins the old one"

# --- newest_archive_mtime uses the archive's mtime, not the name's stamp -----
# mk() deliberately derives an archive's name stamp and its mtime from the same
# days-ago value, so in every fixture above the two orderings agree and cannot
# tell "newest by name" from "newest by mtime" apart. An --import promotion is
# the documented case where they disagree: an old-named archive can be touched
# just now. Two archives are needed, not one: the name-newest one is genuinely
# old, and a name-OLDER one is the one just touched, so a scheduler that used
# the name-newest archive's mtime (list_archives()[:1]) would see the wrong,
# older mtime and wrongly call a backup due.
reset_dir
printf 'BACKUP_INTERVAL_HOURS=24\n' > "$SCHED"
recent_named="$(mk 5)"    # name-newest; genuinely 5 days old, past the interval
promoted="$(mk 40)"       # name-oldest...
touch "$BACKUPS/$promoted"  # ...but just (re)written, as an --import promotion would
out="$(backups --if-due 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--if-due succeeds when the name-newest and mtime-newest archives differ"
assert_path_absent "$LOG" \
  "the freshly-touched, name-oldest archive decides due-ness by mtime: not due"
assert_contains "$out" "not due" \
  "a promoted archive's mtime, not its name, is what the schedule reads"
assert_file_exists "$BACKUPS/$recent_named" "--if-due did not remove anything here"
assert_file_exists "$BACKUPS/$promoted" "nor create anything, since it correctly saw 'not due'"
assert_eq "$(count)" "2" "the collection is unchanged by a due-check that found nothing due"

# --- --if-due --prune compose, in that order ---------------------------------
# The order is the point, not an accident: retention is applied to the collection
# INCLUDING the archive just created, so the new archive counts toward
# BACKUP_KEEP_MIN and the expired ones age out in the same tick. Pruning first
# would leave the directory one archive over the floor until the next tick — which
# is what this fixture distinguishes: with KEEP_MIN=1, prune-then-create leaves the
# 30-day archive behind, create-then-prune does not.
reset_dir
printf 'BACKUP_ENABLED=true\nBACKUP_INTERVAL_HOURS=24\nBACKUP_RETENTION_DAYS=14\nBACKUP_KEEP_MIN=1\n' > "$SCHED"
c1="$(mk 40)"; c2="$(mk 30)"
out="$(backups --if-due --prune 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--if-due --prune runs both in one invocation"
assert_file_exists "$LOG" "the composed run created the due backup"
assert_path_absent "$BACKUPS/$c1" "and pruned the oldest expired archive"
assert_path_absent "$BACKUPS/$c2" \
  "and the second expired one too, which only holds if the create ran BEFORE the prune"
assert_eq "$(count)" "1" "only the freshly created archive is left"

# --- --show-schedule ---------------------------------------------------------
reset_dir; reset_sched
out="$(backups --show-schedule 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "--show-schedule succeeds with no schedule file at all"
assert_contains "$out" '"BACKUP_ENABLED": true' "the default is enabled"
assert_contains "$out" '"BACKUP_INTERVAL_HOURS": 24' "default interval"
assert_contains "$out" '"BACKUP_RETENTION_DAYS": 14' "default retention"
assert_contains "$out" '"BACKUP_KEEP_MIN": 3' "default floor"
assert_eq "$(wc -c < "$WORK/err" | tr -d ' ')" "0" "an absent schedule file is not a warning"
# Really JSON, not something that merely looks like it — the web UI parses this.
# The key SET is pinned too: Task 6's HTTP endpoint and the browser panel both
# consume this JSON as-is, so a fifth key added here for an unrelated reason
# would ship into the API silently unless a test enumerates all four and no
# more. Types are pinned alongside the keys, using `type(x) is int` rather than
# `isinstance`, because bool is a subclass of int in Python: isinstance would
# not catch BACKUP_KEEP_MIN silently becoming a JSON bool.
assert_rc 0 python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert sorted(d) == ['BACKUP_ENABLED', 'BACKUP_INTERVAL_HOURS', 'BACKUP_KEEP_MIN',
                      'BACKUP_RETENTION_DAYS'], sorted(d)
assert type(d['BACKUP_ENABLED']) is bool, type(d['BACKUP_ENABLED'])
for key in ('BACKUP_INTERVAL_HOURS', 'BACKUP_RETENTION_DAYS', 'BACKUP_KEEP_MIN'):
    assert type(d[key]) is int, (key, type(d[key]))
" <(printf '%s' "$out")

printf '# a comment\n\nBACKUP_ENABLED="false"\nBACKUP_INTERVAL_HOURS=6\nBACKUP_RETENTION_DAYS=30\nBACKUP_KEEP_MIN=5\nNOT_OURS=whatever\n' > "$SCHED"
out="$(backups --show-schedule 2>"$WORK/err")"
assert_contains "$out" '"BACKUP_ENABLED": false' "a quoted false is read as false"
assert_contains "$out" '"BACKUP_INTERVAL_HOURS": 6' "the file's interval is used"
assert_contains "$out" '"BACKUP_RETENTION_DAYS": 30' "the file's retention is used"
assert_contains "$out" '"BACKUP_KEEP_MIN": 5' "the file's floor is used"
assert_not_contains "$out" "NOT_OURS" "keys that are not ours are ignored"
assert_eq "$(wc -c < "$WORK/err" | tr -d ' ')" "0" "a valid schedule file is silent"

# --- a typo must not take out the scheduled backup ---------------------------
# Out of range and unparseable values warn and fall back to the DEFAULT, rather
# than raising: an unreadable schedule that crashed the tick would silently stop
# backups on the one host whose operator was editing the file.
printf 'BACKUP_INTERVAL_HOURS=999999\n' > "$SCHED"
out="$(backups --show-schedule 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "an out-of-range value does not crash the tool"
assert_contains "$out" '"BACKUP_INTERVAL_HOURS": 24' "an over-range interval falls back to the default"
assert_file_contains "$WORK/err" "BACKUP_INTERVAL_HOURS" "the warning names the key"
assert_file_contains "$WORK/err" "999999" "and the value it refused"

printf 'BACKUP_KEEP_MIN=0\n' > "$SCHED"
out="$(backups --show-schedule 2>"$WORK/err")"
assert_contains "$out" '"BACKUP_KEEP_MIN": 3' "an under-range floor falls back to the default"
assert_file_contains "$WORK/err" "BACKUP_KEEP_MIN" "and says which key was wrong"

printf 'BACKUP_RETENTION_DAYS=soon\n' > "$SCHED"
out="$(backups --show-schedule 2>"$WORK/err")"; rc=$?
assert_eq "$rc" "0" "an unparseable value does not crash the tool"
assert_contains "$out" '"BACKUP_RETENTION_DAYS": 14' "an unparseable retention falls back to the default"
assert_file_contains "$WORK/err" "soon" "the warning quotes the value it could not read"

printf 'BACKUP_ENABLED=maybe\n' > "$SCHED"
out="$(backups --show-schedule 2>"$WORK/err")"
assert_contains "$out" '"BACKUP_ENABLED": true' "an unparseable bool falls back to enabled"
assert_file_contains "$WORK/err" "BACKUP_ENABLED" "and says so"

# A schedule file that cannot be parsed at all must still leave --if-due working:
# the whole reason for the fall-back is that the tick keeps running.
reset_dir
printf 'BACKUP_INTERVAL_HOURS=nonsense\n' > "$SCHED"
backups --if-due >/dev/null 2>&1
assert_file_exists "$LOG" "--if-due still backs up with an unparseable schedule file"

assert_report
