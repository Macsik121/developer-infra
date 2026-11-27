#!/usr/bin/env bash
# End-to-end runtime smoke test for developer-infra (run on host after `run-env`).
# Usage:
#   ./scripts/smoke-test.sh
#   ./scripts/smoke-test.sh --env-file .env.dev2 --test-killswitch
set -euo pipefail

ENV_FILE=".env"
TEST_KILLSWITCH=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)        ENV_FILE="${2:-.env}"; shift 2 ;;
        --test-killswitch) TEST_KILLSWITCH=1; shift ;;
        -h|--help)
            echo "Usage: ./scripts/smoke-test.sh [--env-file .env] [--test-killswitch]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

PASS=0
FAIL=0

pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

dc_root() {
    docker compose --env-file "$ENV_FILE" exec -T -u root ubuntu-dev "$@"
}

dc_coder() {
    docker compose --env-file "$ENV_FILE" exec -T -u coder ubuntu-dev "$@"
}

echo "=== developer-infra Smoke Test (env=${ENV_FILE}) ==="

# 1. Container running
if docker compose --env-file "$ENV_FILE" ps --status running --services | grep -qx "ubuntu-dev"; then
    pass "Service ubuntu-dev is running"
else
    fail "Service ubuntu-dev is NOT running"
    exit 1
fi

# 2. Supervisor core services & display-aware GUI checks
ACTIVE_DISPLAY="$(dc_coder /usr/local/lib/dev-infra/display-detect.sh 2>/dev/null | tr -d '\r\n' || echo ":99")"
CONTAINER_PROFILE="$(dc_coder printenv DEV_INFRA_PROFILE 2>/dev/null | tr -d '\r\n' | tr '[:upper:]' '[:lower:]' || echo "full")"
[[ "$CONTAINER_PROFILE" == "lite" || "$CONTAINER_PROFILE" == "full" ]] || CONTAINER_PROFILE="full"
SUP_OUT="$(dc_root supervisorctl status 2>&1 || true)"

if [[ "$CONTAINER_PROFILE" == "lite" ]]; then
    CORE_SVCS=(vpn-sub-updater sing-box vpn-status vpn-watchdog)
else
    CORE_SVCS=(vpn-sub-updater sing-box vpn-status vpn-watchdog code-server omniroute)
fi

for svc in "${CORE_SVCS[@]}"; do
    if echo "$SUP_OUT" | grep -E "^${svc}[[:space:]]+RUNNING" >/dev/null; then
        pass "supervisord core service '${svc}' is RUNNING (profile=${CONTAINER_PROFILE})"
    else
        fail "supervisord core service '${svc}' is NOT RUNNING (profile=${CONTAINER_PROFILE})"
    fi
done

if [[ "$ACTIVE_DISPLAY" == ":0" ]]; then
    for svc in xvfb fluxbox x11vnc novnc; do
        if echo "$SUP_OUT" | grep -E "^${svc}[[:space:]]+FATAL" >/dev/null; then
            fail "WSLg mode (:0): '${svc}' entered FATAL state (expected clean EXITED)"
        else
            pass "WSLg mode (:0): fallback service '${svc}' cleanly skipped (no FATAL)"
        fi
    done
else
    for svc in x11vnc novnc; do
        if echo "$SUP_OUT" | grep -E "^${svc}[[:space:]]+RUNNING" >/dev/null; then
            pass "Headless mode (:99): '${svc}' is RUNNING"
        else
            fail "Headless mode (:99): '${svc}' is NOT RUNNING"
        fi
    done
fi

# 3. TUN interface, VPN Status API & live VPN egress
if dc_root ip link show sing-tun >/dev/null 2>&1; then
    pass "sing-tun interface is UP"
else
    fail "sing-tun interface is DOWN"
fi

if ST_JSON="$(dc_coder curl -fsS --max-time 5 http://127.0.0.1:9099/api/status 2>/dev/null)" && printf '%s' "$ST_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "mode" in d and "state" in d' 2>/dev/null; then
    pass "Internal VPN Status Dashboard API responds on 127.0.0.1:9099"
else
    fail "Internal VPN Status Dashboard API (127.0.0.1:9099/api/status) failed"
fi

if IP_JSON="$(dc_coder curl -fsS --max-time 8 https://ipinfo.io 2>/dev/null)"; then
    COUNTRY="$(printf '%s' "$IP_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("country","?"))' 2>/dev/null || echo "?")"
    pass "Egress reachable via VPN (country=${COUNTRY})"
else
    fail "Egress check (https://ipinfo.io) failed"
fi

# 4. Local services inside container
if [[ "$CONTAINER_PROFILE" == "lite" ]]; then
    pass "lite profile active — code-server and OmniRoute intentionally skipped"
else
    if dc_coder curl -fsS --max-time 3 http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
        pass "code-server /healthz responds on 8080"
    else
        fail "code-server /healthz did not respond"
    fi
fi

if [[ "$ACTIVE_DISPLAY" != ":0" ]]; then
    if dc_coder curl -fsS --max-time 3 http://127.0.0.1:6080/vnc.html >/dev/null 2>&1; then
        pass "noVNC serves /vnc.html on 6080"
    else
        fail "noVNC did not respond on 6080"
    fi
else
    pass "WSLg mode (:0) active — noVNC skipped as designed"
fi

if [[ "$CONTAINER_PROFILE" != "lite" ]]; then
    OMNI_PORT="$(grep -E '^OMNIROUTE_PORT=' "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2- | tr -d '\r' || true)"
    OMNI_PORT="${OMNI_PORT:-20128}"
    if dc_coder curl -fsS --max-time 3 "http://127.0.0.1:${OMNI_PORT}" >/dev/null 2>&1; then
        pass "Supervised OmniRoute responds on ${OMNI_PORT}"
    else
        fail "OmniRoute did not respond on ${OMNI_PORT}"
    fi
fi

# 5. Security hardening checks (D8, D9)
if dc_coder bash -c 'command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1'; then
    fail "coder unexpectedly has passwordless sudo!"
else
    pass "coder has no passwordless sudo (D8)"
fi

if dc_coder env | grep -Eq '^(VPN_SUBSCRIPTION_URL|VNC_PASSWORD|CODE_SERVER_PASSWORD)='; then
    fail "Secret environment variable leaked into coder shell!"
else
    pass "Secret env vars purged before supervisord/coder (D8)"
fi

if dc_coder test -r /run/vpn/subscription_url -o -r /run/vpn/clash_secret -o -r /run/vnc/passwd -o -r /var/lib/sing-box/config.active.json; then
    fail "coder can read root-only secret files!"
else
    pass "Root-only secrets (/run/vpn/*, /run/vnc/passwd, /var/lib/sing-box) blocked from coder (D8)"
fi

if dc_coder vpn-ctl status >/dev/null 2>&1; then
    pass "coder can run read-only 'vpn-ctl status'"
else
    fail "coder failed to run 'vpn-ctl status'"
fi

if dc_coder vpn-ctl direct >/dev/null 2>&1; then
    fail "coder was able to mutate kill-switch ('vpn-ctl direct')!"
else
    pass "coder is blocked from mutating kill-switch (D8)"
fi

# 6. Optional destructive kill-switch verification (D6, ST-LIVE-7)
if [[ "$TEST_KILLSWITCH" -eq 1 ]]; then
    echo "--- Running strict kill-switch + Docker DNS leak test ---"
    dc_root /usr/local/bin/vpn-ctl strict >/dev/null
    dc_root supervisorctl stop sing-box >/dev/null
    sleep 2
    if dc_coder curl -fsS --max-time 3 https://1.1.1.1 >/dev/null 2>&1; then
        fail "Kill-switch LEAKED IPv4 traffic while sing-box was stopped!"
    else
        pass "Kill-switch blocked direct IPv4 egress while sing-box was stopped"
    fi
    if dc_coder python3 -c 'import socket; socket.setdefaulttimeout(2); socket.getaddrinfo("example.com", 443)' >/dev/null 2>&1; then
        fail "Kill-switch LEAKED DNS resolution via 127.0.0.11 while sing-box was stopped!"
    else
        pass "Kill-switch blocked DNS resolution (no 127.0.0.11 NAT bypass) while sing-box was stopped"
    fi
    LOCAL_HEALTH_URL="http://127.0.0.1:8080/healthz"
    [[ "$CONTAINER_PROFILE" == "lite" ]] && LOCAL_HEALTH_URL="http://127.0.0.1:9099/healthz"
    if dc_coder curl -fsS --max-time 3 "$LOCAL_HEALTH_URL" >/dev/null 2>&1; then
        pass "Local service (${LOCAL_HEALTH_URL}) remained reachable while kill-switch was active"
    else
        fail "Local service (${LOCAL_HEALTH_URL}) became unreachable during kill-switch"
    fi
    dc_root supervisorctl start sing-box >/dev/null
    sleep 4
    if dc_root ip link show sing-tun >/dev/null 2>&1; then
        pass "sing-tun recovered after restart"
    else
        fail "sing-tun failed to recover after restart"
    fi
fi

echo ""
echo "=== Summary: PASS=${PASS} FAIL=${FAIL} ==="
[[ "$FAIL" -eq 0 ]]
