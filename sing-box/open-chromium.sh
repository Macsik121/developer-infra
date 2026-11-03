#!/bin/bash
# Open Chromium on the WSLg desktop (Windows: separate window).
# Chromium is not auto-restarted, so use this after closing it.
# Prefer supervisor so the process is tracked and its logs land in
# /var/log/supervisor/chromium.err.log:
#   supervisorctl start chromium
# Falls back to a direct launch if supervisor already has it RUNNING.

export DISPLAY="${DISPLAY:-:0}"
export HOME="${HOME:-/home/coder}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/home/coder/.xdg}"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

if supervisorctl status chromium 2>/dev/null | grep -q RUNNING; then
    echo "chromium is already running"
    exit 0
fi

if supervisorctl start chromium 2>/dev/null; then
    exit 0
fi

exec /usr/bin/chromium \
    --no-sandbox --disable-dev-shm-usage \
    --no-first-run --no-default-browser-check --password-store=basic \
    --disable-features=dbus --ozone-platform=x11 \
    --user-data-dir=/home/coder/.chromium-profile \
    --window-position=0,0 --window-size=1280,800 \
    --disable-background-timer-throttling \
    --disable-backgrounding-occluded-windows \
    --disable-renderer-backgrounding \
    --disable-frame-rate-limit --disable-gpu-vsync \
    https://ipinfo.io
