#!/usr/bin/env bash
# Detects active X11 display: returns ":0" if live WSLg/host X server responds,
# otherwise falls back to virtual Xvfb ":99".
set -euo pipefail

X11_SOCKET_PATH="${X11_SOCKET_PATH:-/tmp/.X11-unix/X0}"

if [[ -S "$X11_SOCKET_PATH" ]] && DISPLAY=":0" timeout 2 xdpyinfo >/dev/null 2>&1; then
    echo ":0"
else
    echo ":99"
fi
