# Packaging (nfpm)

One manifest ([`nfpm.yaml`](nfpm.yaml)) builds native packages for the three
target families. `.deb` is the priority target (prod runs Ubuntu 24.04 LTS).

```sh
mkdir -p dist
VERSION=0.1.0 nfpm package -f packaging/nfpm.yaml -p deb       -t dist/
VERSION=0.1.0 nfpm package -f packaging/nfpm.yaml -p rpm       -t dist/
VERSION=0.1.0 nfpm package -f packaging/nfpm.yaml -p archlinux -t dist/
```

Run from the repo root (`src:` paths in the manifest are repo-relative).
`VERSION` must be set; in CI it derives from the tag (`${GITHUB_REF_NAME#v}`).

Releases are automated: pushing a `v*.*.*` tag runs
`.github/workflows/release.yml`, which gates on the full test suite, builds
all three packages plus the docker image (pushed to GHCR), install-tests each
package in a fresh container of its native distro
([`tests/assert-install.sh`](tests/assert-install.sh)), and only then cuts a
GitHub release with the packages attached.

Install on the target host with the native tool so dependencies resolve:

```sh
sudo apt install ./dist/palwarden_0.1.0_all.deb     # Ubuntu/Debian
sudo dnf install ./dist/palwarden-0.1.0-1.noarch.rpm
sudo pacman -U   ./dist/palwarden-0.1.0-1-any.pkg.tar.zst
```

## What the package does that install.sh did

| install.sh behaviour | package mechanism |
|---|---|
| copy scripts/units/webui | payload (`contents:` in nfpm.yaml) |
| never clobber `engine.env` / `backup.env` | `config|noreplace` (dpkg conffile / rpm `.rpmnew` / pacman `.pacnew`) |
| create `palworld` user if asked | `sysusers.d/palwarden.conf` via postinstall + every boot |
| `install -d` the runtime tree with the root-vs-service split | `tmpfiles.d/palwarden.conf` via postinstall + **re-enforced every boot** |
| `palwarden-webui --init-credentials` + perms | postinstall |
| daemon-reload / pair-enable jobd / try-restart | postinstall (same logic, same guards) |
| *(no uninstall existed)* | preremove stops+disables units; live data is left behind |

`install.sh` remains the fallback for non-deb/rpm/arch hosts and checkout-based
dev installs. If you change ownership/paths in one place, change the other:
`install.sh` §4c/§6 ↔ `tmpfiles.d/palwarden.conf`.

## Known deviations / caveats

- **Paths stay under `/usr/local`** because every script and unit hardcodes
  them. Fine for a self-distributed package; it would be rejected from the
  Debian archive proper (policy reserves `/usr/local` for the sysadmin).
  Moving to `/usr` is a separate refactor.
- **Units move to `/usr/lib/systemd/system`** (vendor tree) instead of
  install.sh's `/etc/systemd/system`. If a host was previously set up by
  install.sh, remove the old copies in `/etc` first — they would shadow the
  packaged ones: `rm /etc/systemd/system/palworld*.{service,timer}
  /etc/systemd/system/palwarden-jobd.service && systemctl daemon-reload`.
- **The `current` symlink** is part of the payload (dangling until the game
  server is installed under /opt/palworld/server — same as install.sh).
- **needrestart hooks** install even where needrestart isn't (harmless);
  `Recommends: needrestart` on deb.
- Package removal **stops the game server** (gracefully, SIGINT → world
  save). It never deletes saves, backups, telemetry, or the live `*.env`
  files.
