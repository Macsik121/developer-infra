#!/usr/bin/env bash
# Preflight, port-conflict diagnostics & launch script for Linux Desktop / Remote Linux Server (D1, D2, D9, Patch v2.1).
# Usage:
#   ./run-env.sh                      # starts headless/noVNC profile and opens bash
#   ./run-env.sh --check-ports        # inspect port availability/owners & host VPN status
#   ./run-env.sh --auto-port          # auto-increment conflicting host ports (+1)
#   ./run-env.sh --detach             # starts container without attaching shell
#   ./run-env.sh --env-file .env.dev2 # multi-instance launch
set -euo pipefail

ENV_FILE=".env"
MODE="headless"
PROFILE=""
DETACH=0
NO_BUILD=0
CHECK_PORTS=0
AUTO_PORT=0

usage() {
    cat <<EOF
Usage: ./run-env.sh [OPTIONS]

Options:
  --mode <headless|wslg>   Compose display profile (default: headless)
  --profile <lite|full>    Build target: 'lite' (fast VPN + Chromium check) or 'full' (IDE + AI stack; default from .env or full)
  --env-file <path>        Path to .env file (default: .env)
  --check-ports            Inspect host port availability / owners & host VPN status, then exit
  --auto-port              Automatically increment (+1) conflicting host ports until free
  --detach, -d             Start container without attaching interactive shell
  --no-build               Skip --build on docker compose up
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)        MODE="${2:-}"; shift 2 ;;
        --profile)     PROFILE="${2:-}"; shift 2 ;;
        --env-file)    ENV_FILE="${2:-}"; shift 2 ;;
        --check-ports) CHECK_PORTS=1; shift ;;
        --auto-port)   AUTO_PORT=1; shift ;;
        -d|--detach)   DETACH=1; shift ;;
        --no-build)    NO_BUILD=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$MODE" in
    headless|wslg) ;;
    *) echo "ERROR: --mode must be 'headless' or 'wslg'." >&2; exit 1 ;;
esac

# 1. Preflight: Docker & Compose v2
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker CLI not found." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: Docker daemon is not reachable." >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: Docker Compose v2 is required." >&2; exit 1; }

# 2. Preflight: .env & mandatory strong passwords (D9)
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: ${ENV_FILE} not found. Run: cp .env.example ${ENV_FILE}" >&2
    exit 1
fi

get_env_val() {
    local key="$1"
    grep -E "^${key}=" "$ENV_FILE" | tail -n 1 | cut -d'=' -f2- | tr -d '\r' | sed -E 's/^["'\'']|["'\'']$//g' || true
}

is_weak() {
    local val="${1:-}"
    [[ -z "$val" || ${#val} -lt 6 ]] && return 0
    case "${val,,}" in
        change_me*|devpassword123|password|123456|12345678|admin) return 0 ;;
    esac
    return 1
}

if [[ "$CHECK_PORTS" -eq 0 ]]; then
    CODE_PW="$(get_env_val CODE_SERVER_PASSWORD)"
    VNC_PW="$(get_env_val VNC_PASSWORD)"
    if is_weak "$CODE_PW"; then
        echo "ERROR: Set a strong CODE_SERVER_PASSWORD (>=6 chars, no CHANGE_ME) in ${ENV_FILE}." >&2
        exit 1
    fi
    if is_weak "$VNC_PW"; then
        echo "ERROR: Set a strong VNC_PASSWORD (>=6 chars, no CHANGE_ME) in ${ENV_FILE}." >&2
        exit 1
    fi
fi

PROJECT_NAME="$(get_env_val COMPOSE_PROJECT_NAME)"; PROJECT_NAME="${PROJECT_NAME:-devbox-main}"
BIND_HOST="$(get_env_val BIND_HOST)"; BIND_HOST="${BIND_HOST:-127.0.0.1}"
TEST_BIND_ADDR="$BIND_HOST"
[[ "$TEST_BIND_ADDR" == "0.0.0.0" || "$TEST_BIND_ADDR" == "::" ]] && TEST_BIND_ADDR="127.0.0.1"
CODE_PORT="$(get_env_val CODE_SERVER_PORT)"; CODE_PORT="${CODE_PORT:-8080}"
NOVNC_PORT="$(get_env_val NOVNC_PORT)"; NOVNC_PORT="${NOVNC_PORT:-6901}"
OMNI_PORT="$(get_env_val OMNIROUTE_PORT)"; OMNI_PORT="${OMNI_PORT:-20128}"
WORKSPACE_DIR="$(get_env_val WORKSPACE_DIR)"; WORKSPACE_DIR="${WORKSPACE_DIR:-./workspace}"
if [[ -z "$PROFILE" ]]; then
    PROFILE="$(get_env_val DEV_INFRA_PROFILE)"
    PROFILE="${PROFILE:-full}"
fi
PROFILE="${PROFILE,,}"
case "$PROFILE" in
    lite|full) ;;
    *) echo "ERROR: --profile / DEV_INFRA_PROFILE must be 'lite' or 'full'." >&2; exit 1 ;;
esac

# 3. Host VPN / TUN detection (non-blocking advisory)
if command -v ip >/dev/null 2>&1; then
    HOST_TUN="$(ip route show default 2>/dev/null | grep -Eo 'dev[[:space:]]+(tun[0-9a-zA-Z_-]*|wg[0-9a-zA-Z_-]*|sing[0-9a-zA-Z_-]*|utun[0-9a-zA-Z_-]*)' | head -n 1 || true)"
    if [[ -n "$HOST_TUN" ]]; then
        echo "[run-env] Notice: Active host VPN/TUN detected (${HOST_TUN})."
        echo "          Container uses its own isolated sing-box TUN (MTU 1280 + TCP pre-probe)."
        echo "          Tip: if upstream blocks double-VPN, switch via ./vpn-ctl.sh proxy or ./vpn-ctl.sh direct."
    fi
fi

# 4. Port preflight & developer-infra ownership lookup
MANAGED_CONTAINERS="$(docker ps --filter 'label=dev.infra.managed=true' --format '{{.Names}}|{{.Label "dev.infra.project"}}|{{.Ports}}' 2>/dev/null || true)"

test_port_free() {
    local addr="$1"
    local port="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.bind((sys.argv[1],int(sys.argv[2]))); s.close()' "$addr" "$port" 2>/dev/null
        return $?
    fi
    if command -v ss >/dev/null 2>&1; then
        ! ss -H -tln "sport = :${port}" 2>/dev/null | grep -q .
        return $?
    fi
    return 0
}

describe_port_owner() {
    local port="$1"
    local line name proj ports
    while IFS='|' read -r name proj ports; do
        [[ -n "$name" ]] || continue
        if [[ "$ports" == *":${port}->"* ]]; then
            if [[ "$proj" == "$PROJECT_NAME" ]]; then
                echo "OWN|own developer-infra container (${name})"
                return 0
            fi
            echo "OTHER|developer-infra instance '${proj}' (${name})"
            return 0
        fi
    done <<< "$MANAGED_CONTAINERS"

    if command -v ss >/dev/null 2>&1; then
        local proc_info
        proc_info="$(ss -H -tlnp "sport = :${port}" 2>/dev/null | head -n 1 || true)"
        if [[ -n "$proc_info" ]]; then
            echo "OTHER|host listener (${proc_info})"
            return 0
        fi
    fi
    echo "OTHER|port busy or restricted on ${BIND_HOST}:${port}"
}

CHOSEN_PORTS=" "
HAS_CONFLICT=0

resolve_port() {
    local svc="$1"
    local key="$2"
    local desired="$3"
    local result_var="$4"

    if test_port_free "$TEST_BIND_ADDR" "$desired" && [[ "$CHOSEN_PORTS" != *" ${desired} "* ]]; then
        CHOSEN_PORTS="${CHOSEN_PORTS}${desired} "
        printf -v "$result_var" '%s' "$desired"
        [[ "$CHECK_PORTS" -eq 1 ]] && printf '  [FREE]     %-12s %s:%s\n' "$svc" "$BIND_HOST" "$desired"
        return 0
    fi

    local owner_raw owner_kind owner_desc
    owner_raw="$(describe_port_owner "$desired")"
    owner_kind="${owner_raw%%|*}"
    owner_desc="${owner_raw#*|}"

    if [[ "$owner_kind" == "OWN" ]] && [[ "$CHOSEN_PORTS" != *" ${desired} "* ]]; then
        CHOSEN_PORTS="${CHOSEN_PORTS}${desired} "
        printf -v "$result_var" '%s' "$desired"
        [[ "$CHECK_PORTS" -eq 1 ]] && printf '  [OWN]      %-12s %s:%s -> %s\n' "$svc" "$BIND_HOST" "$desired" "$owner_desc"
        return 0
    fi

    if [[ "$AUTO_PORT" -eq 1 ]] && [[ "$CHECK_PORTS" -eq 0 ]]; then
        local cand
        for (( cand = desired + 1; cand <= desired + 100; cand++ )); do
            (( cand > 65535 )) && break
            [[ "$CHOSEN_PORTS" == *" ${cand} "* ]] && continue
            if test_port_free "$TEST_BIND_ADDR" "$cand"; then
                CHOSEN_PORTS="${CHOSEN_PORTS}${cand} "
                printf -v "$result_var" '%s' "$cand"
                export "${key}=${cand}"
                echo "[run-env] Port conflict on ${BIND_HOST}:${desired} (${owner_desc}) -> auto-shifted ${key} to ${cand}"
                return 0
            fi
        done
    fi

    HAS_CONFLICT=1
    printf -v "$result_var" '%s' "$desired"
    printf '  [CONFLICT] %-12s %s:%s -> %s\n' "$svc" "$BIND_HOST" "$desired" "$owner_desc"
}

resolve_port "code-server" "CODE_SERVER_PORT" "$CODE_PORT" CODE_PORT
resolve_port "noVNC"       "NOVNC_PORT"       "$NOVNC_PORT" NOVNC_PORT
resolve_port "OmniRoute"   "OMNIROUTE_PORT"   "$OMNI_PORT" OMNI_PORT

if [[ "$CHECK_PORTS" -eq 1 ]]; then
    if [[ "$HAS_CONFLICT" -eq 1 ]]; then
        echo ""
        echo "Fix: run './run-env.sh --auto-port' or update conflicting ports in ${ENV_FILE}." >&2
        exit 1
    fi
    echo ""
    echo "All configured host ports are ready for project '${PROJECT_NAME}'."
    exit 0
fi

if [[ "$HAS_CONFLICT" -eq 1 ]]; then
    echo "" >&2
    echo "ERROR: Host port conflict detected. Re-run with './run-env.sh --auto-port' or change ports in ${ENV_FILE}." >&2
    exit 1
fi

mkdir -p "$WORKSPACE_DIR"

COMPOSE_FILES=(-f docker-compose.yaml)
if [[ "$MODE" == "wslg" ]]; then
    COMPOSE_FILES+=(-f docker-compose.wslg.yaml)
else
    COMPOSE_FILES+=(-f docker-compose.headless.yaml)
fi

UP_ARGS=(up -d)
[[ "$NO_BUILD" -eq 0 ]] && UP_ARGS+=(--build)

export DEV_INFRA_PROFILE="$PROFILE"
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

echo "[run-env] Starting developer-infra (mode=${MODE}, profile=${PROFILE}, env=${ENV_FILE})..."
docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" "${UP_ARGS[@]}"

echo ""
if [[ "$PROFILE" == "lite" ]]; then
    echo "Ready (profile=lite: VPN + Chromium verification build):"
    echo "  noVNC       : http://${BIND_HOST}:${NOVNC_PORT}/vnc.html"
    echo "  VPN status  : ./vpn-ctl.sh status  (in Chromium: http://127.0.0.1:9099)"
    echo "  Diagnostics : ./diag-env.sh"
    echo "  Upgrade full: ./run-env.sh --profile full --auto-port"
else
    echo "Ready (profile=full):"
    echo "  code-server : http://${BIND_HOST}:${CODE_PORT}"
    echo "  noVNC       : http://${BIND_HOST}:${NOVNC_PORT}/vnc.html"
    echo "  OmniRoute   : http://${BIND_HOST}:${OMNI_PORT}"
    echo "  VPN status  : ./vpn-ctl.sh status  (in Chromium: http://127.0.0.1:9099)"
    echo "  Claude Code : docker compose --env-file ${ENV_FILE} exec -it -u coder ubuntu-dev start-claude"
fi
echo ""

if [[ "$DETACH" -eq 0 ]]; then
    exec docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" exec -it -u coder -w /home/coder/workspace ubuntu-dev bash
fi