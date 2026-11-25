#!/usr/bin/env bash
# Root entrypoint for developer-infra (D8, D9):
# 1. Validates mandatory UI passwords (no empty or placeholder values).
# 2. Stages secrets into root-only /run/* files (chmod 600) and code-server config.
# 3. Hardens directory permissions (/var/lib/sing-box 700, /var/log/supervisor 750).
# 4. Initializes kill-switch rules via vpn-ctl.
# 5. Unsets sensitive env vars before exec'ing supervisord so coder/AI agents cannot read them.
set -euo pipefail

RUN_DIR="${DEV_INFRA_RUN_DIR:-/run}"
HOME_DIR="${DEV_INFRA_HOME_DIR:-/home/coder}"
SINGBOX_STATE_DIR="${DEV_INFRA_SINGBOX_STATE_DIR:-/var/lib/sing-box}"
SUPERVISOR_LOG_DIR="${DEV_INFRA_SUPERVISOR_LOG_DIR:-/var/log/supervisor}"
ETC_SINGBOX_DIR="${DEV_INFRA_ETC_SINGBOX_DIR:-/etc/sing-box}"
X11VNC_BIN="${X11VNC_BIN:-x11vnc}"
VPN_CTL_BIN="${VPN_CTL_BIN:-/usr/local/bin/vpn-ctl}"
SUPERVISORD_CMD="${DEV_INFRA_SUPERVISORD_CMD:-/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf}"

is_weak_password() {
    local val="${1:-}"
    if [[ -z "$val" ]] || [[ ${#val} -lt 6 ]]; then
        return 0
    fi
    case "${val,,}" in
        change_me*|devpassword123|password|123456|12345678|admin|qwerty)
            return 0
            ;;
    esac
    return 1
}

# 1. Validate mandatory passwords (D9)
CODE_PW="${CODE_SERVER_PASSWORD:-}"
VNC_PW="${VNC_PASSWORD:-}"

if is_weak_password "$CODE_PW"; then
    echo "[entrypoint] FATAL: CODE_SERVER_PASSWORD is missing, too short (<6 chars), or uses a forbidden placeholder." >&2
    echo "[entrypoint] Set a strong CODE_SERVER_PASSWORD in .env and restart." >&2
    exit 1
fi

if is_weak_password "$VNC_PW"; then
    echo "[entrypoint] FATAL: VNC_PASSWORD is missing, too short (<6 chars), or uses a forbidden placeholder." >&2
    echo "[entrypoint] Set a strong VNC_PASSWORD in .env and restart." >&2
    exit 1
fi

# 2. Prepare runtime & state directories with strict permissions (D8)
mkdir -p "${RUN_DIR}/vpn" "${RUN_DIR}/vnc" "$SINGBOX_STATE_DIR" "$SUPERVISOR_LOG_DIR"
chmod 755 "${RUN_DIR}/vpn"
chmod 700 "${RUN_DIR}/vnc" "$SINGBOX_STATE_DIR"
chmod 750 "$SUPERVISOR_LOG_DIR"

mkdir -p \
    "${HOME_DIR}/workspace" \
    "${HOME_DIR}/.config/code-server" \
    "${HOME_DIR}/.config/omniroute" \
    "${HOME_DIR}/.local/share/code-server" \
    "${HOME_DIR}/.chromium-profile" \
    "${HOME_DIR}/.claude" \
    "${HOME_DIR}/.xdg"

chmod 700 "${HOME_DIR}/.xdg" "${HOME_DIR}/.claude" "${HOME_DIR}/.config/code-server"

# 3. Stage VPN secrets in root-only files (D8)
umask 077
if [[ -n "${VPN_SUBSCRIPTION_URL:-}" ]]; then
    printf '%s\n' "$VPN_SUBSCRIPTION_URL" > "${RUN_DIR}/vpn/subscription_url"
    chmod 600 "${RUN_DIR}/vpn/subscription_url"
else
    rm -f "${RUN_DIR}/vpn/subscription_url"
fi

if [[ ! -s "${RUN_DIR}/vpn/clash_secret" ]]; then
    python3 -c 'import secrets; print(secrets.token_hex(24))' > "${RUN_DIR}/vpn/clash_secret"
    chmod 600 "${RUN_DIR}/vpn/clash_secret"
fi

# Public (non-secret) status files readable by coder for PROMPT_COMMAND / vpn-ctl status
FAIL_MODE="${VPN_FAIL_MODE:-strict}"
case "$FAIL_MODE" in
    strict|fallback|proxy|direct) ;;
    *)
        echo "[entrypoint] Warning: invalid VPN_FAIL_MODE='${FAIL_MODE}', defaulting to 'strict'" >&2
        FAIL_MODE="strict"
        ;;
esac
printf '%s\n' "$FAIL_MODE" > "${RUN_DIR}/vpn/mode"
printf '%s\n' "BOOTSTRAPPING" > "${RUN_DIR}/vpn/state"
chmod 644 "${RUN_DIR}/vpn/mode" "${RUN_DIR}/vpn/state"

# Save original Docker /etc/resolv.conf once so vpn-ctl can safely toggle TUN DNS vs Docker DNS
if [[ "${DEV_INFRA_SKIP_RESOLV_BACKUP:-0}" != "1" ]] && [[ -r /etc/resolv.conf ]] && [[ ! -s "${RUN_DIR}/vpn/resolv.conf.orig" ]]; then
    cp /etc/resolv.conf "${RUN_DIR}/vpn/resolv.conf.orig" 2>/dev/null || true
    chmod 644 "${RUN_DIR}/vpn/resolv.conf.orig" 2>/dev/null || true
fi

# 4. Stage VNC password file via x11vnc -storepasswd (invisible in ps aux, D9)
"$X11VNC_BIN" -storepasswd "$VNC_PW" "${RUN_DIR}/vnc/passwd" >/dev/null
chmod 600 "${RUN_DIR}/vnc/passwd"

# 5. Stage code-server config file (no PASSWORD env exposed to processes, D8/D9)
# Escape single quotes for YAML single-quoted scalar
ESCAPED_CODE_PW="${CODE_PW//\'/\'\'}"
cat > "${HOME_DIR}/.config/code-server/config.yaml" <<EOF
bind-addr: 0.0.0.0:8080
auth: password
password: '${ESCAPED_CODE_PW}'
cert: false
EOF
chmod 600 "${HOME_DIR}/.config/code-server/config.yaml"
umask 022

# Ensure coder owns its home subdirectories (skip in unprivileged unit test mode)
if [[ "${DEV_INFRA_SKIP_CHOWN:-0}" != "1" ]] && id coder >/dev/null 2>&1; then
    chown -R coder:coder \
        "${HOME_DIR}/.config" \
        "${HOME_DIR}/.local" \
        "${HOME_DIR}/.chromium-profile" \
        "${HOME_DIR}/.claude" \
        "${HOME_DIR}/.xdg"
    chown coder:coder "${HOME_DIR}/workspace" 2>/dev/null || true
fi

# 6. Sanitize any host-mounted /etc/sing-box/*.sh scripts
if [[ -d "$ETC_SINGBOX_DIR" ]]; then
    for f in "${ETC_SINGBOX_DIR}"/*.sh; do
        [[ -f "$f" ]] || continue
        if command -v dos2unix >/dev/null 2>&1; then
            dos2unix -q "$f" 2>/dev/null || true
        fi
        chmod +x "$f" 2>/dev/null || true
    done
fi

# 7. Initialize kill-switch firewall rules BEFORE launching user services (D6)
if [[ "${DEV_INFRA_SKIP_VPN_INIT:-0}" != "1" ]] && [[ -x "$VPN_CTL_BIN" ]]; then
    "$VPN_CTL_BIN" init
fi

# 8. CRITICAL (D8): Purge secrets from environment before exec'ing supervisord
unset VPN_SUBSCRIPTION_URL VNC_PASSWORD CODE_SERVER_PASSWORD PASSWORD CODE_PW VNC_PW ESCAPED_CODE_PW

# 9. Hand off PID 1 to supervisord (or test command)
# shellcheck disable=SC2086
exec $SUPERVISORD_CMD
