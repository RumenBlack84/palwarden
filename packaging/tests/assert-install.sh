#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Post-install sanity assertions, run INSIDE a fresh distro container right
# after the native package was installed (see .github/workflows/release.yml).
# POSIX sh: it runs on ubuntu, fedora and arch base images alike. Containers
# have no booted systemd, so this asserts everything the postinstall does on
# such a host — and nothing it correctly skips (unit refresh, tmpfiles dirs
# when systemd-tmpfiles is absent).
set -eu

fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "  ok: $*"; }

# The service account: created by systemd-sysusers or the useradd fallback.
if getent passwd palworld >/dev/null; then ok "palworld user exists"; else fail "palworld user missing"; fi
if getent group palworld >/dev/null; then ok "palworld group exists"; else fail "palworld group missing"; fi

# Payload landed where the scripts expect each other.
for f in /usr/local/sbin/palworld-status /usr/local/sbin/palwarden-webui \
         /usr/local/sbin/palwarden-jobd /usr/local/sbin/palworld-graceful-restart \
         /usr/local/bin/palworld-config-parser /usr/local/lib/palworld-notify; do
  if [ -x "$f" ]; then ok "$f is executable"; else fail "$f missing or not executable"; fi
done
for f in /usr/lib/systemd/system/palworld.service \
         /usr/lib/systemd/system/palwarden-jobd.service \
         /usr/lib/sysusers.d/palwarden.conf /usr/lib/tmpfiles.d/palwarden.conf \
         /etc/palworld/engine.env /etc/palworld/backup.env \
         /etc/palworld/settings.env.example \
         /opt/palworld/tools/config-webui/palwarden.html; do
  if [ -f "$f" ]; then ok "$f present"; else fail "$f missing"; fi
done
if [ -L /opt/palworld/tools/config-webui/current ]; then
  ok "current symlink present"
else
  fail "current symlink missing"
fi

# postinstall generated credentials with the exact ownership the control
# plane's trust model needs (root-writable only, service-account-readable).
if [ -s /etc/palworld/webui.env ]; then
  ok "webui.env created and non-empty"
  perms=$(stat -c '%a %U %G' /etc/palworld/webui.env)
  if [ "$perms" = "640 root palworld" ]; then
    ok "webui.env is 640 root:palworld"
  else
    fail "webui.env perms are '$perms', expected '640 root palworld'"
  fi
else
  fail "webui.env missing or empty"
fi

# The runtime tree, only where the postinstall could actually create it.
if command -v systemd-tmpfiles >/dev/null 2>&1; then
  for d in /var/lib/palworld/jobs /var/lib/palworld/uploads /opt/palworld/restore-scratch; do
    if [ -d "$d" ]; then ok "$d created"; else fail "$d missing despite systemd-tmpfiles"; fi
  done
fi

# The two control-plane python tools must at least compile with the distro's
# python3 — this is what catches a syntax-vs-python-version regression that
# file-presence checks never would.
if python3 -m py_compile /usr/local/sbin/palwarden-webui /usr/local/sbin/palwarden-jobd \
     /usr/local/bin/palworld-config-parser; then
  ok "python tools compile under $(python3 --version)"
else
  fail "python tools failed to compile"
fi
# And the bash entry points must parse.
for f in /usr/local/sbin/palworld-graceful-restart /usr/local/sbin/palworld-update \
         /usr/local/sbin/palworld-backup; do
  if bash -n "$f"; then ok "$f parses"; else fail "$f has a bash syntax error"; fi
done

if [ "$fails" -gt 0 ]; then
  echo "assert-install: $fails assertion(s) failed" >&2
  exit 1
fi
echo "assert-install: all assertions passed"
