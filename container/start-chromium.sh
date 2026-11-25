#!/usr/bin/env bash
# Launches Chromium with dynamic display detection, stale SingletonLock cleanup,
# mandatory XDG_RUNTIME_DIR="" (Wayland bypass for X11/WSLg), optional --proxy mode,
# and startup VPN Status Dashboard (http://127.0.0.1:9099).
set -euo pipefail

export HOME="${HOME:-/home/coder}"
PROFILE_DIR="${CHROMIUM_PROFILE_DIR:-${HOME}/.chromium-profile}"
XDG_DIR="${HOME}/.xdg"
DISPLAY_DETECT_BIN="${DISPLAY_DETECT_BIN:-/usr/local/lib/dev-infra/display-detect.sh}"
CHROMIUM_BIN="${CHROMIUM_BIN:-/usr/bin/chromium}"
START_URL="${CHROMIUM_START_URL:-http://127.0.0.1:9099}"
USE_LOCAL_PROXY=0

PASSTHROUGH_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--proxy" ]]; then
        USE_LOCAL_PROXY=1
    else
        PASSTHROUGH_ARGS+=("$arg")
    fi
done

mkdir -p "$PROFILE_DIR" "$XDG_DIR"
chmod 700 "$XDG_DIR"

DETECTED_DISPLAY="$("$DISPLAY_DETECT_BIN")"
export DISPLAY="$DETECTED_DISPLAY"

if [[ "$DISPLAY" == ":99" ]]; then
    for _ in $(seq 1 15); do
        if DISPLAY=":99" timeout 1 xdpyinfo >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
fi

if ! pgrep -u "$(id -u)" -f "(chromium|chrome)" >/dev/null 2>&1; then
    rm -f "${PROFILE_DIR}/SingletonLock" \
          "${PROFILE_DIR}/SingletonSocket" \
          "${PROFILE_DIR}/SingletonCookie"
fi

# Chesterton's Fence: NEVER pass --disable-software-rasterizer under WSLg
ARGS=(
    --no-sandbox
    --disable-dev-shm-usage
    --no-first-run
    --no-default-browser-check
    --password-store=basic
    --disable-features=dbus
    --ozone-platform=x11
    "--user-data-dir=${PROFILE_DIR}"
    --window-position=0,0
    --window-size=1280,800
    --disable-background-timer-throttling
    --disable-backgrounding-occluded-windows
    --disable-renderer-backgrounding
    --disable-frame-rate-limit
    --disable-gpu-vsync
)

if [[ "${CHROMIUM_DISABLE_GPU:-0}" == "1" ]]; then
    ARGS+=(--disable-gpu)
fi

if [[ "$USE_LOCAL_PROXY" -eq 1 ]]; then
    ARGS+=("--proxy-server=http://127.0.0.1:2080")
fi

if [[ ${#PASSTHROUGH_ARGS[@]} -gt 0 ]]; then
    ARGS+=("${PASSTHROUGH_ARGS[@]}")
else
    ARGS+=("$START_URL")
fi

# CRITICAL: Blank XDG_RUNTIME_DIR right before exec so Chromium uses X11 instead of Wayland
XDG_RUNTIME_DIR="" exec "$CHROMIUM_BIN" "${ARGS[@]}"
