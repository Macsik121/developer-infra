# ==============================================================================
# developer-infra — Multi-Stage Dockerfile (v2.2.4, Zero-Docker-Hub Bootstrap)
#
# No `# syntax=docker/dockerfile:1` directive on purpose: BuildKit uses its
# built-in parser and NEVER calls registry-1.docker.io/v2/docker/dockerfile
# (fixes builds on restricted networks / hosts without a pre-existing VPN).
#
# Build targets (selected via DEV_INFRA_PROFILE or `run-env --profile / -Profile`):
#   - lite : Fast first-run image: networking + sing-box TUN VPN + X11/noVNC + Chromium.
#            Use this to verify VPN subscription, routing & Chromium before installing heavy IDE/AI tools.
#   - full : Complete dev environment (default): reuses 100% of `base-net` cache and adds
#            python3-pip/venv, Node.js 22 LTS, code-server, Claude Code & OmniRoute.
#
# Cache-friendly DAG:
#   base-net -> lite
#   base-net -> full-deps -> full
# Editing runtime scripts in container/ or supervisord.conf rebuilds ONLY the final COPY layer (~1s)
# for both lite and full without invalidating Chromium, Node.js, code-server, or npm layers.
# ==============================================================================

# Official Canonical Ubuntu 24.04 on AWS Public ECR (multi-arch amd64/arm64, avoids Docker Hub blocks/limits).
# Override via BASE_IMAGE in .env (e.g., dockerhub.timeweb.cloud/library/ubuntu:24.04 or ubuntu:24.04).
ARG BASE_IMAGE=public.ecr.aws/ubuntu/ubuntu:24.04

# ------------------------------------------------------------------------------
# Stage 1: base-net — Core networking, sing-box, X11/noVNC, Chromium & coder user
# ------------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS base-net

ENV DEBIAN_FRONTEND=noninteractive

# Pinned core versions (D10) & optional network mirrors — override via .env / --build-arg
ARG TARGETARCH=amd64
ARG SING_BOX_VERSION=1.12.8
ARG SING_BOX_SHA256_AMD64=b41d9ae438a4367e5fd5c4aa36fe040d0c1bfe5f91f96a072eef31f61d46670c
ARG SING_BOX_SHA256_ARM64=
ARG APT_MIRROR=

# Optional APT mirror rewrite for Ubuntu 24.04 (DEB822 ubuntu.sources + legacy sources.list)
RUN if [ -n "${APT_MIRROR}" ]; then \
        MIRROR="${APT_MIRROR%/}"; \
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do \
            if [ -f "$f" ]; then \
                sed -i -E "s|https?://(archive|security)\.ubuntu\.com/ubuntu|${MIRROR}|g" "$f"; \
            fi; \
        done; \
    fi

# 1. Core utilities, networking, Python runtime, Supervisor, X11/noVNC & GUI notifications
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git unzip nano jq ca-certificates gnupg iputils-ping dnsutils \
    iptables iproute2 supervisor dos2unix procps \
    python3 \
    xvfb x11vnc novnc websockify fluxbox dbus-x11 \
    x11-apps x11-utils libnotify-bin dunst \
    && rm -rf /var/lib/apt/lists/*

# 2. sing-box pre-baked at build time with SHA256 verification (F4, D10)
RUN set -eux; \
    ARCH="${TARGETARCH:-amd64}"; \
    case "$ARCH" in \
        amd64|arm64) ;; \
        *) echo "Unsupported TARGETARCH: $ARCH" >&2; exit 1 ;; \
    esac; \
    TARBALL="sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz"; \
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${TARBALL}"; \
    curl -fsSL "$URL" -o "/tmp/${TARBALL}"; \
    EXPECTED_SHA=""; \
    if [ "$ARCH" = "amd64" ]; then \
        EXPECTED_SHA="${SING_BOX_SHA256_AMD64}"; \
    elif [ -n "${SING_BOX_SHA256_ARM64}" ]; then \
        EXPECTED_SHA="${SING_BOX_SHA256_ARM64}"; \
    else \
        EXPECTED_SHA="$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${SING_BOX_VERSION}" \
            | jq -r --arg name "$TARBALL" '.assets[] | select(.name == $name) | .digest // empty' \
            | sed 's/^sha256://')"; \
    fi; \
    test -n "$EXPECTED_SHA" || { echo "Missing SHA256 checksum for ${TARBALL}" >&2; exit 1; }; \
    echo "${EXPECTED_SHA}  /tmp/${TARBALL}" | sha256sum -c -; \
    tar -xzf "/tmp/${TARBALL}" -C /tmp; \
    install -m 0755 "/tmp/sing-box-${SING_BOX_VERSION}-linux-${ARCH}/sing-box" /usr/local/bin/sing-box; \
    rm -rf "/tmp/${TARBALL}" "/tmp/sing-box-${SING_BOX_VERSION}-linux-${ARCH}"; \
    /usr/local/bin/sing-box version

# 3. Chromium from PPA (avoids Ubuntu 24 snap package which breaks in Docker)
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:xtradeb/apps \
    && apt-get update && apt-get install -y --no-install-recommends chromium \
    && rm -rf /var/lib/apt/lists/*

# 4. Unprivileged developer user — NO sudo / NOPASSWD:ALL (D8)
RUN useradd -m -s /bin/bash coder

# 5. Prepare directories with least-privilege permissions (D3, D8)
RUN mkdir -p \
        /home/coder/workspace \
        /home/coder/.config/omniroute \
        /home/coder/.config/code-server \
        /home/coder/.local/share/code-server \
        /home/coder/.chromium-profile \
        /home/coder/.claude \
        /home/coder/.xdg \
        /etc/sing-box \
        /var/lib/sing-box \
        /var/log/supervisor \
        /usr/local/lib/dev-infra \
    && chown -R coder:coder /home/coder \
    && chmod 700 /var/lib/sing-box /home/coder/.xdg /home/coder/.claude \
    && chmod 750 /var/log/supervisor

# 6. UTF-8 locale (ST-LIVE-4)
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color

# ------------------------------------------------------------------------------
# Stage 2: lite — Fast VPN + Chromium verification target (no Node/IDE/AI stack)
# ------------------------------------------------------------------------------
FROM base-net AS lite

ENV DEV_INFRA_PROFILE=lite

COPY container/ /usr/local/lib/dev-infra/
COPY ./sing-box/open-chromium.sh /etc/sing-box/open-chromium.sh
COPY ./sing-box/test-connection.sh /etc/sing-box/test-connection.sh
COPY ./sing-box/setup-vpn.sh /etc/sing-box/setup-vpn.sh
COPY ./sing-box/config.json.example /etc/sing-box/config.json.example
COPY ./start-claude.sh /usr/local/bin/start-claude
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY novnc-index.html /usr/share/novnc/index.html

RUN chmod 0755 \
        /usr/local/lib/dev-infra/entrypoint.sh \
        /usr/local/lib/dev-infra/display-detect.sh \
        /usr/local/lib/dev-infra/wait-for-tun.sh \
        /usr/local/lib/dev-infra/start-chromium.sh \
        /usr/local/lib/dev-infra/vpn-ctl.sh \
        /usr/local/lib/dev-infra/vpn-watchdog.sh \
        /usr/local/lib/dev-infra/vpn-sub-updater.py \
        /usr/local/lib/dev-infra/vpn-status-server.py \
        /usr/local/bin/start-claude \
        /etc/sing-box/open-chromium.sh \
        /etc/sing-box/test-connection.sh \
        /etc/sing-box/setup-vpn.sh \
    && chmod 0644 /usr/local/lib/dev-infra/bashrc-vpn-banner.sh \
    && ln -sf /usr/local/lib/dev-infra/vpn-ctl.sh /usr/local/bin/vpn-ctl \
    && ln -sf /usr/local/lib/dev-infra/start-chromium.sh /usr/local/bin/open-chromium \
    && ln -sf /usr/local/bin/start-claude /usr/local/bin/start-claude.sh \
    && printf '\n# developer-infra VPN status banner\n[ -r /usr/local/lib/dev-infra/bashrc-vpn-banner.sh ] && . /usr/local/lib/dev-infra/bashrc-vpn-banner.sh\n' >> /etc/bash.bashrc

EXPOSE 8080 6080 20128

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD /bin/bash -c 'curl -fsS --max-time 3 http://127.0.0.1:9099/healthz >/dev/null && (! command -v code-server >/dev/null 2>&1 || curl -fsS --max-time 3 http://127.0.0.1:8080/healthz >/dev/null) && (ip link show sing-tun >/dev/null 2>&1 || grep -Eq "^(direct|proxy)$" /run/vpn/mode 2>/dev/null)'

ENTRYPOINT ["/usr/local/lib/dev-infra/entrypoint.sh"]

# ------------------------------------------------------------------------------
# Stage 3: full-deps — Heavy IDE & AI toolchain (reuses 100% of base-net cache)
# ------------------------------------------------------------------------------
FROM base-net AS full-deps

ARG CODE_SERVER_VERSION=4.146.0
ARG CLAUDE_CODE_VERSION=2.1.331
ARG OMNIROUTE_VERSION=3.8.54
ARG NPM_REGISTRY=

# 7. Python dev tooling & Node.js v22 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends python3-pip python3-venv nodejs \
    && rm -rf /var/lib/apt/lists/*

# 8. code-server (pinned)
RUN curl -fsSL https://code-server.dev/install.sh | sh -s -- --version="${CODE_SERVER_VERSION}"

# 9. Claude Code & OmniRoute (pinned; supports optional NPM_REGISTRY mirror)
RUN if [ -n "${NPM_REGISTRY}" ]; then npm config set registry "${NPM_REGISTRY}"; fi \
    && npm install -g \
    "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    "omniroute@${OMNIROUTE_VERSION}" \
    && npm cache clean --force

# ------------------------------------------------------------------------------
# Stage 4: full — Complete developer-infra image (default final stage)
# ------------------------------------------------------------------------------
FROM full-deps AS full

ENV DEV_INFRA_PROFILE=full

COPY container/ /usr/local/lib/dev-infra/
COPY ./sing-box/open-chromium.sh /etc/sing-box/open-chromium.sh
COPY ./sing-box/test-connection.sh /etc/sing-box/test-connection.sh
COPY ./sing-box/setup-vpn.sh /etc/sing-box/setup-vpn.sh
COPY ./sing-box/config.json.example /etc/sing-box/config.json.example
COPY ./start-claude.sh /usr/local/bin/start-claude
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY novnc-index.html /usr/share/novnc/index.html

RUN chmod 0755 \
        /usr/local/lib/dev-infra/entrypoint.sh \
        /usr/local/lib/dev-infra/display-detect.sh \
        /usr/local/lib/dev-infra/wait-for-tun.sh \
        /usr/local/lib/dev-infra/start-chromium.sh \
        /usr/local/lib/dev-infra/vpn-ctl.sh \
        /usr/local/lib/dev-infra/vpn-watchdog.sh \
        /usr/local/lib/dev-infra/vpn-sub-updater.py \
        /usr/local/lib/dev-infra/vpn-status-server.py \
        /usr/local/bin/start-claude \
        /etc/sing-box/open-chromium.sh \
        /etc/sing-box/test-connection.sh \
        /etc/sing-box/setup-vpn.sh \
    && chmod 0644 /usr/local/lib/dev-infra/bashrc-vpn-banner.sh \
    && ln -sf /usr/local/lib/dev-infra/vpn-ctl.sh /usr/local/bin/vpn-ctl \
    && ln -sf /usr/local/lib/dev-infra/start-chromium.sh /usr/local/bin/open-chromium \
    && ln -sf /usr/local/bin/start-claude /usr/local/bin/start-claude.sh \
    && printf '\n# developer-infra VPN status banner\n[ -r /usr/local/lib/dev-infra/bashrc-vpn-banner.sh ] && . /usr/local/lib/dev-infra/bashrc-vpn-banner.sh\n' >> /etc/bash.bashrc

EXPOSE 8080 6080 20128

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD /bin/bash -c 'curl -fsS --max-time 3 http://127.0.0.1:9099/healthz >/dev/null && (! command -v code-server >/dev/null 2>&1 || curl -fsS --max-time 3 http://127.0.0.1:8080/healthz >/dev/null) && (ip link show sing-tun >/dev/null 2>&1 || grep -Eq "^(direct|proxy)$" /run/vpn/mode 2>/dev/null)'

ENTRYPOINT ["/usr/local/lib/dev-infra/entrypoint.sh"]