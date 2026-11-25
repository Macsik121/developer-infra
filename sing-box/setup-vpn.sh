#!/usr/bin/env bash
# Deprecated helper retained for backward compatibility.
# sing-box is now pre-installed and SHA256-verified inside the Docker image,
# and managed by supervisord + vpn-sub-updater + vpn-ctl.
set -euo pipefail

echo "[setup-vpn.sh] sing-box is pre-installed in the image and managed automatically."
echo "Use 'vpn-ctl status' (inside container) or './vpn-ctl.ps1' / './vpn-ctl.sh' on the host."
if command -v sing-box >/dev/null 2>&1; then
    sing-box version
fi
