#!/usr/bin/env bash
# Quick egress & VPN diagnostic script (does not write temporary files into /etc/sing-box).
set -euo pipefail

echo "=== VPN Status ==="
if command -v vpn-ctl >/dev/null 2>&1; then
    vpn-ctl status || true
fi

echo ""
echo "=== TUN Interface ==="
ip a show sing-tun || echo "sing-tun is DOWN"

echo ""
echo "=== Egress IP (ipinfo.io) ==="
curl -fsS --max-time 8 https://ipinfo.io || echo "Egress check failed (kill-switch active or no route)"
echo ""
