#!/usr/bin/env bash
# Interactive & CLI supervisor log collector for developer-infra (Linux / macOS / WSL).
# Usage:
#   ./collect-logs.sh
#   ./collect-logs.sh --scope vpn --lines 50
#   ./collect-logs.sh --scope all --lines 30 --out-file diagnostics/my-logs.log
#   ./collect-logs.sh --scope sing-box --lines 100
set -euo pipefail

SCOPE=""
LINES=50
OUT_FILE=""
ENV_FILE=".env"
CONTAINER_ID=""

ALL_PACKAGES=(
    sing-box
    vpn-sub-updater
    vpn-watchdog
    vpn-status
    xvfb
    fluxbox
    x11vnc
    novnc
    chromium
    code-server
    omniroute
)
VPN_PACKAGES=(sing-box vpn-sub-updater vpn-watchdog vpn-status)
GUI_PACKAGES=(xvfb fluxbox x11vnc novnc chromium)
DEV_PACKAGES=(code-server omniroute)

usage() {
    cat <<EOF
Usage: ./collect-logs.sh [OPTIONS]

Options:
  --scope <all|vpn|gui|dev|package>  Log group or single supervisor package (interactive if omitted)
  --lines <N>                        Number of tail lines per .out/.err log (default: 50)
  --out-file <path>                  Output log bundle path (default: diagnostics/logs-<scope>-<ts>.log)
  --env-file <path>                  Path to .env file (default: .env)
  --container-id <id>                Optional pre-resolved container ID (skips docker compose lookup)
  -h, --help                         Show this help

Groups:
  all : ${ALL_PACKAGES[*]}
  vpn : ${VPN_PACKAGES[*]}
  gui : ${GUI_PACKAGES[*]}
  dev : ${DEV_PACKAGES[*]}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scope)        SCOPE="${2:-}"; shift 2 ;;
        --lines)        LINES="${2:-50}"; shift 2 ;;
        --out-file)     OUT_FILE="${2:-}"; shift 2 ;;
        --env-file)     ENV_FILE="${2:-.env}"; shift 2 ;;
        --container-id) CONTAINER_ID="${2:-}"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker CLI not found." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: Env file '${ENV_FILE}' not found." >&2; exit 1; }

if [[ -z "$CONTAINER_ID" ]]; then
    CONTAINER_ID="$(docker compose --env-file "$ENV_FILE" ps -q ubuntu-dev 2>/dev/null | head -n 1 | tr -d '\r\n' || true)"
    if [[ -z "$CONTAINER_ID" ]]; then
        echo "ERROR: Container 'ubuntu-dev' is not running. Start it with ./run-env.sh --auto-port" >&2
        exit 1
    fi
fi

if [[ -z "$SCOPE" ]]; then
    echo ""
    echo "=== developer-infra Log Collector ==="
    echo "Select which supervisor logs to collect:"
    echo "  1) All packages (all)"
    echo "  2) VPN / TUN stack (${VPN_PACKAGES[*]})"
    echo "  3) Graphics / GUI stack (${GUI_PACKAGES[*]})"
    echo "  4) IDE & AI stack (${DEV_PACKAGES[*]})"
    echo "  5) Single package (choose one)"
    echo ""
    read -r -p "Enter choice [1-5, default: 1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        1) SCOPE="all" ;;
        2) SCOPE="vpn" ;;
        3) SCOPE="gui" ;;
        4) SCOPE="dev" ;;
        5)
            echo ""
            echo "Available packages:"
            for i in "${!ALL_PACKAGES[@]}"; do
                printf '  %2d) %s\n' "$((i + 1))" "${ALL_PACKAGES[$i]}"
            done
            read -r -p "Enter number [1-${#ALL_PACKAGES[@]}] or package name: " pkg_pick
            if [[ "$pkg_pick" =~ ^[0-9]+$ ]] && (( pkg_pick >= 1 && pkg_pick <= ${#ALL_PACKAGES[@]} )); then
                SCOPE="${ALL_PACKAGES[$((pkg_pick - 1))]}"
            else
                SCOPE="${pkg_pick:-sing-box}"
            fi
            ;;
        *) SCOPE="$choice" ;;
    esac

    read -r -p "Tail lines per log file [default: ${LINES}]: " lines_in
    if [[ "$lines_in" =~ ^[0-9]+$ ]] && (( lines_in > 0 )); then
        LINES="$lines_in"
    fi
fi

SELECTED=()
case "$SCOPE" in
    all) SELECTED=("${ALL_PACKAGES[@]}") ;;
    vpn) SELECTED=("${VPN_PACKAGES[@]}") ;;
    gui) SELECTED=("${GUI_PACKAGES[@]}") ;;
    dev) SELECTED=("${DEV_PACKAGES[@]}") ;;
    *)
        matched=0
        for p in "${ALL_PACKAGES[@]}"; do
            if [[ "$p" == "$SCOPE" ]]; then
                SELECTED=("$p")
                matched=1
                break
            fi
        done
        if [[ "$matched" -eq 0 ]]; then
            echo "ERROR: Unknown scope or package '${SCOPE}'." >&2
            exit 1
        fi
        ;;
esac

TS="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$OUT_FILE" ]]; then
    mkdir -p diagnostics
    OUT_FILE="diagnostics/logs-${SCOPE}-${TS}.log"
else
    mkdir -p "$(dirname "$OUT_FILE")"
fi

redact_stream() {
    sed -E \
        -e 's#(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]"'\'']+#\1<redacted>#gI' \
        -e 's#(https?://[^/[:space:]]+/sub/)[^[:space:]"'\'']+#\1<redacted>#gI' \
        -e 's#((VPN_SUBSCRIPTION_URL|ANTHROPIC_AUTH_TOKEN|CODE_SERVER_PASSWORD|VNC_PASSWORD|password|secret)[[:space:]]*[:=][[:space:]]*)[^[:space:]"'\'';]+#\1<redacted>#gI'
}

{
    echo "########################################################################"
    echo "# developer-infra Supervisor Log Bundle"
    echo "# Scope    : ${SCOPE}"
    echo "# Packages : ${SELECTED[*]}"
    echo "# Tail     : ${LINES} lines per file"
    echo "# Created  : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "########################################################################"
    echo ""
} > "$OUT_FILE"

CAPTURED=0
PKG_IDX=0
PKG_TOTAL="${#SELECTED[@]}"
for pkg in "${SELECTED[@]}"; do
    PKG_IDX=$((PKG_IDX + 1))
    echo "  .. [collect-logs ${PKG_IDX}/${PKG_TOTAL}] Reading ${pkg} (out + err, tail=${LINES})..."
    for stream in out err; do
        log_path="/var/log/supervisor/${pkg}.${stream}.log"
        now_str="$(date '+%Y-%m-%d %H:%M:%S')"
        content="$(docker exec -u root "$CONTAINER_ID" bash -c \
            "if [ -f '${log_path}' ]; then if [ -s '${log_path}' ]; then tail -n ${LINES} '${log_path}'; else echo '(file exists, empty)'; fi; else echo '(file not found)'; fi" \
            2>&1 | redact_stream || true)"

        {
            echo "========================================================================"
            echo "[LOG APPENDED] ${log_path}  (tail -n ${LINES})"
            echo "Package  : ${pkg} | Stream: ${stream} | Captured: ${now_str}"
            echo "========================================================================"
            printf '%s\n\n' "$content"
        } >> "$OUT_FILE"
        CAPTURED=$((CAPTURED + 1))
    done
done

ABS_OUT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUT_FILE" 2>/dev/null || printf '%s' "$OUT_FILE")"
echo "[collect-logs] Collected ${CAPTURED} log streams (${SCOPE}, tail=${LINES})."
echo "[collect-logs] Saved to: ${ABS_OUT}"
