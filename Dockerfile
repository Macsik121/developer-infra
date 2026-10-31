FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# 1. Install core utilities, Python, Supervisor, and X11/noVNC for Chromium GUI
RUN apt-get update && apt-get install -y \
    curl wget git sudo unzip nano jq ca-certificates gnupg \
    iptables iproute2 supervisor dos2unix \
    python3 python3-pip python3-venv pipx \
    xvfb x11vnc novnc websockify fluxbox dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Node.js (v22 LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# 3. Install Chromium Browser (via PPA to avoid Ubuntu 24 Snap errors in Docker)
RUN apt-get update && apt-get install -y software-properties-common && \
    add-apt-repository -y ppa:xtradeb/apps && \
    apt-get update && apt-get install -y chromium && \
    rm -rf /var/lib/apt/lists/*

# 4. Install VS Code (code-server)
RUN curl -fsSL https://code-server.dev/install.sh | sh

# 5. Install Claude Code & Omniroute
RUN npm install -g @anthropic-ai/claude-code
RUN npm install -g omniroute || pip3 install --break-system-packages omniroute || true

# 6. Create a non-root developer user ('coder') with passwordless sudo
RUN useradd -m -s /bin/bash coder && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# 7. Prepare directories
RUN mkdir -p /home/coder/workspace /etc/sing-box /var/log/supervisor && \
    chown -R coder:coder /home/coder

# 8. Copy your sing-box scripts and run setup-vpn.sh
COPY ./sing-box /etc/sing-box
#RUN lsmod | grep tun && sudo modprobe tun && echo "tun" | sudo tee -a /etc/modules && \
#    ls -l /dev/net/tun && \
#RUN find /etc/sing-box -type f -name "*.sh" -exec dos2unix {} + && \
 #   chmod +x /etc/sing-box/*.sh && \
  #  cd /etc/sing-box && ./setup-vpn.sh
# 8. Copy your sing-box scripts and prepare permissions (do NOT run setup-vpn.sh during build)
COPY ./sing-box /etc/sing-box
RUN find /etc/sing-box -type f -name "*.sh" -exec dos2unix {} + && \
    chmod +x /etc/sing-box/*.sh

# Copy Supervisor process manager configuration
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 8080 6080 1080

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
