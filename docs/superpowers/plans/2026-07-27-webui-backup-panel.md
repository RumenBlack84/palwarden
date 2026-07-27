# Web UI backup panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a world save recoverable from the browser after a total failure — create, download, re-upload and restore an archive — plus scheduled backups with retention, and deletion behind three confirmations.

**Architecture:** Two new root tools own the archive collection (`palworld-backups`) and turning an archive back into a world (`palworld-restore`). The unprivileged web process streams uploads into a staging directory **it** owns and never writes to the root-owned backups directory; root validates and promotes. Scheduling lives in a config file read every tick, so one design works on systemd and s6 without rewriting units.

**Tech Stack:** Python 3 standard library only (`tarfile` with `filter='data'`, available on the image's 3.13). Bash for the existing-style shell tools. `tests/lib/assert.sh` for tests. systemd timers (bare metal) and s6-overlay + `palwarden-run-periodic` (container).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-27-webui-backup-panel-design.md`. Read it before starting; the sections below name which part governs each task.
- **Python 3 standard library only.** No new dependencies, no new image packages.
- **The unprivileged web process must never write into `/opt/palworld/backups`.** That directory is root-owned 0755 deliberately — it closed a symlink-swap escalation. Uploads go to `/var/lib/palworld/uploads` (0700, web-owned) and root promotes them. If a task seems to need the web process writing to the backups directory, stop and escalate.
- **`palwarden-jobd` must never trust the queue.** It re-validates every action name and parameter itself.
- **No parameter ever reaches a shell.** Fixed argv lists with typed, validated slots. No `shell=True`, no string interpolation into a command.
- **Operate on descriptors, not paths.** This repo has fixed six instances of "validate a path, then act on the path". Every open of an operator-influenced path uses `O_NOFOLLOW`, non-regular files are refused, and ownership/mode changes use `fchown`/`fchmod` on the descriptor already held.
- **Import is round-trip only:** filename must match `^palworld-save-[0-9]{8}T[0-9]{6}Z\.tar\.gz$` and every archive member must resolve under `SaveGames/` or `Config/`.
- Mutating endpoints require Basic auth **plus** the token in `X-Palwarden-Token` **plus** the `Origin`/`Sec-Fetch-Site` check. Disruptive actions additionally require `"confirm": true`.
- Host-portable: every path an env override with a **bare-metal-preserving default**. Use `${VAR-default}` semantics so an explicit empty override is honoured.
- Service account from `PALWORLD_USER`/`PALWORLD_GROUP`, **never** a hardcoded `palworld` — that bug made snapshots root-owned in the container.
- Notifications stay optional: source the helper tolerantly and define a no-op fallback (`tests/unit/test_notify_optional.sh` enforces this).
- SPDX on new first-party files: `# SPDX-License-Identifier: AGPL-3.0-or-later`, `# SPDX-FileCopyrightText: 2026 Brian Grant`.
- **`webui/PalWorldSettingsEditor.html` must stay byte-identical** — vendored MIT, do not touch.
- UI: only the documented `--pw-*` tokens and `pw-*` classes. **No new class names**, no raw colour outside `:root` in any notation, no inline styles. Every server-supplied string via `textContent` — guards in `tests/unit/test_webui_jobs.sh` enforce all of this on both pages and must stay green.
- Every task ends green: `./tests/lint.sh` and `./tests/run.sh`.
- Commit messages end with a blank line then `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Mutation-check every refusal test.** Remove the check, confirm the test fails, restore. This repo has repeatedly shipped assertions that could not fail.

## Interfaces that already exist

`sbin/palwarden-jobd`:
- `validate_label(params, key="label") -> str`, `validate_text(params, key="text") -> str`, `validate_wait(params) -> int | None`, `validate_dry_run(params) -> bool`, `validate_message(params) -> str | None`, `validate_settings(params) -> dict[str,str]`, `require_confirm(params) -> None`.
- **`validate_backup(params) -> str` already exists and is for *config* backups** (`Engine.ini.<stamp>` in `PALWORLD_BACKUP_DIR`, used by `engine_rollback`). Do **not** overload it. Save archives get a separate validator.
- `ACTIONS: dict[str, dict]` — each entry `{"argv": callable|None, "disruptive": bool, "params": tuple[str, ...]}`. `"argv": None` marks a file-only action handled directly in `run_job` (see `engine_save`).
- `recognised_params(action) -> frozenset[str]`, `validate_params(action, params) -> tuple[dict|None, str|None]`, `build_commands(action, params) -> list[list[str]]`, `run_job(job) -> int`.
- `write_engine_env(settings: dict[str,str]) -> None` — the atomic validated-key/value file writer `backup_schedule_save` mirrors.
- `_read_nofollow_text(path) -> str | None`, `_AlreadyRead` — read helpers.

`sbin/palwarden-webui`:
- `check_basic`, `check_token`, `origin_ok`, `_authenticated()`, `_send_json(status, obj, extra_headers=...)`, `_send_json_safely`, `_reject(status, error, **extra)`, `_read_body()`, `READ_ENDPOINTS`, `_list_dir(path, limit=50)`, `allowed_roots()`, `CLIENT_GONE`, `MAX_BODY_BYTES = 65536`, `REQUEST_TIMEOUT = 10.0`, `JOBS_LIST_LIMIT = 200`, `SAVE_BACKUP_DIR`, `TOKEN_HEADER`.
- `do_GET` routes `/api/token` and `/api/jobs*` before the generic `READ_ENDPOINTS` lookup; `do_POST` handles `/api/jobs` only.

`sbin/palworld-backup` — creates `$PALWARDEN_SAVE_BACKUP_DIR/palworld-save-<stamp>.tar.gz` from `$PALWORLD_SAVED_DIR` (`SaveGames` + `Config`), prints the path on stdout. Unchanged by this plan.

## File Structure

| File | Responsibility |
|---|---|
| `lib/palwarden_archive.py` (create) | Shared archive rules: the name pattern, member validation, safe extraction. Imported by both new tools so the security rules have exactly one implementation. |
| `sbin/palworld-restore` (create) | Archive → world. `--import`, `--restore`. |
| `sbin/palworld-backups` (create) | The archive collection. `--delete`, `--prune`, `--if-due`, `--show-schedule`. |
| `sbin/palwarden-jobd` (modify) | Four new actions + their validators. |
| `sbin/palwarden-webui` (modify) | Upload, download, schedule-read endpoints. |
| `webui/backups.html` (create) | The Backups tab. |
| `webui/palwarden.html`, `webui/EngineIniPerformanceEditor.html` (modify) | Add the fourth nav tab. |
| `systemd/palworld-backup-auto.{service,timer}` (create) | Bare-metal tick. |
| `docker/s6-rc.d/backup-auto/{type,run,timeout-kill}` (create) | Container tick. |
| `install.sh`, `docker/entrypoint.sh`, `docker/Dockerfile` (modify) | Staging dir, schedule file, service wiring. |
| `docs/tools.md`, `docs/architecture.md`, `docs/palworld-service-runbook.md`, `README.md` (modify) | Operator docs. |

**Why a shared `lib/palwarden_archive.py`:** the name pattern and member rules are the security boundary, and both tools plus their tests need them. Two copies would drift, and this repo already learned that lesson with `lib/palwarden_jobs.py`.

---

### Task 1: Shared archive rules

**Files:**
- Create: `lib/palwarden_archive.py`
- Test: `tests/unit/test_archive_rules.sh`

**Interfaces produced:**
```python
ARCHIVE_RE                                  # ^palworld-save-[0-9]{8}T[0-9]{6}Z\.tar\.gz$
MAX_MEMBERS = 200000                        # PALWARDEN_ARCHIVE_MAX_MEMBERS
MAX_UNCOMPRESSED_BYTES = 20 * 1024**3       # PALWARDEN_ARCHIVE_MAX_BYTES
ALLOWED_TOPLEVEL = ("SaveGames", "Config")

class ArchiveError(Exception): ...

def valid_archive_name(name: str) -> bool
def open_archive_fd(path) -> int             # O_RDONLY|O_NOFOLLOW|O_NONBLOCK, S_ISREG or ArchiveError
def validate_archive(path) -> dict           # {"members": int, "bytes": int}; raises ArchiveError
def extract_archive(path, dest_dir) -> dict  # validate, then extract with filter="data"
```

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_archive_rules.sh`:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# These rules are the security boundary for import: root unpacks whatever the
# operator uploads. The name check is the primary control (round-trip only), and
# the member rules are defence in depth. Every refusal below is mutation-checked
# in the task's steps, because a refusal test that cannot fail is worse than none.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../lib/assert.sh"
LIB="$DIR/../../lib"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
print('ok')")"
assert_eq "$out" "ok" "a real palworld-backup-shaped archive validates"

# --- hostile members are refused ------------------------------------------
# Each archive is built with python tarfile so the member name is exactly what we
# intend, which `tar` would normalise away.
build_hostile() {  # build_hostile <out> <python-body>
  PYTHONPATH="$LIB" python3 - "$1" <<PYEOF
import sys, tarfile, io
tf = tarfile.open(sys.argv[1], "w:gz")
$2
tf.close()
PYEOF
}

build_hostile "$WORK/traverse.tar.gz" '
info = tarfile.TarInfo("../escaped.sav"); info.size = 0
tf.addfile(info, io.BytesIO(b""))'
build_hostile "$WORK/absolute.tar.gz" '
info = tarfile.TarInfo("/etc/shadow"); info.size = 0
tf.addfile(info, io.BytesIO(b""))'
build_hostile "$WORK/symlink.tar.gz" '
info = tarfile.TarInfo("SaveGames/link"); info.type = tarfile.SYMTYPE
info.linkname = "/etc/shadow"; tf.addfile(info)'
build_hostile "$WORK/device.tar.gz" '
info = tarfile.TarInfo("SaveGames/dev"); info.type = tarfile.CHRTYPE
info.devmajor = 1; info.devminor = 3; tf.addfile(info)'
build_hostile "$WORK/outside.tar.gz" '
info = tarfile.TarInfo("Elsewhere/thing.sav"); info.size = 0
tf.addfile(info, io.BytesIO(b""))'

for kind in traverse absolute symlink device outside; do
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
except a.ArchiveError:
    print('refused')"; echo "rc=$?")"
assert_contains "$out" "refused" "refuses a FIFO promptly instead of blocking forever"
assert_not_contains "$out" "rc=124" "did not hang on the FIFO"

# --- extraction writes nothing outside dest -------------------------------
mkdir -p "$WORK/dest"
out="$(py "
import palwarden_archive as a
info = a.extract_archive('$WORK/good.tar.gz', '$WORK/dest')
print('ok' if info['members'] > 0 else 'bad')")"
assert_eq "$out" "ok" "a good archive extracts"
assert_rc 0 test -f "$WORK/dest/SaveGames/abc/Level.sav" "extraction produced the save"

mkdir -p "$WORK/dest2"
out="$(py "
import palwarden_archive as a
try:
    a.extract_archive('$WORK/traverse.tar.gz', '$WORK/dest2'); print('ACCEPTED')
except a.ArchiveError:
    print('refused')")"
assert_eq "$out" "refused" "extraction refuses a traversing member"
assert_rc 1 test -e "$WORK/escaped.sav" "nothing was written outside dest"

assert_report
```

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/unit/test_archive_rules.sh
bash tests/unit/test_archive_rules.sh
```
Expected: FAIL — `ModuleNotFoundError: No module named 'palwarden_archive'`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/palwarden_archive.py`. Requirements:

- Module docstring explaining *why*: root unpacks operator-supplied bytes, so the name check (round-trip contract) and the member rules (defence in depth) live here once rather than in each tool.
- `ARCHIVE_RE = re.compile(r"^palworld-save-[0-9]{8}T[0-9]{6}Z\.tar\.gz$")`; `valid_archive_name` uses `fullmatch` and returns `False` for a non-`str`.
- `open_archive_fd(path) -> int`: `os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)`; `os.fstat` and raise `ArchiveError` unless `stat.S_ISREG`. `O_NONBLOCK` is what stops a planted FIFO blocking forever *inside* the open — the `S_ISREG` check alone cannot, because it never runs. Clear `O_NONBLOCK` with `fcntl` after the check, or document why leaving it is safe on a regular file.
- `validate_archive(path, max_members=MAX_MEMBERS, max_bytes=MAX_UNCOMPRESSED_BYTES) -> dict`: open via `open_archive_fd`, `tarfile.open(fileobj=os.fdopen(fd,'rb'), mode='r:gz')`, iterate members and for each require: `member.isreg() or member.isdir()` (anything else — symlink, hardlink, device, FIFO — is refused by name); `not member.name.startswith('/')`; no `..` component; the first path component is in `ALLOWED_TOPLEVEL`. Accumulate count and size, raising on either cap. Raise `ArchiveError` with a message naming the offending member. Convert `tarfile.TarError`/`OSError`/`EOFError` into `ArchiveError` so a truncated upload is a clean refusal, not a traceback.
- `extract_archive(path, dest_dir) -> dict`: call `validate_archive` first, then extract with `tf.extractall(dest_dir, filter="data")`. `filter="data"` is the kernel-of-last-resort here; our own checks are what the tests pin. If `filter` raises `TypeError` (a Python without it), raise `ArchiveError` rather than silently extracting unfiltered.
- Env overrides for both caps.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_archive_rules.sh && ./tests/lint.sh && ./tests/run.sh
```

- [ ] **Step 5: Mutation-check every refusal**

For each of: the `..` check, the absolute-path check, the member-type check, the top-level check, the member cap, the byte cap, `S_ISREG`, `O_NONBLOCK`, and `filter="data"` — remove it, run the suite, confirm a FAIL, restore, confirm green. Record the failure counts.

- [ ] **Step 6: Commit**

```bash
git add lib/palwarden_archive.py tests/unit/test_archive_rules.sh
git commit -m "Add the shared archive rules for backup import

Root unpacks whatever the operator uploads, so the round-trip name contract and
the member rules live in one module imported by both new tools rather than copied
into each. Every refusal is mutation-checked: a planted FIFO is refused promptly
rather than blocking the open forever, and a traversing member is refused before
extraction writes anything."
```

---

### Task 2: `palworld-restore --import`

**Files:**
- Create: `sbin/palworld-restore`
- Test: `tests/unit/test_restore_import.sh`

**Interfaces:**
- Consumes: `lib/palwarden_archive.py` (Task 1) — `valid_archive_name`, `validate_archive`, `ArchiveError`.
- Produces: CLI `palworld-restore --import <staged-name>`; env `PALWARDEN_UPLOAD_DIR` (default `/var/lib/palworld/uploads`), `PALWARDEN_SAVE_BACKUP_DIR` (default `/opt/palworld/backups`).

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_restore_import.sh` asserting:
- A staged archive with a valid name and valid members is **moved** into the backups dir, root-readable 0644, and removed from staging.
- **The authoritative validation is the one on the promoted copy.** Simulate the in-place rewrite: make the staged file pass validation, then have the copy step observe different bytes (e.g. a stub or a `pwrite` between the passes), and assert the promotion is still refused and no archive appears in the backups dir. If that is impractical to simulate directly, assert the *ordering* instead — that validation runs against a path inside the backups dir, not the staging dir — and say in the report which you did and why.
- A refused promotion leaves **no** temp file in the backups dir.
- An invalid name is refused **before** any file is touched: staging file still present, backups dir unchanged.
- A hostile archive (reuse Task 1's traversing tarball, renamed to a valid name) is refused and **left in staging** for inspection, with the reason on stderr.
- A staged name containing `/` or `\` is refused.
- A symlink in the staging dir under a valid name is refused (`is_symlink`, not a following check).
- Promotion refuses to overwrite an existing archive of the same name, and the existing file's bytes are unchanged.
- Exit status is non-zero on every refusal.

Use the `py`/`build_hostile` fixture shape from Task 1 and `assert_report` at the end.

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/unit/test_restore_import.sh
bash tests/unit/test_restore_import.sh
```
Expected: FAIL — `can't open file '.../sbin/palworld-restore'`.

- [ ] **Step 3: Write minimal implementation**

Create `sbin/palworld-restore` (Python, `argparse`). For this task implement only `--import`:

**Order matters here, and it is not the obvious order.** Validating the staged file
and then copying it does **not** guarantee the promoted bytes are the validated
bytes: the web process *owns* the staging file, and holding a descriptor stops a
name swap but not a write to the inode you are holding (`O_WRONLY` without
`O_TRUNC`, or `pwrite`). So **promote first, then validate the promotion**, where
the copy sits in a directory the web process cannot write:

1. Reject a `staged` value containing a path separator or failing
   `valid_archive_name`, before touching the filesystem.
2. Resolve inside `PALWARDEN_UPLOAD_DIR`; refuse if `Path.is_symlink()`; require a
   regular file (`open_archive_fd`). Note `O_NOFOLLOW` does **not** stop the web
   user hardlinking a file it can read into staging, so staging content is fully
   untrusted even when the name looks right — which this ordering handles.
3. **Free-space check** before copying (`os.statvfs` on the backups filesystem). A
   web process that can fill that volume by uploading is a denial of service
   against `palworld-backup` itself.
4. **Advisory pre-validate** via `validate_archive` on the staged fd — only to give
   a good error message and to avoid copying obvious junk. Treat the result as
   advisory; it is not the authority.
5. **Copy** to a temp name in `PALWARDEN_SAVE_BACKUP_DIR`, created
   `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW` mode 0644, with `shutil.copyfileobj` from
   the descriptor from step 2 — never `shutil.copy(path, ...)`, which re-opens by
   name. Bound the copy by a compressed-size cap and abort if exceeded.
6. **Validate the temp file in the backups directory.** This is the authoritative
   check: that file is unwritable by the web process, so validated == persisted,
   unconditionally — no window and no reasoning about descriptor lifetimes. On
   refusal, `unlink` the temp, leave the staged file for inspection, exit non-zero.
7. **Rename** the temp to the final `palworld-save-<stamp>.tar.gz`, refusing if that
   name already exists. Build the destination name yourself from the
   `valid_archive_name`-checked basename — never join anything client-supplied. A
   half-copied or refused archive is therefore never visible to `/api/backups` or
   to `--restore`.
8. Unlink the staged file on success. Print the promoted path on stdout.

This makes `--restore`'s own re-validation a genuine *second independent*
guarantee rather than the only real one.

Add `sys.path` entries for `/usr/local/lib` and the repo's `lib/` exactly as `palwarden-jobd` does, so the module resolves in both installed and dev layouts.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_restore_import.sh && ./tests/lint.sh && ./tests/run.sh
```

- [ ] **Step 5: Mutation-check** the name check, the symlink refusal, and `O_EXCL`. Confirm each removal fails the suite; restore.

- [ ] **Step 6: Commit**

```bash
git add sbin/palworld-restore tests/unit/test_restore_import.sh
git commit -m "Promote a staged upload into the backups directory

The web process stages uploads in a directory it owns and root promotes them, so
the root-owned backups directory keeps the ownership that closed the symlink-swap
escalation. A refused archive stays in staging with the reason named, so a partial
or corrupt upload can be retried rather than silently vanishing."
```

---

### Task 3: `palworld-restore --restore`

**Files:**
- Modify: `sbin/palworld-restore`
- Test: `tests/unit/test_restore_apply.sh`

**Interfaces:**
- Consumes: Task 1's `extract_archive`; `palworld-backup`, `palworld-graceful-stop`, and the server start path, all located under `PALWARDEN_SBIN_DIR` (default `/usr/local/sbin`) so tests can stub them.
- Produces: CLI `palworld-restore --restore <backup-name> [--wait N]`.

Spec section: `### --restore <backup-name>`.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_restore_apply.sh` with stub tools that log their argv, asserting:
- **Happy path:** safety backup runs, stop runs, the world is replaced with the archive's contents, chown uses `PALWORLD_USER`/`PALWORLD_GROUP` from the env, the server starts, and **the replaced tree is deleted**.
- **Invalid archive aborts before stopping:** the stop stub's log is empty and the live tree is untouched.
- **Fresh install (no `Pal/Saved`):** succeeds, and stdout records that the safety backup was skipped.
- **Already stopped:** a stop stub exiting non-zero *because nothing was running* is treated as success — distinguish "already stopped" from a real stop failure and assert a real failure still aborts.
- **Startup failure keeps the replaced tree** and prints its path plus the safety archive's name.
- **Extraction failure leaves the original tree intact** — extract-then-swap, never extract over the live tree.
- Ownership asserted with a **secondary group** so a non-root chown is observable (the primary group is what files get at creation, so asserting on it would pass either way). Skip with a printed note when the user has only one group.

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/unit/test_restore_apply.sh
bash tests/unit/test_restore_apply.sh
```
Expected: FAIL — `--restore` is not a recognised argument.

- [ ] **Step 3: Write minimal implementation**

Add `--restore` to `sbin/palworld-restore`, stopping at the first failure:

1. Validate the named archive in `PALWARDEN_SAVE_BACKUP_DIR` (name + members). Nothing is stopped or replaced until this passes.
2. Safety backup, **conditional**: if the saved dir exists and is non-empty, run `palworld-backup` and record the filename it prints. Otherwise print that it was skipped and continue.
3. `palworld-graceful-stop [--wait N]`. Treat "already stopped" as success — detect it rather than ignoring all failures, so a genuine stop failure still aborts. Print which case occurred.
4. `extract_archive` into `<saved>.restore-<stamp>` **beside** the target, then `os.rename` the existing tree to `<saved>.replaced-<stamp>` and the new tree into place.
5. `chown -R` the restored tree to the configured account, warning non-fatally on an unresolvable account (never a hardcoded name).
6. Start the server and confirm readiness using the same check `palworld-graceful-restart` performs. Read that script and reuse its mechanism rather than inventing a second definition of "up".
7. On confirmed startup, delete `<saved>.replaced-<stamp>`. On failure, keep it and print its path **and** the safety archive name.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_restore_apply.sh && ./tests/lint.sh && ./tests/run.sh
```

- [ ] **Step 5: Mutation-check** the abort-before-stop ordering, the conditional safety backup, and the conditional deletion of the replaced tree (make startup fail and assert the tree survives).

- [ ] **Step 6: Commit**

```bash
git add sbin/palworld-restore tests/unit/test_restore_apply.sh
git commit -m "Restore a world save, extract-then-swap

Validation happens before anything is stopped, so a corrupt archive never costs a
running server. Extraction lands beside the target and swaps atomically, so a
partial extraction cannot leave a half-replaced world. The displaced tree is the
fastest undo available until the restored server is confirmed up, and is deleted
only then — kept precisely when startup fails, which is when it is needed."
```

---

### Task 4: `palworld-backups` — delete, prune, schedule

**Files:**
- Create: `sbin/palworld-backups`
- Test: `tests/unit/test_backups_manage.sh`

**Interfaces:**
- Consumes: Task 1's `valid_archive_name`; `palworld-backup` under `PALWARDEN_SBIN_DIR`.
- Produces: CLI `--delete <name>`, `--prune`, `--if-due`, `--show-schedule`; `read_schedule() -> dict`; env `PALWORLD_BACKUP_SCHEDULE` (default `/etc/palworld/backup.env`).

Spec sections: `## Deletion and retention`, `## Scheduled backups`.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_backups_manage.sh` asserting:
- `--delete` removes exactly the named archive and nothing else.
- `--delete` refuses: a name failing the pattern, a name with separators, a symlink under a valid name, a name that does not exist. Nothing deleted in any case.
- `--delete` **has no floor** — deleting the only archive succeeds (the operator confirmed three times in the UI).
- `--prune` deletes archives older than `BACKUP_RETENTION_DAYS`, keeps the newest `BACKUP_KEEP_MIN` regardless of age, and **never deletes the last remaining archive** even with `BACKUP_RETENTION_DAYS=1` and `BACKUP_KEEP_MIN=1`.
- `--prune` does not delete by count: many archives inside the retention window all survive.
- `--if-due` as pure logic: not due before the interval elapses; due after; due when no archive exists; a no-op when `BACKUP_ENABLED=false`. Control archive mtimes rather than waiting real hours.
- `--show-schedule` prints the effective values as JSON, including defaults when the file is absent.

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/unit/test_backups_manage.sh
bash tests/unit/test_backups_manage.sh
```
Expected: FAIL — `can't open file '.../sbin/palworld-backups'`.

- [ ] **Step 3: Write minimal implementation**

Create `sbin/palworld-backups` (Python, `argparse`, mutually-exclusive mode group so `--help` exits 0 and an unknown flag exits non-zero):

- `read_schedule()`: parse `PALWORLD_BACKUP_SCHEDULE` if present, apply defaults `BACKUP_ENABLED=true`, `BACKUP_INTERVAL_HOURS=24`, `BACKUP_RETENTION_DAYS=14`, `BACKUP_KEEP_MIN=3`, clamp to the spec's ranges (1–720, 1–3650, 1–100), warn on an out-of-range or unparseable value and fall back to the default rather than crashing — a typo in the file must not take out the scheduled backup.
- `--delete <name>`: validate the name, refuse a symlink, require a regular file inside the backups dir, unlink. No floor.
- `--prune`: sort archives newest-first by name (the stamp sorts lexically); keep the first `BACKUP_KEEP_MIN`; from the rest delete those older than `BACKUP_RETENTION_DAYS` by mtime; **never** let the directory reach zero. Print each deletion.
- `--if-due`: if `BACKUP_ENABLED` is false, print that and exit 0. Otherwise find the newest archive; if none, or its age exceeds `BACKUP_INTERVAL_HOURS`, exec `palworld-backup`. Put the due decision in a small pure function so the test can drive it directly.
- `--show-schedule`: print `read_schedule()` as JSON.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_backups_manage.sh && ./tests/lint.sh && ./tests/run.sh
```

- [ ] **Step 5: Mutation-check** the name validation, the symlink refusal, the never-empty guard, and the `BACKUP_KEEP_MIN` floor.

- [ ] **Step 6: Commit**

```bash
git add sbin/palworld-backups tests/unit/test_backups_manage.sh
git commit -m "Manage the backup collection: delete, prune, and schedule

Retention combines age with a minimum-kept floor, because age alone leaves a host
that was powered off for a month with nothing, and prune never empties the
directory whatever the settings say. Explicit deletion has no floor on purpose: an
operator who passed three confirmations may delete their only archive.

The due decision reads a config file each tick rather than living in a unit, so one
implementation serves systemd and s6 and the schedule can be changed without
rewriting units."
```

---

### Task 5: The four `jobd` actions

**Files:**
- Modify: `sbin/palwarden-jobd`
- Test: `tests/unit/test_jobd.sh`

**Interfaces:**
- Consumes: Tasks 2–4's CLIs.
- Produces: actions `backup_import`, `backup_restore`, `backup_delete`, `backup_schedule_save`; validators `validate_staged(params) -> str`, `validate_save_archive(params) -> str`, `validate_schedule(params) -> dict[str,str]`; `write_backup_schedule(settings) -> None`.

- [ ] **Step 1: Write the failing test**

Extend `tests/unit/test_jobd.sh` asserting:
- `backup_import` with a valid `staged` runs `palworld-restore --import -- <name>`; the argv is exact.
- `backup_restore` requires `confirm: true` (refused without), and with it runs `palworld-restore --restore -- <name>`; `wait` forwards as `--wait` when present and the flag is **absent** when omitted.
- `backup_delete` requires `confirm: true` and runs `palworld-backups --delete -- <name>`.
- Hostile values for `staged`/`backup` (separators, traversal, a name off-pattern, a shell metacharacter) are refused and **never reach argv** — assert the argv log is empty.
- `backup_schedule_save` writes the four keys; an unknown key is refused **by name**; each key is refused outside its range; the file is re-read to confirm it parses.
- **`validate_backup` still works for `engine_rollback`** — the new save-archive validator did not overload it. Assert both an `Engine.ini.<stamp>` name accepted for `engine_rollback` and a `palworld-save-*` name refused for it.
- A `--` terminator precedes every positional built from a parameter.

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/unit/test_jobd.sh
```
Expected: FAIL — the new actions are not on the allowlist.

- [ ] **Step 3: Write minimal implementation**

In `sbin/palwarden-jobd`:
- `validate_staged` / `validate_save_archive`: reject separators, require `palwarden_archive.valid_archive_name`, then require the file to exist in `PALWARDEN_UPLOAD_DIR` / `PALWARDEN_SAVE_BACKUP_DIR`, refusing a symlink. **Do not modify `validate_backup`** — it is `engine_rollback`'s config-backup validator and overloading it would silently widen what a rollback accepts.
- `validate_schedule`: like `validate_settings` but over the four schedule keys with the spec's ranges; bool for `BACKUP_ENABLED`; reject unknown keys by name; store normalised strings.
- `write_backup_schedule`: mirror `write_engine_env` — unique temp name, `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`, `fchmod(0o644)`, atomic replace, read back through an `O_NOFOLLOW` descriptor to confirm it parses. A **replace**, not a merge: the form always posts all four keys, and unlike `engine.env` there is no other writer whose values could be dropped. Say that in a comment.
- `ACTIONS` entries: `backup_import` file-only (`disruptive: False`, params `("staged",)`); `backup_restore` (`disruptive: True`, params `("backup", "wait", "confirm")`); `backup_delete` (`disruptive: True`, params `("backup", "confirm")`); `backup_schedule_save` (`"argv": None`, `disruptive: False`, params `("settings",)`).
- Extend `run_job`'s file-only branch to handle `backup_schedule_save` alongside `engine_save`.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_jobd.sh && ./tests/lint.sh && ./tests/run.sh
```

- [ ] **Step 5: Mutation-check** the `confirm` gates on both disruptive actions, the unknown-key refusal, and one hostile-name refusal.

- [ ] **Step 6: Commit**

```bash
git add sbin/palwarden-jobd tests/unit/test_jobd.sh
git commit -m "Add the backup import, restore, delete and schedule actions

Save archives get their own validator rather than overloading validate_backup,
which is engine_rollback's config-backup check — widening it would have silently
changed what a rollback accepts. Delete and restore are both classed disruptive:
the classification gates irreversible actions, and deleting the archive that would
have recovered the world is the least reversible thing here."
```

---

### Task 6: Upload, download and schedule endpoints

**Files:**
- Modify: `sbin/palwarden-webui`
- Test: `tests/unit/test_webui_backups.sh`

**Interfaces produced:**
- `POST /api/backups/upload`, `GET /api/backups/<name>/download`, `GET /api/backup-schedule`.
- `MAX_UPLOAD_BYTES` (`PALWARDEN_MAX_UPLOAD_BYTES`, default 2 GiB), `UPLOAD_TIMEOUT` (`PALWARDEN_UPLOAD_TIMEOUT`, default 600.0), `UPLOAD_DIR` (`PALWARDEN_UPLOAD_DIR`).

Spec sections: `### Upload is a raw body, not multipart`, `### Two existing constants must not apply to this path`, `### Download is a dedicated endpoint`.

- [ ] **Step 1: Write the failing test**

Create `tests/unit/test_webui_backups.sh`, modelled on `tests/unit/test_webui_jobs.sh`'s fixture, asserting:
- **Upload:** no token → 403; cross-site → 403; no auth → 401; a bad `X-Palwarden-Filename` → 400 **with no file created** in staging; `Content-Length` over the cap → 413 with no file created; a good upload → 202/200 and the staged bytes match exactly; a body shorter than `Content-Length` leaves **no** staged file; two uploads of the same name do not clobber (unique temp, then the promotion step owns collisions).
- **The 64 KiB job cap did not leak:** a `POST /api/jobs` body over `MAX_BODY_BYTES` is still refused, and an upload well over 64 KiB still succeeds.
- **Download:** no auth → 401; a crafted name (`../../etc/passwd`, url-encoded traversal, `%00`, off-pattern) → 404 with no traceback; a valid name → 200, bytes identical to the file, `Content-Disposition: attachment`, `Cache-Control: no-store`; a symlink planted in the backups dir under a valid name → 404.
- **Schedule:** `GET /api/backup-schedule` needs Basic (401 without), returns `{"ok": true, "data": {...}}` with the four keys.
- **The server is still serving** after every rejection — assert a following `GET` succeeds.
- The token never appears in the server log.

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/unit/test_webui_backups.sh
bash tests/unit/test_webui_backups.sh
```
Expected: FAIL — the endpoints 404.

- [ ] **Step 3: Write minimal implementation**

In `sbin/palwarden-webui`:
- **Upload** in `do_POST`, routed before the `/api/jobs` branch. Order: `_authenticated()` → `check_token` → `origin_ok` → validate `X-Palwarden-Filename` → `Content-Length` sanity (ASCII digits only, ≤ `MAX_UPLOAD_BYTES`) → `os.statvfs` free-space check → stream. Set `self.connection.settimeout(UPLOAD_TIMEOUT)` for this request only, and restore it after; comment that `REQUEST_TIMEOUT` is correct for every other path and would abort a real upload here. Stream in 1 MiB chunks to a unique temp name opened `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW` mode 0600, counting bytes and aborting if the stream exceeds the cap. `os.replace` into the validated name on success; `unlink` the temp on any failure, including a short read. Every rejection path sets `close_connection = True` like `_reject` does.
- **Download** in `do_GET`, before the generic `READ_ENDPOINTS` lookup: match `/api/backups/<name>/download`, validate the name, `open_archive_fd`-style open (`O_RDONLY|O_NOFOLLOW`, `S_ISREG`), then `send_response(200)` with `Content-Type: application/gzip`, `Content-Length` from `fstat`, `Content-Disposition: attachment; filename="<name>"`, `Cache-Control: no-store`, and copy in chunks. Wrap in `CLIENT_GONE` handling — a cancelled browser download is routine, not an error.
- **Schedule** as a normal `READ_ENDPOINTS` entry backed by `palworld-backups --show-schedule` via the existing `run_tool_json`.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_webui_backups.sh && ./tests/lint.sh && ./tests/run.sh
```

- [ ] **Step 5: Mutation-check** the token gate on upload, the filename validation, the cap, and the download name validation.

- [ ] **Step 6: Commit**

```bash
git add sbin/palwarden-webui tests/unit/test_webui_backups.sh
git commit -m "Add backup upload, download and schedule endpoints

Uploads are a raw body, not multipart: Python 3.13 removed the cgi module, so
there is no stdlib multipart parser and hand-writing one inside the unprivileged
HTTP process is exactly the parser this design should not contain.

Two existing constants stay put and are overridden locally for this path only: the
64 KiB body cap is right for a job body, and the 10-second request timeout would
abort any real upload mid-flight. A test pins that neither leaked into the other."
```

---

### Task 7: The Backups page

**Files:**
- Create: `webui/backups.html`
- Modify: `webui/palwarden.html`, `webui/EngineIniPerformanceEditor.html` (nav only)
- Test: extend `tests/unit/test_webui_backups.sh`

Spec section: `## UI`.

- [ ] **Step 1: Write the failing test**

Extend the suite to assert, preferring **node-executed** checks over greps (the repo's pattern: extract a function with `awk`, run it against fixtures; skip with a printed note if node is absent, but **fail** when `$CI` is set):
- The page contains the four nav tabs and all three sibling pages gained the Backups tab.
- Delete is a **three-step** flow: extract the confirm sequence and assert that it sends nothing until the second dialog is confirmed, that `confirm: true` is on the payload, and that cancelling at either step sends nothing.
- Neither dialog's default-focused control is the destructive one.
- The final dialog's text names the archive **and** says it is the only one when the list has length 1.
- A fixture job output containing `<img src=x onerror=alert(1)>` renders as literal text.
- Payloads carry only the recognised params per action.
- The schedule form posts all four keys and shows a worker refusal verbatim.
- The existing guards stay green: no HTML sinks in any page, no new class names, no raw colour outside `:root`, `PalWorldSettingsEditor.html` byte-identical.

- [ ] **Step 2: Run test to verify it fails**

```bash
bash tests/unit/test_webui_backups.sh
```
Expected: FAIL — `webui/backups.html` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `webui/backups.html` following `webui/EngineIniPerformanceEditor.html`'s structure and its token handling (`GET /api/token` → `sessionStorage`, prompt only as fallback). Add the `Backups` tab to all three sibling pages. Build: the archive list card with Download/Restore/Delete per row; Create backup; the upload control (`fetch` with the `File` as body, `X-Palwarden-Filename`, progress in `pw-log`); the three-step delete flow with Cancel default-focused and Esc cancelling; the schedule card from `GET /api/backup-schedule` saving via `backup_schedule_save`; `pw-empty` "No backups yet". Poll `GET /api/jobs` while a job is unfinished, exactly as the Engine editor does. `textContent` everywhere.

- [ ] **Step 4: Run test to verify it passes**

```bash
bash tests/unit/test_webui_backups.sh && ./tests/lint.sh && ./tests/run.sh
```

- [ ] **Step 5: Commit** with a message explaining why Cancel is default-focused in both dialogs.

---

### Task 8: Platform wiring and the full recovery loop

**Files:**
- Create: `systemd/palworld-backup-auto.service`, `systemd/palworld-backup-auto.timer`, `docker/s6-rc.d/backup-auto/{type,run,timeout-kill}`
- Modify: `install.sh`, `docker/entrypoint.sh`, `docker/Dockerfile`, `tests/integration/test_docker.sh`
- Modify docs: `docs/tools.md`, `docs/architecture.md`, `docs/palworld-service-runbook.md`, `README.md`

- [ ] **Step 1: Write the failing integration assertions**

Append to `tests/integration/test_docker.sh` the **full recovery loop**: create a backup through the API; download it; delete the archive via `backup_delete`; upload the downloaded bytes back; `backup_import`; `backup_restore`; assert the world returns. Plus: the staging dir is web-owned 0700; the backups dir is root-owned; `palwarden-jobd` runs as root and `palwarden-webui` unprivileged; the `backup-auto` service is present and runs as root; a scheduled tick with `BACKUP_ENABLED=false` creates nothing.

- [ ] **Step 2: Run and confirm the new assertions fail**

```bash
RUN_INTEGRATION=1 bash tests/integration/test_docker.sh
```

- [ ] **Step 3: Implement the wiring**

- Timer + unit, root, `Restart=on-failure`, no sandbox directive that blocks writes to `/opt/palworld/backups`, `/var/lib/palworld` or the game tree. Match `palwarden-jobd.service`'s hardening choices and its comment style. Read the sibling units first; note they use `network-online.target`.
- s6 `longrun` as root via `palwarden-run-periodic "${BACKUP_TICK_SECONDS:-900}" backup-auto palworld-backups --if-due --prune`, `timeout-kill` consistent with siblings. **Commit the `run` script mode 755** — a sibling shipped 644 and depended entirely on the Dockerfile's `chmod`.
- Entrypoint: create `/var/lib/palworld/uploads` (web user, 0700) as a **mount-point child only**, never a recursive chown of a volume; render `/etc/palworld/backup.env` from `BACKUP_*` env if absent; `enable_service backup-auto`. Note the existing limitation that `config-webui`/`jobd` are embedded-only and follow whatever pattern is already there.
- `install.sh`: create the staging dir service-account-owned 0700 and the schedule file; add both new units to what it installs; extend the existing `try-restart` block.
- Dockerfile: add the new `run` to the explicit `chmod +x` list; add the staging dir to `install -d`.
- Docs: `docs/tools.md` entries for both new tools and the three endpoints; the panel and its privilege split in `architecture.md`; runbook procedures for **recovering from a failed restore** (where the replaced tree and safety archive are) and for schedule/retention; README orientation.

- [ ] **Step 4: Verify**

```bash
./tests/lint.sh && ./tests/run.sh && RUN_INTEGRATION=1 ./tests/run.sh
```
Clean up containers and images afterwards. A `palwarden-review` container may exist — leave it alone.

- [ ] **Step 5: Commit** explaining the privilege split and the staging indirection.

---

## Self-Review

**Spec coverage.** Name/member rules and extraction hardening → Task 1. Import → Task 2. Restore, conditional safety backup, already-stopped tolerance, extract-then-swap, conditional deletion of the replaced tree → Task 3. Deletion, retention with floor, due logic, schedule reading → Task 4. The four actions and their validators → Task 5. Upload/download/schedule endpoints and the two constant overrides → Task 6. The page, three-step delete, schedule form → Task 7. Both platform services, the staging dir, docs, and the full recovery loop → Task 8.

**Placeholder scan.** No "TBD"/"add validation"/"handle errors" — each task names the specific checks and the specific test cases.

**Type consistency.** `valid_archive_name`, `validate_archive`, `extract_archive`, `ArchiveError`, `open_archive_fd` are defined in Task 1 and used under those names in Tasks 2, 3, 4 and 6. `validate_staged`/`validate_save_archive`/`validate_schedule`/`write_backup_schedule` are defined in Task 5 and used nowhere earlier. `PALWARDEN_UPLOAD_DIR`, `PALWARDEN_SAVE_BACKUP_DIR`, `PALWORLD_BACKUP_SCHEDULE` are spelled identically throughout. `ACTIONS` entries use the existing `{"argv", "disruptive", "params"}` shape.

**One trap flagged deliberately.** `validate_backup` already exists for *config* backups (`engine_rollback`). Task 5 adds a separate save-archive validator and asserts the old one still refuses a save-archive name, because overloading it would silently widen what a rollback accepts.
