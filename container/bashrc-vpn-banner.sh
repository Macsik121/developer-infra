# Sourced by /etc/bash.bashrc for interactive shells.
# Displays a concise terminal banner whenever VPN is not UP.

__dev_infra_vpn_banner() {
    local state_file="/run/vpn/state"
    local mode_file="/run/vpn/mode"
    [[ -r "$state_file" ]] || return 0

    local state mode
    state="$(tr -d '[:space:]' < "$state_file" 2>/dev/null || echo UNKNOWN)"
    mode="$(tr -d '[:space:]' < "$mode_file" 2>/dev/null || echo strict)"

    case "$state" in
        UP)
            return 0
            ;;
        DEGRADED_NO_EGRESS)
            printf '\033[1;31m[VPN DEGRADED: NO EGRESS | mode=%s]\033[0m sing-tun is up, but proxy nodes are timing out. Run: vpn-ctl status | retest\n' "$mode"
            ;;
        DOWN_STRICT)
            printf '\033[1;31m[VPN KILL-SWITCH ACTIVE | mode=%s]\033[0m Traffic blocked while sing-box is down. Run on host: vpn-ctl status | direct\n' "$mode"
            ;;
        DOWN_FALLBACK)
            printf '\033[1;33m[VPN DEGRADED | mode=fallback]\033[0m Direct egress active (unprotected). Check: vpn-ctl status\n'
            ;;
        PROXY_ONLY)
            printf '\033[0;36m[VPN PROXY MODE]\033[0m Local proxy at http://127.0.0.1:2080 (no TUN kill-switch). Switch back on host: vpn-ctl strict\n'
            ;;
        DIRECT)
            printf '\033[1;33m[VPN BYPASSED | mode=direct]\033[0m Traffic is NOT routed through VPN. Re-enable on host: vpn-ctl strict\n'
            ;;
        KILLSWITCH_ERROR)
            printf '\033[1;41;37m[VPN KILL-SWITCH ERROR]\033[0m Kernel iptables/xt_mark failed! Network halted for safety.\n'
            ;;
        BOOTSTRAPPING)
            printf '\033[0;36m[VPN BOOTSTRAPPING]\033[0m Initializing sing-box tunnel...\n'
            ;;
        *)
            printf '\033[1;33m[VPN STATE: %s | mode=%s]\033[0m Run: vpn-ctl status\n' "$state" "$mode"
            ;;
    esac
}

case ";${PROMPT_COMMAND:-};" in
    *";__dev_infra_vpn_banner;"*) ;;
    *)
        if [[ -n "${PROMPT_COMMAND:-}" ]]; then
            PROMPT_COMMAND="__dev_infra_vpn_banner; ${PROMPT_COMMAND}"
        else
            PROMPT_COMMAND="__dev_infra_vpn_banner"
        fi
        ;;
esac
