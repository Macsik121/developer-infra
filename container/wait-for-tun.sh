#!/usr/bin/env bash
# Waits until sing-tun interface is UP or VPN mode explicitly allows direct traffic.
set -euo pipefail

WAIT_SECONDS="${VPN_TUN_WAIT_SECONDS:-25}"
RUN_VPN_DIR="${DEV_INFRA_RUN_DIR:-/run}/vpn"
TUN_IFACE="${VPN_TUN_IFACE:-sing-tun}"

for (( i=1; i<=WAIT_SECONDS; i++ )); do
    if [[ -r "${RUN_VPN_DIR}/mode" ]]; then
        mode="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/mode" 2>/dev/null || true)"
        if [[ "$mode" == "direct" ]]; then
            exit 0
        fi
    fi

    if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
        exit 0
    fi

    sleep 1
done

echo "[wait-for-tun] Warning: ${TUN_IFACE} not ready after ${WAIT_SECONDS}s" >&2
exit 1
