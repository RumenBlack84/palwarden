# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# palwarden all-in-one image: the Palworld dedicated server + management tooling
# in a single artifact. Behavior is selected at runtime by PALWARDEN_MODE
# (embedded = run the server here; external = manage a server elsewhere).
#
# Base: cm2network/steamcmd provides SteamCMD, the 32-bit runtime libraries, and
# a non-root `steam` user (uid/gid 1000). The :root tag starts as root so we can
# install extra packages, then we drop to `steam`.
#
# syntax=docker/dockerfile:1
FROM cm2network/steamcmd:root

ARG DEBIAN_FRONTEND=noninteractive

# Runtime dependencies for the tooling (Python stdlib client, curl, ps, tar).
# matplotlib (for FPS/health graphs) is intentionally omitted to keep the image
# smaller; text reports work without it. Add it in the tooling increment if the
# graph features are wanted in-container.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        curl \
        ca-certificates \
        tar \
        gzip \
        procps \
        iproute2 \
    && rm -rf /var/lib/apt/lists/*

ENV SteamAppId=2394010 \
    PALWORLD_APP_ID=2394010 \
    PALWORLD_INSTALL_DIR=/opt/palworld/server \
    LD_LIBRARY_PATH=/opt/palworld/server/linux64:/opt/palworld/server/Pal/Binaries/Linux \
    PALWARDEN_MODE=embedded \
    UPDATE_ON_START=true

# Management tooling baked in so this is a true all-in-one image. The processes
# that use it are wired under a supervisor in the next increment; the files are
# present and on PATH now.
COPY sbin/ /usr/local/sbin/
COPY lib/  /usr/local/lib/
COPY bin/  /usr/local/bin/
COPY webui/ /opt/palworld/tools/config-webui/
COPY docker/entrypoint.sh /usr/local/bin/palwarden-entrypoint

# Ownership: create the server/tooling/log trees owned by the unprivileged
# `steam` user from the base image, and make our scripts executable. We do NOT
# recursively chown mounted volumes at runtime (see runbook §11).
RUN chmod +x /usr/local/bin/palwarden-entrypoint \
    && chmod +x /usr/local/sbin/palworld-* /usr/local/bin/palworld-config-parser 2>/dev/null || true \
    && install -d -o steam -g steam \
        /opt/palworld/server \
        /opt/palworld/tools \
        /var/log/palworld

USER steam
WORKDIR /opt/palworld/server

# Preserve the VM's stop semantics: SIGINT with a long grace period.
STOPSIGNAL SIGINT

# 8211/udp: players. 8212/tcp: REST API (internal only; do not publish publicly).
EXPOSE 8211/udp
EXPOSE 8212/tcp

ENTRYPOINT ["/usr/local/bin/palwarden-entrypoint"]
