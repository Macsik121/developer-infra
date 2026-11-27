#!/usr/bin/env bash
# Full end-to-end system diagnostic & audit suite for developer-infra (Linux / macOS / WSL).
# Collects supervisor status, layered L3/DNS/L7 network probes, vpn-ctl + redacted config audit,
# and supervisor logs via collect-logs.sh into diagnostics/diag-<timestamp>/.
#
# Usage:
#   ./diag-env.sh
#   ./diag-env.sh --log-scope vpn --lines 50
#   ./diag-env.sh --log-scope ask
#   ./diag-env.sh --skip-retest
set -euo pipefail

ENV_FILE=".env"
LOG_SCOPE="all"
LINES=50
SKIP_RETEST=0

usage() {
    cat <<EOF
Usage: ./diag-env.sh [OPTIONS]

Options:
  --env-file <path>                        Path to .env file (default: .env)
  --log-scope <all|vpn|gui|dev|pkg|ask>    Logs passed to collect-logs.sh (default: all; 'ask' opens menu)
  --lines <N>                              Tail lines per supervisor log file (default: 50)
  --skip-retest                            Skip 'vpn-ctl retest' latency sweep
  -h, --help                               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)    ENV_FILE="${2:-.env}"; shift 2 ;;
        --log-scope)   LOG_SCOPE="${2:-all}"; shift 2 ;;
        --lines)       LINES="${2:-50}"; shift 2 ;;
        --skip-retest) SKIP_RETEST=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker CLI not found." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: Env file '${ENV_FILE}' not found." >&2; exit 1; }

OMNI_PORT="$(grep -E '^OMNIROUTE_PORT=' "$ENV_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2- | tr -d '\r' || true)"
OMNI_PORT="${OMNI_PORT:-20128}"

TS="$(date +%Y%m%d-%H%M%S)"
BUNDLE_DIR="$(pwd)/diagnostics/diag-${TS}"
mkdir -p "$BUNDLE_DIR"

SUMMARY_FILE="${BUNDLE_DIR}/00-summary.txt"
SVC_FILE="${BUNDLE_DIR}/01-services.txt"
NET_FILE="${BUNDLE_DIR}/02-network-audit.txt"
VPN_FILE="${BUNDLE_DIR}/03-vpn-audit.txt"
if [[ "$LOG_SCOPE" == "ask" ]]; then
    LOG_FILENAME="04-logs-selected.log"
else
    LOG_FILENAME="04-logs-${LOG_SCOPE}.log"
fi
LOGS_FILE="${BUNDLE_DIR}/${LOG_FILENAME}"

redact_text() {
    sed -E \
        -e 's#(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]"'\'']+#\1<redacted>#gI' \
        -e 's#(https?://[^/[:space:]]+/sub/)[^[:space:]"'\'']+#\1<redacted>#gI' \
        -e 's#((VPN_SUBSCRIPTION_URL|ANTHROPIC_AUTH_TOKEN|CODE_SERVER_PASSWORD|VNC_PASSWORD|password|secret)[[:space:]]*[:=][[:space:]]*)[^[:space:]"'\'';]+#\1<redacted>#gI'
}

append_section() {
    local target="$1"
    local title="$2"
    local body="$3"
    {
        echo "========================================================================"
        echo "[${title}]"
        echo "Captured: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================================================"
        printf '%s\n\n' "$body" | redact_text
    } >> "$target"
}

SUMMARY_ROWS=()
HINTS=()

step_msg() {
    echo "  .. $1"
}

record_check() {
    local status="$1"
    local name="$2"
    local detail="$3"
    SUMMARY_ROWS+=("$(printf '  [%-4s] %-34s %s' "$status" "$name" "$detail")")
    printf '  [%-4s] %-32s %s\n' "$status" "$name" "$detail"
}

echo ""
echo "=== developer-infra Full System Diagnostic ==="
echo "Bundle directory: ${BUNDLE_DIR}"
echo ""

# 1. Container & Supervisor Status
echo "[1/4] Checking Docker & supervisorctl status..."
step_msg "[1/4.1] Running docker compose ps & resolving container ID..."
PS_ERR_TMP="$(mktemp)"
PS_OUT="$(docker compose --env-file "$ENV_FILE" ps -a 2>"$PS_ERR_TMP" || true)"
PS_ERR="$(cat "$PS_ERR_TMP" 2>/dev/null || true)"
rm -f "$PS_ERR_TMP"
append_section "$SVC_FILE" "docker compose ps -a" "${PS_OUT}"$'\n'"${PS_ERR}"

if printf '%s' "$PS_ERR" | grep -q 'variable is not set'; then
    record_check "WARN" ".env variable interpolation" "Unescaped \$var detected in ${ENV_FILE} (Compose replaces it with blank!)"
    HINTS+=("Your ${ENV_FILE} contains an unescaped \$var (likely inside a password). Escape \$ as \$\$ in .env.")
fi

CONTAINER_ID="$(docker compose --env-file "$ENV_FILE" ps --status running -q ubuntu-dev 2>/dev/null | head -n 1 | tr -d '\r\n' || true)"
if [[ -z "$CONTAINER_ID" ]]; then
    record_check "FAIL" "Container ubuntu-dev" "NOT RUNNING (start with ./run-env.sh --auto-port)"
    printf 'Container ubuntu-dev is not running.\nSee: %s\n' "$SVC_FILE" > "$SUMMARY_FILE"
    echo "Created files: ${SUMMARY_FILE}, ${SVC_FILE}"
    exit 1
fi
record_check "PASS" "Container ubuntu-dev" "running (id=${CONTAINER_ID:0:12})"

step_msg "[1/4.2] Running supervisorctl status..."
SUP_OUT="$(docker exec -u root "$CONTAINER_ID" supervisorctl status 2>&1 || true)"
append_section "$SVC_FILE" "supervisorctl status" "$SUP_OUT"

step_msg "[1/4.3] Checking active DISPLAY & locale..."
ACTIVE_DISP="$(docker exec -u coder "$CONTAINER_ID" /usr/local/lib/dev-infra/display-detect.sh 2>/dev/null | tr -d '\r\n' || echo "unknown")"
LOCALE_OUT="$(docker exec -u coder "$CONTAINER_ID" locale 2>&1 || true)"
append_section "$SVC_FILE" "Active DISPLAY & Locale" "DISPLAY=${ACTIVE_DISP}"$'\n'"${LOCALE_OUT}"

CORE_DOWN=()
for svc in vpn-sub-updater sing-box vpn-status vpn-watchdog code-server omniroute; do
    if ! printf '%s\n' "$SUP_OUT" | grep -Eq "^${svc}[[:space:]]+RUNNING"; then
        CORE_DOWN+=("$svc")
    fi
done
if [[ ${#CORE_DOWN[@]} -eq 0 ]]; then
    record_check "PASS" "supervisord services" "All core services RUNNING (DISPLAY=${ACTIVE_DISP})"
else
    record_check "FAIL" "supervisord core services" "Not RUNNING: ${CORE_DOWN[*]}"
fi

# 2. Layered Network Audit
echo "[2/4] Running layered network audit (L3/DNS/L7 TUN/Proxy)..."
step_msg "[2/4.1] Inspecting interfaces, ip rule, ip route, /etc/resolv.conf & iptables DEVINFRA_KS..."
NET_ROUTE_OUT="$(docker exec -i -u root "$CONTAINER_ID" bash -s <<'BASHEOF' 2>&1 || true
echo "--- ip -br addr ---"; ip -br addr 2>&1 || true
echo ""; echo "--- ip link show sing-tun ---"; ip link show sing-tun 2>&1 || true
echo ""; echo "--- ip rule list ---"; ip rule list 2>&1 || true
echo ""; echo "--- ip route show table main ---"; ip route show table main 2>&1 || true
echo ""; echo "--- ip route show table all (top 35) ---"; ip route show table all 2>&1 | head -n 35 || true
echo ""; echo "--- /etc/resolv.conf ---"; cat /etc/resolv.conf 2>&1 || true
echo ""; echo "--- iptables DEVINFRA_KS ---"
(iptables-nft -S DEVINFRA_KS 2>/dev/null || iptables-legacy -S DEVINFRA_KS 2>/dev/null || iptables -S DEVINFRA_KS 2>/dev/null || echo "(no DEVINFRA_KS chain)")
BASHEOF
)"
append_section "$NET_FILE" "Routing, DNS & Firewall (DEVINFRA_KS)" "$NET_ROUTE_OUT"

if printf '%s' "$NET_ROUTE_OUT" | grep -q "sing-tun:"; then
    record_check "PASS" "TUN interface (sing-tun)" "UP"
    ETH0_GW="$(printf '%s\n' "$NET_ROUTE_OUT" | sed -nE 's/^default via ([0-9.]+) dev eth0.*/\1/p' | head -n 1)"
    TUN_IP="$(printf '%s\n' "$NET_ROUTE_OUT" | sed -nE 's/^sing-tun[[:space:]]+[^[:space:]]+[[:space:]]+([0-9.]+)\/.*/\1/p' | head -n 1)"
    if [[ -n "$ETH0_GW" ]] && [[ "$ETH0_GW" == "$TUN_IP" ]]; then
        record_check "FAIL" "TUN / eth0 subnet collision" "CRITICAL: sing-tun stole Docker gateway IP ${ETH0_GW}!"
        HINTS+=("CRITICAL: sing-tun IP (${TUN_IP}) collides with Docker eth0 gateway (${ETH0_GW}), blackholing ALL outbound traffic! Rebuild v2.2.2+ image (uses 198.18.0.1/30 & auto-heals persisted volumes).")
    fi
else
    record_check "FAIL" "TUN interface (sing-tun)" "DOWN"
fi

if printf '%s' "$NET_ROUTE_OUT" | grep -Eq "fwmark 0xff.*lookup main"; then
    record_check "PASS" "Policy routing (fwmark 0xff)" "ip rule fwmark 0xff lookup main present"
else
    record_check "WARN" "Policy routing (fwmark 0xff)" "Missing 'fwmark 0xff lookup main' rule"
    HINTS+=("Missing ip rule 'fwmark 0xff lookup main'. Ensure v2.1+ image is built and run ./vpn-ctl.sh strict.")
fi

PING_LOG=""
PING_OK=0
GVISOR_ECHO=0
P_IDX=0
for t in 1.1.1.1 8.8.8.8 google.com github.com; do
    P_IDX=$((P_IDX + 1))
    step_msg "[2/4.2] ICMP ping (${P_IDX}/4): ${t} (timeout 2s)..."
    p_out="$(docker exec -u coder "$CONTAINER_ID" ping -4 -c 2 -W 2 "$t" 2>&1)" && p_rc=0 || p_rc=$?
    PING_LOG+=">>> ping -4 -c 2 -W 2 ${t} (exit=${p_rc})"$'\n'"${p_out}"$'\n\n'
    if [[ "$p_rc" -eq 0 ]]; then
        PING_OK=$((PING_OK + 1))
        if printf '%s' "$p_out" | grep -Eq 'time=0\.[0-9]+[[:space:]]*ms'; then
            GVISOR_ECHO=1
        fi
    fi
done
if [[ "$GVISOR_ECHO" -eq 1 ]]; then
    PING_LOG+="[DIAG NOTE] Sub-1ms ping RTT detected! sing-box stack=gvisor replies to ICMP locally; ping PASS does NOT prove upstream proxy works."$'\n'
    record_check "PASS" "ICMP ping (IPv4)" "${PING_OK}/4 ok (sub-1ms gVisor local echo - NOT L7 proof)"
else
    record_check "$([[ "$PING_OK" -gt 0 ]] && echo PASS || echo FAIL)" "ICMP ping (IPv4)" "${PING_OK}/4 reachable"
fi
append_section "$NET_FILE" "ICMP Ping Tests (IPv4)" "$PING_LOG"

step_msg "[2/4.3] Testing DNS resolution (getent ahosts google.com ipinfo.io)..."
DNS_OUT="$(docker exec -u coder "$CONTAINER_ID" getent ahosts google.com ipinfo.io 2>&1)" && DNS_RC=0 || DNS_RC=$?
append_section "$NET_FILE" "DNS Resolution (getent ahosts)" "$DNS_OUT"
if [[ "$DNS_RC" -eq 0 ]]; then
    record_check "PASS" "DNS resolution" "Resolved google.com / ipinfo.io"
else
    record_check "FAIL" "DNS resolution" "Failed to resolve hostnames"
fi

step_msg "[2/4.4] Testing L7 HTTPS via TUN (curl https://ipinfo.io/json, timeout 7s)..."
CURL_TUN="$(docker exec -u coder "$CONTAINER_ID" curl -4 -sS -v --max-time 7 https://ipinfo.io/json 2>&1)" && TUN_RC=0 || TUN_RC=$?
append_section "$NET_FILE" "L7 HTTPS via TUN (curl https://ipinfo.io/json)" "exit=${TUN_RC}"$'\n'"${CURL_TUN}"
L7_TUN_OK=0
if [[ "$TUN_RC" -eq 0 ]] && printf '%s' "$CURL_TUN" | grep -q '"ip"'; then
    L7_TUN_OK=1
    record_check "PASS" "L7 HTTPS via TUN (ipinfo.io)" "OK"
else
    record_check "FAIL" "L7 HTTPS via TUN (ipinfo.io)" "FAILED (exit=${TUN_RC}) - see 02-network-audit.txt"
fi

step_msg "[2/4.5] Testing L7 HTTPS via internal proxy 127.0.0.1:2080 (timeout 7s)..."
CURL_PRX="$(docker exec -u coder "$CONTAINER_ID" curl -4 -sS --proxy http://127.0.0.1:2080 --max-time 7 https://ipinfo.io/json 2>&1)" && PRX_RC=0 || PRX_RC=$?
append_section "$NET_FILE" "L7 HTTPS via internal proxy (127.0.0.1:2080)" "exit=${PRX_RC}"$'\n'"${CURL_PRX}"
L7_PRX_OK=0
if [[ "$PRX_RC" -eq 0 ]] && printf '%s' "$CURL_PRX" | grep -q '"ip"'; then
    L7_PRX_OK=1
    record_check "PASS" "L7 HTTPS via proxy :2080" "OK"
else
    record_check "WARN" "L7 HTTPS via proxy :2080" "FAILED (exit=${PRX_RC})"
fi

step_msg "[2/4.6] Checking local loopback services (8080 / 9099 / ${OMNI_PORT})..."
LOCAL_OUT="$(docker exec -u coder "$CONTAINER_ID" bash -c \
    "printf 'code-server(8080): '; curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1 && echo OK || echo FAIL; printf 'vpn-status(9099): '; (curl -fsS --max-time 2 http://127.0.0.1:9099/healthz >/dev/null 2>&1 || curl -fsS --max-time 6 'http://127.0.0.1:9099/api/status?fast=1' >/dev/null 2>&1) && echo OK || echo FAIL; printf 'omniroute(${OMNI_PORT}): '; curl -fsS --max-time 2 http://127.0.0.1:${OMNI_PORT} >/dev/null 2>&1 && echo OK || echo FAIL" \
    2>&1 || true)"
append_section "$NET_FILE" "Internal Loopback Services" "$LOCAL_OUT"
record_check "$(printf '%s' "$LOCAL_OUT" | grep -q 'code-server(8080):.*OK' && echo PASS || echo FAIL)" "Local services (8080/9099/${OMNI_PORT})" "$(printf '%s' "$LOCAL_OUT" | tr '\n' ' ')"

# 3. VPN-CTL & Redacted Active Config + Direct SO_MARK=255 Probe
echo "[3/4] Running vpn-ctl audit & direct upstream SO_MARK=255 probe..."
step_msg "[3/4.1] Running vpn-ctl status..."
append_section "$VPN_FILE" "vpn-ctl status" "$(docker exec -u root "$CONTAINER_ID" /usr/local/bin/vpn-ctl status 2>&1 || true)"
step_msg "[3/4.2] Running vpn-ctl select (active node & pool list)..."
append_section "$VPN_FILE" "vpn-ctl select" "$(docker exec -u root "$CONTAINER_ID" /usr/local/bin/vpn-ctl select 2>&1 || true)"
if [[ "$SKIP_RETEST" -eq 0 ]]; then
    step_msg "[3/4.3] Running vpn-ctl retest (Clash API latency sweep, up to 12s)..."
    append_section "$VPN_FILE" "vpn-ctl retest" "$(docker exec -u root "$CONTAINER_ID" /usr/local/bin/vpn-ctl retest 2>&1 || true)"
else
    step_msg "[3/4.3] Skipping vpn-ctl retest (--skip-retest)."
fi

step_msg "[3/4.4] Inspecting config.active.json & probing 5 TCP nodes directly with SO_MARK=255..."
CFG_AUDIT="$(docker exec -i -u root "$CONTAINER_ID" python3 - <<'PYEOF' 2>&1 || true
import json, socket, time
from pathlib import Path

cfg_path = Path("/var/lib/sing-box/config.active.json")
if not cfg_path.is_file():
    print("CONFIG_MISSING=1")
    raise SystemExit(0)

st = cfg_path.stat()
cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
inbounds = cfg.get("inbounds", [])
ib_tags = [i.get("tag") for i in inbounds]
mtu = next((i.get("mtu") for i in inbounds if i.get("type") == "tun"), None)
outbounds = cfg.get("outbounds", [])
proxies = [o for o in outbounds if o.get("type") not in {"selector", "urltest", "direct", "block", "dns"}]
protos = {}
for p in proxies:
    t = p.get("type", "?")
    protos[t] = protos.get(t, 0) + 1

print(f"CONFIG_MTIME={time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(st.st_mtime))}")
print(f"INBOUNDS={ib_tags}")
print(f"TUN_MTU={mtu}")
print(f"PROXY_COUNT={len(proxies)}")
print(f"PROTOCOLS={protos}")
print("FIRST_10_NODES:")
for i, p in enumerate(proxies[:10], 1):
    print(f"  {i:2d}. [{p.get('type')}] {p.get('tag')} -> {p.get('server')}:{p.get('server_port')}")

print("\nDIRECT_TCP_PROBE_WITH_SO_MARK_255 (first 5 TCP nodes):")
tcp_nodes = [p for p in proxies if p.get("type") != "hysteria2"][:5]
ok_cnt = 0
for p in tcp_nodes:
    host, port = p.get("server"), int(p.get("server_port", 443))
    t0 = time.monotonic()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.settimeout(2.5)
        try:
            s.setsockopt(socket.SOL_SOCKET, 36, 255)
        except OSError:
            pass
        s.connect((host, port))
        ms = int((time.monotonic() - t0) * 1000)
        ok_cnt += 1
        print(f"  [OK]   {p.get('tag')} ({host}:{port}) {ms} ms")
    except Exception as e:
        print(f"  [FAIL] {p.get('tag')} ({host}:{port}) -> {e}")
    finally:
        s.close()
print(f"DIRECT_TCP_OK={ok_cnt}/{len(tcp_nodes)}")
PYEOF
)"
append_section "$VPN_FILE" "Redacted config.active.json & Direct SO_MARK=255 Probe" "$CFG_AUDIT"

if printf '%s' "$CFG_AUDIT" | grep -q "TUN_MTU=1400"; then
    record_check "WARN" "Active sing-box config" "Stale v2.0 config detected (MTU=1400)"
    HINTS+=("Stale v2.0 config.active.json in singbox-state volume (MTU=1400). Run ./vpn-ctl.sh update.")
elif printf '%s' "$CFG_AUDIT" | grep -q "PROXY_COUNT="; then
    record_check "PASS" "Active sing-box config" "$(printf '%s\n' "$CFG_AUDIT" | grep -E '^(PROXY_COUNT|DIRECT_TCP_OK)=' | tr '\n' ' ')"
else
    record_check "FAIL" "Active sing-box config" "config.active.json missing or unreadable"
fi

if [[ "$L7_TUN_OK" -eq 0 ]]; then
    if [[ "$L7_PRX_OK" -eq 1 ]]; then
        HINTS+=("Internal proxy 127.0.0.1:2080 WORKS while TUN failed -> try ./vpn-ctl.sh proxy + open-chromium --proxy.")
    elif printf '%s' "$CFG_AUDIT" | grep -q "DIRECT_TCP_OK=0/"; then
        HINTS+=("Direct TCP (SO_MARK=255) failed to ALL tested nodes. Run ./vpn-ctl.sh update or check host VPN.")
    else
        HINTS+=("Inspect ${LOGS_FILE} (sing-box.err.log) and ${VPN_FILE} for TLS/VLESS handshake errors.")
    fi
fi

# 4. Collect Supervisor Logs via collect-logs.sh
echo "[4/4] Collecting supervisor logs via collect-logs.sh..."
if [[ -f "${SCRIPT_DIR}/collect-logs.sh" ]]; then
    COLLECT_ARGS=(--lines "$LINES" --out-file "$LOGS_FILE" --env-file "$ENV_FILE" --container-id "$CONTAINER_ID")
    [[ "$LOG_SCOPE" != "ask" ]] && COLLECT_ARGS+=(--scope "$LOG_SCOPE")
    bash "${SCRIPT_DIR}/collect-logs.sh" "${COLLECT_ARGS[@]}"
    record_check "PASS" "Supervisor logs collected" "Saved to ${LOG_FILENAME}"
else
    record_check "WARN" "Supervisor logs collected" "collect-logs.sh not found next to diag-env.sh"
fi

# 5. Write & Print Final Summary + Exact File Paths
{
    echo "========================================================================"
    echo "developer-infra System Diagnostic Summary"
    echo "Timestamp : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "EnvFile   : ${ENV_FILE}"
    echo "========================================================================"
    echo ""
    echo "Check Results:"
    for row in "${SUMMARY_ROWS[@]}"; do
        echo "$row"
    done
    echo ""
    if [[ ${#HINTS[@]} -gt 0 ]]; then
        echo "Root-Cause Hints:"
        for h in "${HINTS[@]}"; do
            echo "  * ${h}"
        done
        echo ""
    fi
    echo "Generated Diagnostic Files:"
    for f in "$SUMMARY_FILE" "$SVC_FILE" "$NET_FILE" "$VPN_FILE" "$LOGS_FILE"; do
        if [[ -f "$f" ]]; then
            sz="$(wc -c < "$f" | tr -d ' ')"
            echo "  - ${f}  (${sz} bytes)"
        fi
    done
} > "$SUMMARY_FILE"

echo ""
cat "$SUMMARY_FILE"
