# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden all-in-one image: the Palworld dedicated server + management tooling
# in a single artifact. Behavior is selected at runtime by PALWARDEN_MODE
# (embedded = run the server here; external = manage a server elsewhere).
#
# Process model: s6-overlay is PID 1 (as root) and supervises the workloads,
# each of which drops to the unprivileged `steam` user from the base image.
#
# Base: cm2network/steamcmd provides SteamCMD, the 32-bit runtime libraries, and
# the `steam` user (uid/gid 1000). The :root tag starts as root.
#
# syntax=docker/dockerfile:1
FROM cm2network/steamcmd:root

ARG DEBIAN_FRONTEND=noninteractive
ARG S6_OVERLAY_VERSION=3.2.0.2
# Include matplotlib so FPS/health report graphs work in-container. Set to
# "false" at build time for a leaner image (reports then run text-only).
ARG WITH_GRAPHS=true

# Runtime dependencies for the tooling + supervisor.
#   python3         - REST client, telemetry, config helpers, web UI server
#   procps/iproute2 - pkill/ps/ss used by the scripts and stop handling
#   util-linux      - flock used by the watchdog
#   xz-utils        - extract the s6-overlay release tarballs
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        curl \
        ca-certificates \
        tar \
        gzip \
        xz-utils \
        procps \
        iproute2 \
        util-linux \
    && if [ "$WITH_GRAPHS" = "true" ]; then \
         apt-get install -y --no-install-recommends python3-matplotlib; \
       fi \
    && rm -rf /var/lib/apt/lists/*

# s6-overlay: small, container-native process supervisor.
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz \
    && rm -f /tmp/s6-overlay-*.tar.xz

# Pre-update SteamCMD during the build (as steam, with the right HOME) so it does
# NOT self-update and restart on first container run. That restart is what makes
# +force_install_dir install to the default Steam library instead of the target
# volume. Warming it here makes the runtime install honor force_install_dir.
RUN HOME=/home/steam /command/s6-setuidgid steam \
      /home/steam/steamcmd/steamcmd.sh +quit 2>/dev/null || true

# Put s6-overlay's /command on PATH for all contexts (docker exec, scripts, and
# the systemctl shim), not just inside s6 run scripts.
ENV PATH="/command:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ENV SteamAppId=2394010 \
    PALWORLD_APP_ID=2394010 \
    PALWORLD_INSTALL_DIR=/opt/palworld/server \
    LD_LIBRARY_PATH=/opt/palworld/server/linux64:/opt/palworld/server/Pal/Binaries/Linux \
    PALWARDEN_MODE=embedded \
    UPDATE_ON_START=true \
    PALWARDEN_CONTAINER=1 \
    PALWORLD_USER=steam \
    PALWORLD_GROUP=steam \
    MEMORY_THRESHOLD=85 \
    MEMORY_CHECK_INTERVAL=300 \
    MEMORY_WAIT=300 \
    DAILY_REPORT_AT=09:00 \
    UPDATE_CHECK=false \
    UPDATE_CHECK_INTERVAL=1800 \
    UPDATE_WAIT=300 \
    PUBLIC_INFO_INTERVAL=600 \
    SERVICE_EVENTS_INTERVAL=60 \
    PALWORLD_STEAMCMD=/home/steam/steamcmd/steamcmd.sh \
    PALWORLD_DROP_PRIV="env HOME=/home/steam s6-setuidgid steam" \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_KILL_GRACETIME=3000

# Management tooling baked in (all-in-one). Only server + web UI run this
# increment; the rest is wired to services in the next one.
COPY sbin/  /usr/local/sbin/
COPY lib/   /usr/local/lib/
COPY bin/   /usr/local/bin/
COPY webui/ /opt/palworld/tools/config-webui/
COPY docker/entrypoint.sh /usr/local/bin/palwarden-entrypoint
COPY docker/palwarden-run-periodic /usr/local/bin/palwarden-run-periodic
COPY docker/palwarden-run-daily /usr/local/bin/palwarden-run-daily
COPY docker/palwarden-render-config /usr/local/bin/palwarden-render-config
# Host-ism shims (systemctl -> s6/cgroup, sudo -> passthrough). Installed in
# /usr/local/bin so they take precedence; only present in the container.
COPY docker/shims/systemctl /usr/local/bin/systemctl
COPY docker/shims/sudo /usr/local/bin/sudo
COPY docker/s6-rc.d/ /etc/s6-overlay/s6-rc.d/

# Make our scripts executable, and pre-create the server/save/state trees owned
# by `steam` so freshly-mounted named volumes inherit the right ownership (see
# runbook §11 — we never recursively chown a mounted volume at runtime).
# Both name prefixes are globbed: `palworld-*` alone missed `palwarden-jobd`,
# whose executable bit then depended entirely on the git mode of the copied file.
# Two ownership groups, on purpose (install.sh makes the same split):
#   * steam-owned — trees an unprivileged process must write: the game's config
#     dir, the web root, and config-backups (palworld-engine-config's rollback
#     sources, which the web UI is expected to be able to manage).
#   * root-owned — config-snapshots and backups. Only root ever writes those
#     (jobd's snapshot_create/backup actions, or a hand-run command); the web UI
#     only *lists* them, which 0755 already allows, and nothing prunes them. They
#     were steam-owned, which let a less-privileged process rename a directory
#     root had just created and redirect root's writes and chowns through a
#     symlink — see the note in sbin/palworld-config-snapshot.
# backups was missing from this list entirely, so /api/backups was permanently
# empty in the container until the first backup ran.
#
# The backup panel adds two more, 0700 and with *opposite* owners, which is the
# whole of its privilege split expressed in two `install -d` lines:
#   * /var/lib/palworld/uploads — steam. The unprivileged web process streams
#     browser uploads into it and refuses to accept one unless it owns the
#     directory with no group/other bits, exactly like the job queue.
#   * /opt/palworld/restore-scratch — root:root, under the ROOT-OWNED
#     /opt/palworld. palworld-restore copies an archive here and validates the
#     copy, because archives in the backups directory are chowned to steam and are
#     therefore web-writable. That only holds if neither the directory nor any
#     parent is steam-writable, so it must not sit under /var/lib/palworld (which
#     steam owns): steam could rename root's directory aside and substitute its
#     own, and a swapped archive would restore while reporting success.
# The entrypoint creates both again at start, because /var/lib/palworld and
# /opt/palworld are usually volumes and a fresh volume shadows what is baked here.
RUN chmod +x \
        /usr/local/bin/palwarden-entrypoint \
        /usr/local/bin/palwarden-run-periodic \
        /usr/local/bin/palwarden-run-daily \
        /usr/local/bin/palwarden-render-config \
        /usr/local/bin/systemctl \
        /usr/local/bin/sudo \
        /etc/s6-overlay/s6-rc.d/palworld-server/run \
        /etc/s6-overlay/s6-rc.d/config-webui/run \
        /etc/s6-overlay/s6-rc.d/fps-sample/run \
        /etc/s6-overlay/s6-rc.d/memory-watch/run \
        /etc/s6-overlay/s6-rc.d/daily-report/run \
        /etc/s6-overlay/s6-rc.d/update-check/run \
        /etc/s6-overlay/s6-rc.d/public-info-watch/run \
        /etc/s6-overlay/s6-rc.d/service-events/run \
        /etc/s6-overlay/s6-rc.d/jobd/run \
        /etc/s6-overlay/s6-rc.d/backup-auto/run \
    && (chmod +x /usr/local/sbin/palworld-* /usr/local/sbin/palwarden-* \
        /usr/local/bin/palworld-config-parser 2>/dev/null || true) \
    && install -d -o steam -g steam \
        /opt/palworld/server/Pal/Saved/Config/LinuxServer \
        /opt/palworld/tools \
        /opt/palworld/config-backups \
        /var/lib/palworld \
        /var/log/palworld \
    && install -d -o root -g root -m 0755 \
        /opt/palworld/config-snapshots \
        /opt/palworld/backups \
    && install -d -o steam -g steam -m 0700 \
        /var/lib/palworld/uploads \
    && install -d -o root -g root -m 0700 \
        /opt/palworld/restore-scratch

WORKDIR /opt/palworld/server

# s6-overlay shuts down cleanly on SIGTERM; the server's s6 service forwards
# SIGINT to the game so it saves. S6_KILL_GRACETIME gives it time before SIGKILL.
STOPSIGNAL SIGTERM

EXPOSE 8211/udp
EXPOSE 8212/tcp
EXPOSE 8088/tcp

ENTRYPOINT ["/usr/local/bin/palwarden-entrypoint"]
