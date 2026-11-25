#!/usr/bin/env bash
# Host wrapper for container VPN & kill-switch management (D6, D8, Patch v2.1).
# Usage:
#   ./vpn-ctl.sh status
#   ./vpn-ctl.sh strict | fallback | proxy | direct | update | retest | select [number|node-tag]
#   ./vpn-ctl.sh --env-file .env.dev2 status
set -euo pipefail

ENV_FILE=".env"
if [[ "${1:-}" == "--env-file" ]]; then
    ENV_FILE="${2:-.env}"
    shift 2
fi

if [[ $# -eq 0 ]]; then
    set -- status
fi

exec docker compose --env-file "$ENV_FILE" exec -T -u root ubuntu-dev /usr/local/bin/vpn-ctl "$@"
