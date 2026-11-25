#!/usr/bin/env bash
# Monitors sing-tun & L7 egress health, maintains /run/vpn/state, and sends rate-limited GUI alerts (D6, Patch v2.1).
set -euo pipefail

RUN_VPN_DIR="${DEV_INFRA_RUN_DIR:-/run}/vpn"
TUN_IFACE="${VPN_TUN_IFACE:-sing-tun}"
DISPLAY_DETECT_BIN="${DISPLAY_DETECT_BIN:-/usr/local/lib/dev-infra/display-detect.sh}"
VPN_STATUS_URL="${VPN_STATUS_URL:-http://127.0.0.1:9099}"
CHECK_INTERVAL="${VPN_WATCHDOG_INTERVAL:-5}"
NOTIFY_COOLDOWN="${VPN_NOTIFY_COOLDOWN:-120}"
L7_CHECK_EVERY="${VPN_L7_CHECK_EVERY:-6}"

LAST_NOTIFY_STATE=""
LAST_NOTIFY_TS=0
L7_TICK=0

write_state() {
    local new_state="$1"
    local current=""
    [[ -r "${RUN_VPN_DIR}/state" ]] && current="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/state" 2>/dev/null || true)"
    if [[ "$current" != "$new_state" ]]; then
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

check_l7_health() {
    # Returns 0 if healthy or indeterminate (early boot), 1 if confirmed degraded (0 reachable + egress failed)
    local json_out=""
    json_out="$(curl -fsS --max-time 5 "${VPN_STATUS_URL}/api/status" 2>/dev/null || true)"
    [[ -n "$json_out" ]] || return 0

    printf '%s' "$json_out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
eg_ok = bool((d.get("egress") or {}).get("ok"))
reachable = int(d.get("reachable_nodes") or 0)
total = int(d.get("total_nodes") or 0)
if eg_ok or reachable > 0:
    sys.exit(0)
if total > 0 and not eg_ok:
    sys.exit(1)
sys.exit(0)
'
}

while true; do
    mode="strict"
    cur_state=""
    [[ -r "${RUN_VPN_DIR}/mode" ]] && mode="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/mode" 2>/dev/null || echo strict)"
    [[ -r "${RUN_VPN_DIR}/state" ]] && cur_state="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/state" 2>/dev/null || true)"

    if [[ "$cur_state" == "KILLSWITCH_ERROR" ]]; then
        send_gui_alert "KILLSWITCH_ERROR" "VPN Kill-Switch Error" "Kernel iptables/xt_mark failed. Egress halted for safety." "critical"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if [[ "$mode" == "direct" ]]; then
        write_state "DIRECT"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if [[ "$mode" == "proxy" ]]; then
        write_state "PROXY_ONLY"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
        L7_TICK=$((L7_TICK + 1))
        if [[ "$cur_state" == "BOOTSTRAPPING" || "$cur_state" == "DOWN_STRICT" || "$cur_state" == "DOWN_FALLBACK" || "$cur_state" == "DEGRADED_NO_EGRESS" || $((L7_TICK % L7_CHECK_EVERY)) -eq 0 ]]; then
            if check_l7_health; then
                if [[ "$cur_state" == "DOWN_STRICT" || "$cur_state" == "DOWN_FALLBACK" || "$cur_state" == "DEGRADED_NO_EGRESS" ]]; then
                    send_gui_alert "UP" "VPN Restored" "sing-tun tunnel and proxy egress are online." "normal"
                fi
                write_state "UP"
            else
                write_state "DEGRADED_NO_EGRESS"
                send_gui_alert "DEGRADED_NO_EGRESS" "VPN Degraded (No Egress)" "sing-tun is UP but 0 nodes are reachable. Run vpn-ctl retest or vpn-ctl update." "critical"
            fi
        else
            [[ "$cur_state" == "DEGRADED_NO_EGRESS" ]] || write_state "UP"
        fi
    else
        L7_TICK=0
        if [[ "$mode" == "fallback" ]]; then
            write_state "DOWN_FALLBACK"
            send_gui_alert "DOWN_FALLBACK" "VPN Down (Fallback Mode)" "sing-tun offline. Direct unprotected egress is active." "critical"
        else
            write_state "DOWN_STRICT"
            send_gui_alert "DOWN_STRICT" "VPN Kill-Switch Active" "sing-tun offline. Outbound traffic is blocked. Use host vpn-ctl." "critical"
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
