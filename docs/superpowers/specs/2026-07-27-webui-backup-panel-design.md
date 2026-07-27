# Web UI backup panel — design

**Date:** 2026-07-27
**Status:** approved, not yet implemented
**Goal:** make a world save recoverable from the browser after a total failure —
create a backup, download it off the host, and later push that file back and
restore it — without giving the browser-facing process privilege, and without
letting an uploaded archive escape the tree root unpacks it into.

## Background: what exists today

`sbin/palworld-backup` creates `/opt/palworld/backups/palworld-save-<stamp>.tar.gz`
(`stamp` = `date -u +%Y%m%dT%H%M%SZ`) containing `SaveGames` and `Config` from
`Pal/Saved`. It is reachable as `jobd`'s `backup` action and from a timer.

`GET /api/backups` lists that directory — `{"ok": true, "data": [{"name", "bytes",
"modified"}, …]}`.

**There is no restore path anywhere in the repo.** `palworld-engine-config
rollback` restores `Engine.ini` only; nothing restores a world save. There is no
download and no upload. So the panel needs one new tool, two new `jobd` actions,
two new HTTP endpoints, and a page.

`/opt/palworld/backups` is **root-owned 0755** deliberately: it was
service-account-owned until a review showed that let a less-privileged process
rename a directory root had just created and redirect root's writes and `chown`
through a symlink. That ownership is load-bearing and this design must not undo it.

## The use case that shapes the design

**Disaster recovery, not routine rollback.** The operator keeps backups off the
host, and after a total failure — rebuilt box, corrupted save, crashlooping
server — opens the web UI on a fresh install and pushes a saved archive back.

Three consequences, each of which would otherwise be designed wrong:

1. **Nothing may assume existing state.** `Pal/Saved` may not exist. The safety
   backup taken before a restore is therefore *conditional*: skip it with a
   recorded note when there is no save to preserve, never abort.
2. **Already-stopped is success.** The server is likely down or crashlooping. A
   restore that fails because it could not stop a stopped server fails exactly
   when it is needed.
3. **The panel must work with an empty backups list**, before anything local
   exists.

## Trust model for imports

**Round-trip only: archives this tool produced.** Import is not a migration
feature; it does not accept an arbitrary Palworld save from a Windows install or a
foreign layout. That is a deliberate scope decision, and it is the primary
security control — the shape check rejects hostile archives before the extractor's
hardening is ever load-bearing.

Accordingly an archive is accepted only if **both** hold:

* the filename matches `^palworld-save-[0-9]{8}T[0-9]{6}Z\.tar\.gz$` — exactly
  what `palworld-backup` writes; and
* every member resolves under `SaveGames/` or `Config/`.

Anything else is refused with the reason named. Arbitrary-layout migration, if it
is ever wanted, is a separate design with a separate threat model.

## Architecture

One rule drives the whole shape: **the unprivileged web process never writes into
the root-owned backups directory.** Giving it write access there would reintroduce
the exact symlink-swap hazard that root ownership closed. So an upload lands in a
staging area the web user owns, and root validates and promotes it.

| Step | Runs as | Writes to |
|---|---|---|
| Upload | web process (`palworld`/`steam`) | `/var/lib/palworld/uploads/` (0700, web-owned) |
| Validate + promote | **root** (`jobd` → `backup_import`) | `/opt/palworld/backups/` |
| Restore | **root** (`jobd` → `backup_restore` → `palworld-restore`) | `Pal/Saved` |
| Download | web process | reads root-owned 0755 backups directly |

The staging indirection is the one added moving part. It is worth it: it keeps the
privilege boundary exactly where the rest of the control plane already puts it —
the process that parses HTTP writes only into a directory it owns, and the process
with privilege re-validates everything it finds there.

### Paths

| Path | Owner | Env override | Purpose |
|---|---|---|---|
| `/opt/palworld/backups` | root 0755 | `PALWARDEN_SAVE_BACKUP_DIR` | Archives. Already exists. |
| `/var/lib/palworld/uploads` | web user 0700 | `PALWARDEN_UPLOAD_DIR` | Staging for in-flight uploads. **New.** |

`/var/lib/palworld/uploads` is created by `install.sh` and `docker/entrypoint.sh`
alongside the job queue, owned by the service account, mode 0700 — same treatment
and same reasoning as `/var/lib/palworld/jobs`.

## Transport decisions

### Upload is a raw body, not multipart

`POST /api/backups/upload`, `Content-Type: application/octet-stream`, the archive
as the entire request body, the intended filename in `X-Palwarden-Filename`.

**Python 3.13 removed the `cgi` module**, so the standard library has no
multipart/form-data parser. Hand-writing one inside the unprivileged HTTP process
is exactly the kind of parser this design should not contain. `fetch()` accepts a
`File` as its body directly, so a raw body costs the browser nothing.

Requirements:

* **Stream to disk in chunks.** Never buffer the archive in memory.
* Write to a unique temp name in the staging dir opened
  `O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`, mode 0600, then rename into place. Unlink
  the temp file on any failure so a partial upload leaves no debris.
* **Cap the size.** `PALWARDEN_MAX_UPLOAD_BYTES`, default **2 GiB**. Reject a
  `Content-Length` over the cap *before* reading a byte, and stop and delete if
  the stream exceeds it anyway.
* **Check free space before accepting** (`os.statvfs`), and refuse with a clear
  message rather than filling the disk. Filling `/var/lib/palworld` would also
  break the telemetry DB and the job queue.
* Validate `X-Palwarden-Filename` against the name pattern above **before**
  creating any file.
* Mutation rules apply in full: Basic auth **plus** `X-Palwarden-Token`, plus the
  `Origin`/`Sec-Fetch-Site` check. This is a mutation.

### Two existing constants must not apply to this path

Both would silently break uploads, and both are correct for their current callers:

* `MAX_BODY_BYTES = 65536` (64 KiB) — sized for a job body. The upload path uses
  `PALWARDEN_MAX_UPLOAD_BYTES` instead.
* `REQUEST_TIMEOUT = 10.0` — a 10-second socket timeout **aborts any real upload
  mid-flight**. The upload path needs its own, longer timeout, applied for the
  duration of that request only.

Neither existing value changes; the upload handler overrides both locally, and a
test pins that a job body over 64 KiB is still refused.

### Download is a dedicated endpoint, not `allowed_roots`

`GET /api/backups/<name>/download`. Adding the backups directory to static
serving would expose directory listings and bypass name validation.

* Validate `<name>` against the pattern; anything else is `404`, never a
  traversal or a traceback.
* Open `O_NOFOLLOW` and confirm `S_ISREG`, then stream in chunks.
* `Content-Type: application/gzip`, `Content-Length`, `Content-Disposition:
  attachment; filename="<name>"`, `Cache-Control: no-store`.
* Basic auth only — it is a read. No token.

## Actions

Added to `palwarden-jobd`'s allowlist, re-validated there as always.

*File-only:*

| Action | Command | Params |
|---|---|---|
| `backup` | `palworld-backup` | — (already exists) |
| `backup_import` | `palworld-restore --import <staged>` | `staged`: a filename (no separators) present in the staging dir and matching the name pattern |

*Disruptive (require `"confirm": true`):*

| Action | Command | Params |
|---|---|---|
| `backup_restore` | `palworld-restore --restore <backup>` | `backup`: matches the name pattern and exists in the backups dir; optional `wait` (0–1800), forwarded to the graceful stop as the player-warning window. Omitted → the stop tool's own default applies, per the convention already set by `graceful_restart`. |

`backup_import` is file-only because it touches no running service: it validates a
staged archive and moves it into the backups directory. `backup_restore` stops the
game server and replaces the world, so it is disruptive.

## `sbin/palworld-restore` (new)

One first-party tool, two subcommands, so validation lives in exactly one place.

### `--import <staged-name>`

1. Resolve the staged file inside the staging dir — reject separators, refuse a
   symlink, require a regular file, open `O_NOFOLLOW`.
2. Validate the archive **without extracting**: it must be a readable gzip tar
   whose every member passes the member rules below.
3. Move it into the backups directory under its validated name, root-owned 0644,
   refusing to overwrite an existing archive of the same name (`O_EXCL`
   semantics).
4. Delete the staged file on success. On failure leave it and say why, so a
   partial upload can be retried or inspected.

### `--restore <backup-name>`

Stops at the first failure; a failed step never reaches the next.

1. **Validate** the archive as above. Nothing is stopped or replaced until it
   passes — a corrupt archive must not cost the operator a running server.
2. **Safety backup**, conditional: if `Pal/Saved` exists and is non-empty, invoke
   `palworld-backup` and record the resulting filename in the job output. If there
   is no save, record that it was skipped and continue.
3. **Graceful stop**, tolerating already-stopped. `palworld-graceful-stop
   [--wait]` warns players and saves; if the server is not running, that is
   success and is recorded as such.
4. **Extract into a temp directory beside the target**, then swap atomically.
   Never extract over the live tree: a partial extraction must not leave a
   half-replaced world. Concretely — extract to `Pal/Saved.restore-<stamp>`,
   rename the existing `Pal/Saved` to `Pal/Saved.replaced-<stamp>`, rename the new
   tree into place. Keep the replaced tree (the safety backup is an archive; this
   is a cheap second line) and say where it is.

   **The replaced tree is not pruned automatically** — it is a full copy of a world
   save, so repeated restores accumulate disk. The job output names the path and
   says it is the operator's to delete. Automatic pruning is out of scope (below),
   and silently deleting the previous world in a recovery tool would be the wrong
   default.
5. **Chown** the restored tree to `PALWORLD_USER`/`PALWORLD_GROUP`, resolved from
   the environment with bare-metal-preserving defaults — never a hardcoded
   `palworld`, which is the bug that made snapshots root-owned in the container.
6. **Start the server** and report.

## Extraction hardening

The shape check is the primary control; this is defence in depth, because an
archive that passes the name check is still operator-supplied bytes that **root**
unpacks.

* `tarfile` with **`filter='data'`** — available on the image's Python 3.13
  (verified). It rejects absolute paths, `..` traversal, links pointing outside
  the destination, and device/character/FIFO members, and strips setuid/setgid
  bits and ownership.
* **Every member must resolve under `SaveGames/` or `Config/`.** Checked
  independently of the filter, since it is the round-trip contract, not a
  generic safety rule.
* **Caps against a decompression bomb:** maximum member count and maximum total
  uncompressed bytes, both env-overridable. `filter='data'` does not bound size.
* The archive is opened `O_NOFOLLOW` and confirmed `S_ISREG` before `tarfile`
  sees it.
* Ownership and modes come from our `chown`, never from the archive.

## API summary

| Endpoint | Method | Auth | Purpose |
|---|---|---|---|
| `/api/backups` | GET | Basic | Existing listing |
| `/api/backups/<name>/download` | GET | Basic | Stream one archive |
| `/api/backups/upload` | POST | Basic + token + Origin | Stage an archive |

Status codes follow the existing scheme: `401` missing/bad Basic · `403`
missing/bad token or bad Origin · `400` validation failure (bad name, oversized,
no space) · `404` unknown archive · `413` body over the cap · `507` insufficient
free space · `500` internal. `/api/*` errors are JSON.

## UI

A fourth tab, **Backups**, beside Dashboard / Server settings / Engine.ini
performance, using only the documented component vocabulary.

* A `pw-card` listing archives — name, size, date — from `GET /api/backups`, each
  row with **Download** (a link to the download endpoint) and **Restore**
  (`pw-btn--danger`).
* **Create backup** — `pw-btn`, enqueues `backup`.
* **Import** — a file input plus an Upload button. Progress shown while streaming;
  on success the list refreshes and the archive appears as a normal row, which is
  the whole point of the two-step flow.
* **Restore** is behind a `pw-confirm` dialog that names what will happen: the
  server stops, the current world is archived first, and players are disconnected.
  It sends `confirm: true`.
* Job progress in a `pw-log` (`aria-live="polite"`), outcomes in a `pw-toast` —
  errors persist, successes auto-clear.
* `pw-empty` with "No backups yet" for the empty list — the fresh-install case.
* **Every server-supplied string via `textContent`.** A guard in
  `tests/unit/test_webui_jobs.sh` rejects HTML sinks on both pages and must stay
  green; the 403 body reflects the request `Origin`, and job output is
  attacker-influenceable.
* The token comes from `GET /api/token`, cached in `sessionStorage`, as on the
  Engine editor. No prompt.

## Error handling

* A refused upload deletes its temp file and names the reason.
* A refused import leaves the staged file in place for retry, and says so.
* A restore that fails after the swap reports **what state the tree is in** and
  where the replaced tree and the safety archive are. A partial recovery that
  cannot be diagnosed from the job output is the worst outcome in this design, so
  the message names paths, not just a failure.
* A missing tool (`FileNotFoundError`) is reported, never a traceback.
* Notifications stay optional (`palworld_notify` no-ops when absent).

## Testing

**Unit** (no docker, per repo convention):

* Name validation: the exact pattern accepted; separators, traversal, absolute
  paths, a wrong extension, a wrong stamp shape all refused.
* Archive validation, each with a crafted tarball: a member with `../` escaping;
  an absolute member path; a symlink member pointing outside; a device member; a
  member outside `SaveGames/`/`Config/`; over the member cap; over the
  uncompressed-size cap. Each refused, and **nothing written outside the temp
  tree** — asserted, not assumed.
* A legitimate round-trip: `palworld-backup` output imports and restores cleanly.
* Restore on a **fresh install** with no `Pal/Saved`: succeeds, and the job output
  records that the safety backup was skipped.
* Restore with the server **already stopped**: succeeds, recorded as such.
* Restore aborts before stopping the server when the archive is invalid —
  asserted via a stub that records whether `graceful-stop` ran.
* Extraction failure leaves the original tree intact (swap-not-overwrite).
* Upload endpoint: no token → 403; over the cap → 413 without writing a file;
  bad filename → 400 before any file is created; a truncated body leaves no
  staged file; a job body over 64 KiB is *still* refused (the constants did not
  leak into each other).
* Download endpoint: unauthenticated → 401; unknown or crafted name → 404;
  correct headers; the bytes match the file.
* Ownership after restore comes from `PALWORLD_USER`/`PALWORLD_GROUP`, asserted
  with a secondary group so a non-root chown is observable.

**Integration** (docker): create a backup through the API, download it, delete the
archive, upload the downloaded bytes back, import, restore, and assert the world
returns — the full recovery loop, which is the feature's actual promise. Assert
`palwarden-jobd` runs as root and `palwarden-webui` unprivileged throughout, and
that the staging directory is web-owned 0700.

**Mutation-check the security assertions.** Every refusal test above must be shown
to fail against an implementation with that check removed. This repo has
repeatedly found assertions that could not fail; a refusal test that passes
against a missing check is worse than no test.

## Deliberately not in scope

* **Arbitrary-layout migration** — a foreign or Windows save. Separate threat
  model, separate design.
* **Scheduled/automatic pruning** of old backups. The panel lists and restores;
  retention is unchanged.
* **Deleting backups from the UI.** Nothing in the recovery story needs it, and it
  is the one destructive action with no undo.
* **Encryption or off-host upload.** Download gives the operator the bytes; where
  they keep them is their business.
