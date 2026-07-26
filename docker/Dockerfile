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
    MEMORY_THRESHOLD=85 \
    MEMORY_CHECK_INTERVAL=300 \
    MEMORY_WAIT=300 \
    DAILY_REPORT_AT=09:00 \
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
# Host-ism shims (systemctl -> s6/cgroup, sudo -> passthrough). Installed in
# /usr/local/bin so they take precedence; only present in the container.
COPY docker/shims/systemctl /usr/local/bin/systemctl
COPY docker/shims/sudo /usr/local/bin/sudo
COPY docker/s6-rc.d/ /etc/s6-overlay/s6-rc.d/

# Make our scripts executable, and pre-create the server/save/state trees owned
# by `steam` so freshly-mounted named volumes inherit the right ownership (see
# runbook §11 — we never recursively chown a mounted volume at runtime).
RUN chmod +x \
        /usr/local/bin/palwarden-entrypoint \
        /usr/local/bin/palwarden-run-periodic \
        /usr/local/bin/palwarden-run-daily \
        /usr/local/bin/systemctl \
        /usr/local/bin/sudo \
        /etc/s6-overlay/s6-rc.d/palworld-server/run \
        /etc/s6-overlay/s6-rc.d/config-webui/run \
        /etc/s6-overlay/s6-rc.d/fps-sample/run \
        /etc/s6-overlay/s6-rc.d/memory-watch/run \
        /etc/s6-overlay/s6-rc.d/daily-report/run \
    && (chmod +x /usr/local/sbin/palworld-* /usr/local/bin/palworld-config-parser 2>/dev/null || true) \
    && install -d -o steam -g steam \
        /opt/palworld/server/Pal/Saved/Config/LinuxServer \
        /opt/palworld/tools \
        /var/lib/palworld \
        /var/log/palworld

WORKDIR /opt/palworld/server

# s6-overlay shuts down cleanly on SIGTERM; the server's s6 service forwards
# SIGINT to the game so it saves. S6_KILL_GRACETIME gives it time before SIGKILL.
STOPSIGNAL SIGTERM

EXPOSE 8211/udp
EXPOSE 8212/tcp
EXPOSE 8088/tcp

ENTRYPOINT ["/usr/local/bin/palwarden-entrypoint"]
