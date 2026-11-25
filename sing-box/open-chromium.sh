#!/usr/bin/env bash
# Reopens Chromium cleanly using dynamic display detection and XDG_RUNTIME_DIR="".
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]] && command -v supervisorctl >/dev/null 2>&1; then
    if supervisorctl status chromium 2>/dev/null | grep -q RUNNING; then
        echo "chromium is already running"
        exit 0
    fi
    if supervisorctl start chromium 2>/dev/null; then
        exit 0
    fi
fi

exec /usr/local/lib/dev-infra/start-chromium.sh "$@"
