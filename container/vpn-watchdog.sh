#!/usr/bin/env bash
# Monitors sing-tun & live L7 egress health, maintains /run/vpn/state,
# performs automatic self-healing failover when the active node dies, and sends
# rate-limited GUI alerts (D6, Patch v2.2.3).
set -euo pipefail

RUN_VPN_DIR="${DEV_INFRA_RUN_DIR:-/run}/vpn"
TUN_IFACE="${VPN_TUN_IFACE:-sing-tun}"
DISPLAY_DETECT_BIN="${DISPLAY_DETECT_BIN:-/usr/local/lib/dev-infra/display-detect.sh}"
VPN_CTL_BIN="${VPN_CTL_BIN:-/usr/local/bin/vpn-ctl}"
VPN_SUB_UPDATER_BIN="${VPN_SUB_UPDATER_BIN:-/usr/local/lib/dev-infra/vpn-sub-updater.py}"
VPN_STATUS_URL="${VPN_STATUS_URL:-http://127.0.0.1:9099}"
CHECK_INTERVAL="${VPN_WATCHDOG_INTERVAL:-5}"
NOTIFY_COOLDOWN="${VPN_NOTIFY_COOLDOWN:-120}"
L7_CHECK_EVERY="${VPN_L7_CHECK_EVERY:-3}"
AUTO_FAILOVER="${VPN_AUTO_FAILOVER:-1}"
AUTO_REFRESH_COOLDOWN="${VPN_AUTO_REFRESH_COOLDOWN:-600}"
FAIL_THRESHOLD="${VPN_FAIL_THRESHOLD:-2}"
REFRESH_STREAK="${VPN_AUTO_REFRESH_STREAK:-12}"

LAST_NOTIFY_STATE=""
LAST_NOTIFY_TS=0
LAST_REFRESH_TS=0
L7_TICK=0
FAIL_STREAK=0

write_state() {
    local new_state="$1"
    local current=""
    [[ -r "${RUN_VPN_DIR}/state" ]] && current="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/state" 2>/dev/null || true)"
    if [[ "$current" != "$new_state" ]]; then
        mkdir -p "$RUN_VPN_DIR"
        printf '%s\n' "$new_state" > "${RUN_VPN_DIR}/state.tmp"
        chmod 644 "${RUN_VPN_DIR}/state.tmp"
        mv -f "${RUN_VPN_DIR}/state.tmp" "${RUN_VPN_DIR}/state"
        echo "[vpn-watchdog] State transition: ${current:-NONE} -> ${new_state}"
    fi
}

send_gui_alert() {
    local state="$1"
    local title="$2"
    local body="$3"
    local urgency="${4:-critical}"

    [[ "${VPN_GUI_NOTIFICATIONS:-1}" == "1" ]] || return 0
    command -v notify-send >/dev/null 2>&1 || return 0

    local now
    now="$(date +%s)"
    if [[ "$state" == "$LAST_NOTIFY_STATE" ]] && (( now - LAST_NOTIFY_TS < NOTIFY_COOLDOWN )); then
        return 0
    fi

    local disp=":99"
    if [[ -x "$DISPLAY_DETECT_BIN" ]]; then
        disp="$("$DISPLAY_DETECT_BIN" 2>/dev/null || echo ":99")"
    fi

    if DISPLAY="$disp" timeout 2 notify-send -u "$urgency" "$title" "$body" >/dev/null 2>&1; then
        LAST_NOTIFY_STATE="$state"
        LAST_NOTIFY_TS="$now"
    fi
}

# Populates global probe fields: PROBE_STATUS (ok|fail|unavailable), PROBE_SEL, PROBE_AUTO, PROBE_REACHABLE, PROBE_TOTAL
PROBE_STATUS="unavailable"
PROBE_SEL=""
PROBE_AUTO=""
PROBE_REACHABLE=0
PROBE_TOTAL=0

probe_l7_status() {
    PROBE_STATUS="unavailable"
    PROBE_SEL=""
    PROBE_AUTO=""
    PROBE_REACHABLE=0
    PROBE_TOTAL=0

    local json_out=""
    json_out="$(curl -fsS --max-time 7 "${VPN_STATUS_URL}/api/status?refresh=1" 2>/dev/null || true)"
    if [[ -z "$json_out" ]]; then
        return 0
    fi

    local parsed=""
    parsed="$(printf '%s' "$json_out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unavailable||||0|0")
    sys.exit(0)
eg_ok = bool((d.get("egress") or {}).get("ok"))
sel = str(d.get("selector_now") or "").replace("|", " ")
auto_now = str(d.get("auto_proxy_now") or "").replace("|", " ")
reachable = int(d.get("reachable_nodes") or 0)
total = int(d.get("total_nodes") or 0)
status = "ok" if eg_ok else "fail"
print(f"{status}|{sel}|{auto_now}|{reachable}|{total}")
' 2>/dev/null || true)"

    if [[ -n "$parsed" ]]; then
        IFS='|' read -r PROBE_STATUS PROBE_SEL PROBE_AUTO PROBE_REACHABLE PROBE_TOTAL <<< "$parsed"
    fi
}

attempt_self_heal() {
    local now
    now="$(date +%s)"

    # 1. If proxy-select is pinned to a dead manual node, immediately auto-failover to auto-proxy
    if [[ "$AUTO_FAILOVER" == "1" ]] \
        && [[ -n "$PROBE_SEL" ]] \
        && [[ "$PROBE_SEL" != "auto-proxy" ]] \
        && [[ "$PROBE_SEL" != "direct" ]] \
        && [[ "$PROBE_SEL" != "n/a" ]]; then
        echo "[vpn-watchdog] Active pinned node '${PROBE_SEL}' failed live egress (streak=${FAIL_STREAK}); auto-switching proxy-select -> auto-proxy (resolved: ${PROBE_AUTO:-pending})"
        if [[ -x "$VPN_CTL_BIN" ]]; then
            "$VPN_CTL_BIN" select auto-proxy >/dev/null 2>&1 || true
        fi
        send_gui_alert "AUTO_FAILOVER" "VPN Auto-Failover" "Pinned node '${PROBE_SEL}' failed egress. Switched to auto-proxy (${PROBE_AUTO:-selecting})." "normal"
        return 0
    fi

    # 2. Already on auto-proxy: trigger immediate Clash API retest so sing-box rotates off the dead node
    if [[ "$AUTO_FAILOVER" == "1" ]] && (( FAIL_STREAK == FAIL_THRESHOLD || (FAIL_STREAK - FAIL_THRESHOLD) % 4 == 0 )); then
        if [[ -x "$VPN_CTL_BIN" ]]; then
            echo "[vpn-watchdog] Egress failing on '${PROBE_SEL:-auto-proxy}' (streak=${FAIL_STREAK}); triggering Clash API latency retest..."
            "$VPN_CTL_BIN" retest >/dev/null 2>&1 || true
        fi
    fi

    # 3. Sustained outage (e.g. provider rotated Reality keys): rate-limited subscription refresh
    if [[ "$AUTO_FAILOVER" == "1" ]] \
        && (( FAIL_STREAK >= REFRESH_STREAK )) \
        && (( now - LAST_REFRESH_TS >= AUTO_REFRESH_COOLDOWN )) \
        && [[ -s "${RUN_VPN_DIR}/subscription_url" ]] \
        && [[ -f "$VPN_SUB_UPDATER_BIN" ]]; then
        LAST_REFRESH_TS="$now"
        echo "[vpn-watchdog] Sustained egress outage (streak=${FAIL_STREAK}); refreshing subscription via vpn-sub-updater..."
        python3 "$VPN_SUB_UPDATER_BIN" --once >/dev/null 2>&1 || true
    fi
}

run_iteration() {
    local mode="strict"
    local cur_state=""
    [[ -r "${RUN_VPN_DIR}/mode" ]] && mode="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/mode" 2>/dev/null || echo strict)"
    [[ -r "${RUN_VPN_DIR}/state" ]] && cur_state="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/state" 2>/dev/null || true)"

    if [[ "$cur_state" == "KILLSWITCH_ERROR" ]]; then
        send_gui_alert "KILLSWITCH_ERROR" "VPN Kill-Switch Error" "Kernel iptables/xt_mark failed. Egress halted for safety." "critical"
        return 0
    fi

    if [[ "$mode" == "direct" ]]; then
        FAIL_STREAK=0
        write_state "DIRECT"
        return 0
    fi

    if [[ "$mode" == "proxy" ]]; then
        FAIL_STREAK=0
        write_state "PROXY_ONLY"
        return 0
    fi

    if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
        L7_TICK=$((L7_TICK + 1))
        if [[ "$cur_state" == "BOOTSTRAPPING" || "$cur_state" == "DOWN_STRICT" || "$cur_state" == "DOWN_FALLBACK" || "$cur_state" == "DEGRADED_NO_EGRESS" || "$FAIL_STREAK" -gt 0 || $((L7_TICK % L7_CHECK_EVERY)) -eq 0 ]]; then
            probe_l7_status
            if [[ "$PROBE_STATUS" == "ok" ]]; then
                FAIL_STREAK=0
                if [[ "$cur_state" == "DOWN_STRICT" || "$cur_state" == "DOWN_FALLBACK" || "$cur_state" == "DEGRADED_NO_EGRESS" ]]; then
                    send_gui_alert "UP" "VPN Restored" "sing-tun tunnel and live proxy egress are online." "normal"
                fi
                write_state "UP"
            elif [[ "$PROBE_STATUS" == "fail" ]]; then
                FAIL_STREAK=$((FAIL_STREAK + 1))
                if (( FAIL_STREAK >= FAIL_THRESHOLD )); then
                    write_state "DEGRADED_NO_EGRESS"
                    attempt_self_heal
                    send_gui_alert "DEGRADED_NO_EGRESS" "VPN Degraded (No Egress)" "Live egress failed on '${PROBE_SEL:-active node}' (reachable in pool: ${PROBE_REACHABLE}/${PROBE_TOTAL}). Run vpn-ctl status." "critical"
                fi
            else
                # Status API temporarily unreachable (early boot or overloaded); do not mask persistent failure
                if [[ "$cur_state" != "BOOTSTRAPPING" && -n "$cur_state" ]]; then
                    FAIL_STREAK=$((FAIL_STREAK + 1))
                    if (( FAIL_STREAK >= FAIL_THRESHOLD + 2 )); then
                        write_state "DEGRADED_NO_EGRESS"
                    fi
                fi
            fi
        else
            [[ "$cur_state" == "DEGRADED_NO_EGRESS" ]] || write_state "UP"
        fi
    else
        L7_TICK=0
        FAIL_STREAK=0
        if [[ "$mode" == "fallback" ]]; then
            write_state "DOWN_FALLBACK"
            send_gui_alert "DOWN_FALLBACK" "VPN Down (Fallback Mode)" "sing-tun offline. Direct unprotected egress is active." "critical"
        else
            write_state "DOWN_STRICT"
            send_gui_alert "DOWN_STRICT" "VPN Kill-Switch Active" "sing-tun offline. Outbound traffic is blocked. Use host vpn-ctl." "critical"
        fi
    fi
}

if [[ "${VPN_WATCHDOG_ONCE:-0}" == "1" ]]; then
    run_iteration
    exit 0
fi

while true; do
    run_iteration
    sleep "$CHECK_INTERVAL"
done
