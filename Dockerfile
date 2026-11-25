FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Pinned component versions (D10) — override via --build-arg when upgrading
ARG TARGETARCH=amd64
ARG SING_BOX_VERSION=1.12.8
ARG SING_BOX_SHA256_AMD64=b41d9ae438a4367e5fd5c4aa36fe040d0c1bfe5f91f96a072eef31f61d46670c
ARG SING_BOX_SHA256_ARM64=
ARG CODE_SERVER_VERSION=4.146.0
ARG CLAUDE_CODE_VERSION=2.1.331
ARG OMNIROUTE_VERSION=3.8.54

# 1. Core utilities, networking, Python, Supervisor, X11/noVNC & GUI notification stack
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git unzip nano jq ca-certificates gnupg iputils-ping dnsutils \
    iptables iproute2 supervisor dos2unix procps \
    python3 python3-pip python3-venv \
    xvfb x11vnc novnc websockify fluxbox dbus-x11 \
    x11-apps x11-utils libnotify-bin dunst \
    && rm -rf /var/lib/apt/lists/*

# 2. Node.js v22 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# 3. Chromium from PPA (avoids Ubuntu 24 snap package which breaks in Docker)
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:xtradeb/apps \
    && apt-get update && apt-get install -y --no-install-recommends chromium \
    && rm -rf /var/lib/apt/lists/*

# 4. sing-box pre-baked at build time with SHA256 verification (F4, D10)
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

# 5. code-server (pinned)
RUN curl -fsSL https://code-server.dev/install.sh | sh -s -- --version="${CODE_SERVER_VERSION}"

# 6. Claude Code & OmniRoute (pinned)
RUN npm install -g \
    "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    "omniroute@${OMNIROUTE_VERSION}" \
    && npm cache clean --force

# 7. Unprivileged developer user — NO sudo / NOPASSWD:ALL (D8)
RUN useradd -m -s /bin/bash coder

# 8. Prepare directories with least-privilege permissions (D3, D8)
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

# 8a. UTF-8 locale (placed after heavy layers so Docker build cache stays intact, ST-LIVE-4)
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color

# 9. Install container runtime scripts & configs
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
    CMD /bin/bash -c 'curl -fsS --max-time 3 http://127.0.0.1:8080/healthz >/dev/null && (ip link show sing-tun >/dev/null 2>&1 || grep -Eq "^(direct|proxy)$" /run/vpn/mode 2>/dev/null)'

ENTRYPOINT ["/usr/local/lib/dev-infra/entrypoint.sh"]