FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Core utilities, Python, Supervisor, X11/noVNC stack
RUN apt-get update && apt-get install -y \
    curl wget git sudo unzip nano jq ca-certificates gnupg iputils-ping \
    iptables iproute2 supervisor dos2unix \
    python3 python3-pip python3-venv pipx \
    xvfb x11vnc novnc websockify fluxbox dbus-x11 \
    x11-apps x11-utils \
    && rm -rf /var/lib/apt/lists/*

# 2. Node.js v22 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# 3. Chromium from PPA (avoids Ubuntu 24 snap package which breaks in Docker)
RUN apt-get update && apt-get install -y software-properties-common && \
    add-apt-repository -y ppa:xtradeb/apps && \
    apt-get update && apt-get install -y chromium && \
    rm -rf /var/lib/apt/lists/*

# 4. code-server
RUN curl -fsSL https://code-server.dev/install.sh | sh

# 5. Claude Code
RUN npm install -g @anthropic-ai/claude-code omniroute

# 6. Non-root developer user with passwordless sudo
RUN useradd -m -s /bin/bash coder && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# 7. Prepare directories
RUN mkdir -p /home/coder/workspace /etc/sing-box /var/log/supervisor && \
    chown -R coder:coder /home/coder

# 8. Copy sing-box scripts. NOTE: this COPY is later shadowed by the
#    bind-mount in docker-compose. dos2unix + chmod happen at container
#    start (see CMD below), not at build time, because the bind-mount
#    overwrites what we sanitize here.
COPY ./sing-box /etc/sing-box

# 9. Supervisor config
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# 9a. Reopen helper — chromium does not auto-restart after you close it.
#     `docker exec ubuntu24-dev-box open-chromium`
#     /etc/sing-box is bind-mounted at runtime, so the copy from step 8 is
#     shadowed by the host dir. Instead we symlink to the bind-mounted file,
#     which is always the current one; setup-vpn.sh does the same on first run.
RUN ln -sf /etc/sing-box/open-chromium.sh /usr/local/bin/open-chromium

# 9b. noVNC has no index.html in the Debian package, so a bare
#     http://localhost:6901/ would only show a directory listing.
#     Drop in a redirect to vnc.html so the root URL works.
COPY novnc-index.html /usr/share/novnc/index.html

EXPOSE 8080 6080
# 8080 — code-server
# 6080 — websockify / noVNC (compose maps host 6901 -> container 6080)
# 2080 not exposed: config.json has only a TUN inbound, no SOCKS/HTTP port

# 10. At every container start:
#     - sanitize CRLF from *.sh that came through the bind mount
#     - make them executable
#     - hand off to supervisord
CMD ["/bin/bash", "-c", "for f in /etc/sing-box/*.sh; do [ -f \"$f\" ] || continue; dos2unix \"$f\"; chmod +x \"$f\"; done; chmod 700 /home/coder/.xdg 2>/dev/null; exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf"]