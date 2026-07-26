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

# Runtime dependencies for the tooling + supervisor.
#   python3         - REST client, telemetry, config helpers, web UI server
#   procps/iproute2 - pkill/ps/ss used by the scripts and stop handling
#   xz-utils        - extract the s6-overlay release tarballs
# matplotlib (FPS/health graphs) is intentionally omitted to keep the image
# smaller; text reports work without it.
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
    && rm -rf /var/lib/apt/lists/*

# s6-overlay: small, container-native process supervisor.
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz \
    && rm -f /tmp/s6-overlay-*.tar.xz

ENV SteamAppId=2394010 \
    PALWORLD_APP_ID=2394010 \
    PALWORLD_INSTALL_DIR=/opt/palworld/server \
    LD_LIBRARY_PATH=/opt/palworld/server/linux64:/opt/palworld/server/Pal/Binaries/Linux \
    PALWARDEN_MODE=embedded \
    UPDATE_ON_START=true \
    S6_KILL_GRACETIME=110000 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# Management tooling baked in (all-in-one). Only server + web UI run this
# increment; the rest is wired to services in the next one.
COPY sbin/  /usr/local/sbin/
COPY lib/   /usr/local/lib/
COPY bin/   /usr/local/bin/
COPY webui/ /opt/palworld/tools/config-webui/
COPY docker/entrypoint.sh /usr/local/bin/palwarden-entrypoint
COPY docker/s6-rc.d/ /etc/s6-overlay/s6-rc.d/

# Make our scripts executable, and pre-create the server/save trees owned by
# `steam` so freshly-mounted named volumes inherit the right ownership (see
# runbook §11 — we never recursively chown a mounted volume at runtime).
RUN chmod +x \
        /usr/local/bin/palwarden-entrypoint \
        /etc/s6-overlay/s6-rc.d/palworld-server/run \
        /etc/s6-overlay/s6-rc.d/config-webui/run \
    && (chmod +x /usr/local/sbin/palworld-* /usr/local/bin/palworld-config-parser 2>/dev/null || true) \
    && install -d -o steam -g steam \
        /opt/palworld/server/Pal/Saved/Config/LinuxServer \
        /opt/palworld/tools \
        /var/log/palworld

WORKDIR /opt/palworld/server

# s6-overlay shuts down cleanly on SIGTERM; the server's s6 service forwards
# SIGINT to the game so it saves. S6_KILL_GRACETIME gives it time before SIGKILL.
STOPSIGNAL SIGTERM

EXPOSE 8211/udp
EXPOSE 8212/tcp
EXPOSE 8088/tcp

ENTRYPOINT ["/usr/local/bin/palwarden-entrypoint"]
