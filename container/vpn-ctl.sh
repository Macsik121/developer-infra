#!/usr/bin/env bash
# VPN Kill-Switch & Control CLI inside container (D6, D8, SRE-3, Patch v2.1).
# Commands:
#   vpn-ctl status                      (allowed for coder — read-only, live telemetry)
#   vpn-ctl init                        (root only — called by entrypoint)
#   vpn-ctl strict                      (root only — enforce IPv4+IPv6+DNS kill-switch + fwmark routing)
#   vpn-ctl fallback                    (root only — allow direct if VPN drops)
#   vpn-ctl proxy                       (root only — internal mixed HTTP/SOCKS5 on 127.0.0.1:2080 without TUN)
#   vpn-ctl direct                      (root only — bypass VPN intentionally)
#   vpn-ctl update                      (root only — trigger immediate subscription refresh)
#   vpn-ctl retest                      (root only — re-benchmark all nodes in auto-proxy via Clash API)
#   vpn-ctl select [number|node-tag]    (root only — numbered list or switch active proxy via Clash API)
#   vpn-ctl bootstrap-allow <host>      (root only — temporary HTTPS rule during cold start)
#   vpn-ctl bootstrap-revoke            (root only — clear temporary cold-start rule)
set -euo pipefail

RUN_VPN_DIR="${DEV_INFRA_RUN_DIR:-/run}/vpn"
TUN_IFACE="${VPN_TUN_IFACE:-sing-tun}"
CLASH_API_URL="${CLASH_API_URL:-http://127.0.0.1:9090}"
VPN_STATUS_URL="${VPN_STATUS_URL:-http://127.0.0.1:9099}"
KS_CHAIN="DEVINFRA_KS"
BS_CHAIN="DEVINFRA_BOOTSTRAP"
PROBE_CHAIN="DEVINFRA_PROBE"
FWMARK="0xff"

IPT4=""
IPT6=""

require_root() {
    if [[ "${VPN_CTL_ALLOW_NONROOT_TEST:-0}" == "1" ]]; then
        return 0
    fi
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "[vpn-ctl] ERROR: Root privileges required for this action." >&2
        echo "[vpn-ctl] Run from host: ./vpn-ctl.ps1 <command>  (or ./vpn-ctl.sh <command>)" >&2
        exit 1
    fi
}

write_file_atomic() {
    local target="$1"
    local val="$2"
    mkdir -p "$RUN_VPN_DIR"
    printf '%s\n' "$val" > "${target}.tmp"
    chmod 644 "${target}.tmp"
    mv -f "${target}.tmp" "$target"
}

set_tun_resolv_conf() {
    if [[ "${VPN_CTL_SKIP_RESOLV:-0}" == "1" ]]; then
        return 0
    fi
    if [[ -r /etc/resolv.conf ]] && [[ ! -s "${RUN_VPN_DIR}/resolv.conf.orig" ]]; then
        mkdir -p "$RUN_VPN_DIR"
        cp /etc/resolv.conf "${RUN_VPN_DIR}/resolv.conf.orig" 2>/dev/null || true
        chmod 644 "${RUN_VPN_DIR}/resolv.conf.orig" 2>/dev/null || true
    fi
    # Overwrite in-place because /etc/resolv.conf is a Docker bind-mount (mv fails with EBUSY)
    printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf 2>/dev/null || true
}

restore_resolv_conf() {
    if [[ "${VPN_CTL_SKIP_RESOLV:-0}" == "1" ]]; then
        return 0
    fi
    if [[ -s "${RUN_VPN_DIR}/resolv.conf.orig" ]]; then
        cat "${RUN_VPN_DIR}/resolv.conf.orig" > /etc/resolv.conf 2>/dev/null || true
    fi
}

ensure_fwmark_routing() {
    # Ensure sing-box & probe sockets marked with fwmark 0xff always bypass sing-tun via main table
    ip rule del fwmark "$FWMARK" lookup main 2>/dev/null || true
    ip rule add fwmark "$FWMARK" lookup main pref 100 2>/dev/null || true
    ip -6 rule del fwmark "$FWMARK" lookup main 2>/dev/null || true
    ip -6 rule add fwmark "$FWMARK" lookup main pref 100 2>/dev/null || true
}

clear_fwmark_routing() {
    ip rule del fwmark "$FWMARK" lookup main 2>/dev/null || true
    ip -6 rule del fwmark "$FWMARK" lookup main 2>/dev/null || true
}

detect_iptables_backend() {
    local candidates=()
    if [[ -n "${VPN_IPTABLES_BIN:-}" ]]; then
        candidates+=("$VPN_IPTABLES_BIN")
    else
        candidates+=(iptables-nft iptables-legacy iptables)
    fi

    local bin
    for bin in "${candidates[@]}"; do
        command -v "$bin" >/dev/null 2>&1 || continue
        "$bin" -N "$PROBE_CHAIN" 2>/dev/null || "$bin" -F "$PROBE_CHAIN" 2>/dev/null || true
        if "$bin" -A "$PROBE_CHAIN" -m mark --mark "$FWMARK" -j ACCEPT 2>/dev/null; then
            "$bin" -F "$PROBE_CHAIN" 2>/dev/null || true
            "$bin" -X "$PROBE_CHAIN" 2>/dev/null || true
            IPT4="$bin"
            case "$bin" in
                *iptables-nft)    IPT6="${bin/iptables-nft/ip6tables-nft}" ;;
                *iptables-legacy) IPT6="${bin/iptables-legacy/ip6tables-legacy}" ;;
                *)                IPT6="${VPN_IP6TABLES_BIN:-ip6tables}" ;;
            esac
            command -v "$IPT6" >/dev/null 2>&1 || IPT6=""
            return 0
        fi
        "$bin" -F "$PROBE_CHAIN" 2>/dev/null || true
        "$bin" -X "$PROBE_CHAIN" 2>/dev/null || true
    done

    return 1
}

apply_failsafe_halt() {
    echo "[vpn-ctl] CRITICAL: Kernel iptables/xt_mark unsupported! Engaging fail-safe halt." >&2
    write_file_atomic "${RUN_VPN_DIR}/state" "KILLSWITCH_ERROR"
    local bin
    for bin in "${VPN_IPTABLES_BIN:-}" iptables-nft iptables-legacy iptables; do
        [[ -n "$bin" ]] && command -v "$bin" >/dev/null 2>&1 || continue
        "$bin" -F OUTPUT 2>/dev/null || true
        "$bin" -A OUTPUT -d 127.0.0.11 -j DROP 2>/dev/null || true
        "$bin" -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
        "$bin" -P OUTPUT DROP 2>/dev/null || true
        break
    done
    exit 1
}

ensure_backend_or_halt() {
    if ! detect_iptables_backend; then
        apply_failsafe_halt
    fi
}

clear_killswitch_rules() {
    ensure_backend_or_halt
    for _ in 1 2 3 4 5; do "$IPT4" -D OUTPUT -j "$KS_CHAIN" 2>/dev/null || break; done
    "$IPT4" -F "$KS_CHAIN" 2>/dev/null || true
    "$IPT4" -F "$BS_CHAIN" 2>/dev/null || true

    if [[ -n "$IPT6" ]]; then
        for _ in 1 2 3 4 5; do "$IPT6" -D OUTPUT -j "$KS_CHAIN" 2>/dev/null || break; done
        "$IPT6" -F "$KS_CHAIN" 2>/dev/null || true
    fi
    clear_fwmark_routing
    restore_resolv_conf
}

apply_strict_rules() {
    ensure_backend_or_halt
    ensure_fwmark_routing

    # Prepare chains idempotently (IPv4)
    "$IPT4" -N "$BS_CHAIN" 2>/dev/null || true
    "$IPT4" -N "$KS_CHAIN" 2>/dev/null || true
    "$IPT4" -F "$KS_CHAIN"

    # 1. Allow tunnel egress & sing-box/probe marked packets (default_mark: 255 = 0xff)
    "$IPT4" -A "$KS_CHAIN" -o "$TUN_IFACE" -j ACCEPT
    "$IPT4" -A "$KS_CHAIN" -m mark --mark "$FWMARK" -j ACCEPT

    # 2. Block ALL traffic to Docker embedded DNS (127.0.0.11) on every port:
    #    Docker nat OUTPUT DNATs 127.0.0.11:53 to an ephemeral port before filter OUTPUT (ST-LIVE-7).
    "$IPT4" -A "$KS_CHAIN" -d 127.0.0.11 -j REJECT --reject-with icmp-admin-prohibited

    # 3. Allow loopback (code-server, omniroute, x11vnc, noVNC, Clash API, vpn-status, mixed proxy)
    "$IPT4" -A "$KS_CHAIN" -o lo -j ACCEPT

    # 4. Allow established replies to private Docker host/bridge networks (UI ports stay reachable)
    "$IPT4" -A "$KS_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -d 10.0.0.0/8 -j ACCEPT
    "$IPT4" -A "$KS_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -d 172.16.0.0/12 -j ACCEPT
    "$IPT4" -A "$KS_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -d 192.168.0.0/16 -j ACCEPT

    # 5. Temporary cold-start bootstrap chain (empty during normal operation)
    "$IPT4" -A "$KS_CHAIN" -j "$BS_CHAIN"

    # 6. Fast-fail all remaining non-VPN IPv4 egress
    "$IPT4" -A "$KS_CHAIN" -j REJECT --reject-with icmp-admin-prohibited

    # Ensure single jump at top of OUTPUT (bounded loop)
    for _ in 1 2 3 4 5; do "$IPT4" -D OUTPUT -j "$KS_CHAIN" 2>/dev/null || break; done
    "$IPT4" -I OUTPUT 1 -j "$KS_CHAIN"

    # Mirror strict rules for IPv6 (ST-3: zero IPv6 leaks)
    if [[ -n "$IPT6" ]]; then
        "$IPT6" -N "$KS_CHAIN" 2>/dev/null || true
        "$IPT6" -F "$KS_CHAIN"
        "$IPT6" -A "$KS_CHAIN" -o "$TUN_IFACE" -j ACCEPT
        "$IPT6" -A "$KS_CHAIN" -m mark --mark "$FWMARK" -j ACCEPT
        "$IPT6" -A "$KS_CHAIN" -o lo -j ACCEPT
        "$IPT6" -A "$KS_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -d fe80::/10 -j ACCEPT
        "$IPT6" -A "$KS_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -d fc00::/7 -j ACCEPT
        "$IPT6" -A "$KS_CHAIN" -j REJECT --reject-with icmp6-adm-prohibited
        for _ in 1 2 3 4 5; do "$IPT6" -D OUTPUT -j "$KS_CHAIN" 2>/dev/null || break; done
        "$IPT6" -I OUTPUT 1 -j "$KS_CHAIN"
    fi

    # Route container DNS through sing-tun (hijack-dns -> dns-remote) instead of 127.0.0.11
    set_tun_resolv_conf
}

cmd_init() {
    require_root
    local mode="strict"
    if [[ -r "${RUN_VPN_DIR}/mode" ]]; then
        mode="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/mode")"
    fi

    case "$mode" in
        strict)
            apply_strict_rules
            echo "[vpn-ctl] Initialized kill-switch in STRICT mode (backend: ${IPT4})"
            ;;
        fallback)
            clear_killswitch_rules
            ensure_fwmark_routing
            echo "[vpn-ctl] Initialized in FALLBACK mode (backend: ${IPT4})"
            ;;
        proxy)
            clear_killswitch_rules
            write_file_atomic "${RUN_VPN_DIR}/state" "PROXY_ONLY"
            echo "[vpn-ctl] Initialized in PROXY mode (mixed proxy on 127.0.0.1:2080, no TUN)"
            ;;
        direct)
            clear_killswitch_rules
            write_file_atomic "${RUN_VPN_DIR}/state" "DIRECT"
            echo "[vpn-ctl] Initialized in DIRECT mode (VPN bypassed)"
            ;;
        *)
            write_file_atomic "${RUN_VPN_DIR}/mode" "strict"
            apply_strict_rules
            echo "[vpn-ctl] Unknown mode '${mode}', defaulted to STRICT"
            ;;
    esac
}

cmd_strict() {
    require_root
    local prev_mode=""
    [[ -r "${RUN_VPN_DIR}/mode" ]] && prev_mode="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/mode" 2>/dev/null || true)"

    write_file_atomic "${RUN_VPN_DIR}/mode" "strict"
    if [[ "$prev_mode" == "proxy" ]] && [[ -f /usr/local/lib/dev-infra/vpn-sub-updater.py ]]; then
        python3 /usr/local/lib/dev-infra/vpn-sub-updater.py --once || true
    fi
    apply_strict_rules
    if command -v supervisorctl >/dev/null 2>&1; then
        if [[ "$prev_mode" == "proxy" ]]; then
            supervisorctl restart sing-box >/dev/null 2>&1 || true
        else
            supervisorctl start sing-box >/dev/null 2>&1 || true
        fi
    fi
    if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
        write_file_atomic "${RUN_VPN_DIR}/state" "UP"
    else
        write_file_atomic "${RUN_VPN_DIR}/state" "DOWN_STRICT"
    fi
    echo "[vpn-ctl] Mode set to STRICT (IPv4 + IPv6 + Docker DNS kill-switch + fwmark routing active)."
}

cmd_fallback() {
    require_root
    local prev_mode=""
    [[ -r "${RUN_VPN_DIR}/mode" ]] && prev_mode="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/mode" 2>/dev/null || true)"

    write_file_atomic "${RUN_VPN_DIR}/mode" "fallback"
    clear_killswitch_rules
    ensure_fwmark_routing
    if [[ "$prev_mode" == "proxy" ]] && [[ -f /usr/local/lib/dev-infra/vpn-sub-updater.py ]]; then
        python3 /usr/local/lib/dev-infra/vpn-sub-updater.py --once || true
    fi
    if command -v supervisorctl >/dev/null 2>&1; then
        if [[ "$prev_mode" == "proxy" ]]; then
            supervisorctl restart sing-box >/dev/null 2>&1 || true
        else
            supervisorctl start sing-box >/dev/null 2>&1 || true
        fi
    fi
    if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
        write_file_atomic "${RUN_VPN_DIR}/state" "UP"
    else
        write_file_atomic "${RUN_VPN_DIR}/state" "DOWN_FALLBACK"
    fi
    echo "[vpn-ctl] Mode set to FALLBACK (VPN active; direct egress permitted on failure)."
}

cmd_proxy() {
    require_root
    write_file_atomic "${RUN_VPN_DIR}/mode" "proxy"
    clear_killswitch_rules
    write_file_atomic "${RUN_VPN_DIR}/state" "PROXY_ONLY"
    if [[ -f /usr/local/lib/dev-infra/vpn-sub-updater.py ]]; then
        python3 /usr/local/lib/dev-infra/vpn-sub-updater.py --once || true
    fi
    if command -v supervisorctl >/dev/null 2>&1; then
        supervisorctl restart sing-box >/dev/null 2>&1 || true
    fi
    echo "[vpn-ctl] Mode set to PROXY (no TUN; internal HTTP/SOCKS5 proxy active at http://127.0.0.1:2080)."
    echo "[vpn-ctl] Use 'open-chromium --proxy' or export HTTP_PROXY=http://127.0.0.1:2080 HTTPS_PROXY=http://127.0.0.1:2080"
}

cmd_direct() {
    require_root
    write_file_atomic "${RUN_VPN_DIR}/mode" "direct"
    clear_killswitch_rules
    if command -v supervisorctl >/dev/null 2>&1; then
        supervisorctl stop sing-box >/dev/null 2>&1 || true
    fi
    write_file_atomic "${RUN_VPN_DIR}/state" "DIRECT"
    echo "[vpn-ctl] Mode set to DIRECT (VPN stopped; host network / unprotected direct egress active)."
}

cmd_bootstrap_allow() {
    require_root
    local host="${1:-}"
    [[ -n "$host" ]] || { echo "[vpn-ctl] Missing host for bootstrap-allow" >&2; exit 1; }
    ensure_backend_or_halt

    # Temporarily restore Docker DNS and allow 127.0.0.11 BEFORE resolving subscription host
    restore_resolv_conf
    "$IPT4" -N "$BS_CHAIN" 2>/dev/null || true
    "$IPT4" -F "$BS_CHAIN"
    "$IPT4" -A "$BS_CHAIN" -d 127.0.0.11 -j ACCEPT
    for _ in 1 2 3 4 5; do "$IPT4" -D "$KS_CHAIN" -j "$BS_CHAIN" 2>/dev/null || break; done
    "$IPT4" -I "$KS_CHAIN" 1 -j "$BS_CHAIN" 2>/dev/null || true

    local ips
    ips="$(python3 -c 'import socket,sys; print("\n".join(sorted({r[4][0] for r in socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET)})))' "$host" 2>/dev/null || true)"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        "$IPT4" -A "$BS_CHAIN" -d "$ip" -p tcp --dport 443 -j ACCEPT
    done <<< "$ips"
}

cmd_bootstrap_revoke() {
    require_root
    ensure_backend_or_halt
    "$IPT4" -F "$BS_CHAIN" 2>/dev/null || true
    local mode=""
    [[ -r "${RUN_VPN_DIR}/mode" ]] && mode="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/mode" 2>/dev/null || true)"
    if [[ "$mode" == "strict" ]]; then
        set_tun_resolv_conf
    fi
}

cmd_update() {
    require_root
    python3 /usr/local/lib/dev-infra/vpn-sub-updater.py --once
}

cmd_retest() {
    require_root
    local secret_file="${RUN_VPN_DIR}/clash_secret"
    if [[ ! -r "$secret_file" ]]; then
        echo "[vpn-ctl] ERROR: Clash API secret not found at ${secret_file}" >&2
        exit 1
    fi
    local secret
    secret="$(tr -d '[:space:]' < "$secret_file")"
    echo "[vpn-ctl] Running latency test across auto-proxy nodes (timeout 5s)..."
    CLASH_API_URL="$CLASH_API_URL" CLASH_SECRET="$secret" python3 -c '
import concurrent.futures, json, os, sys, urllib.error, urllib.parse, urllib.request

base = os.environ["CLASH_API_URL"].rstrip("/")
secret = os.environ["CLASH_SECRET"]
headers = {"Authorization": f"Bearer {secret}"}
test_url = urllib.parse.quote("https://www.gstatic.com/generate_204", safe="")

def api_get(path, timeout=8):
    req = urllib.request.Request(f"{base}{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="ignore"))

results = {}
errors = []

try:
    group_data = api_get(f"/group/auto-proxy/delay?timeout=5000&url={test_url}", timeout=12)
    if isinstance(group_data, dict):
        for k, v in group_data.items():
            if isinstance(v, (int, float)) and v > 0:
                results[k] = int(v)
except Exception as exc:
    errors.append(str(exc))

# sing-box 1.12 /group/auto-proxy/delay can return {} when urltest is busy or group check fails.
# Fall back to parallel per-node /proxies/<tag>/delay probes so operators always get real results.
if not results:
    try:
        proxies = api_get("/proxies", timeout=4).get("proxies", {})
        members = [
            n for n in (proxies.get("auto-proxy") or {}).get("all", [])
            if n not in {"auto-proxy", "proxy-select", "direct"}
        ]
    except Exception as exc:
        print(f"[vpn-ctl] ERROR querying Clash API: {exc}", file=sys.stderr)
        sys.exit(1)

    def probe_one(tag):
        qtag = urllib.parse.quote(tag, safe="")
        try:
            d = api_get(f"/proxies/{qtag}/delay?timeout=5000&url={test_url}", timeout=6)
            delay = d.get("delay") if isinstance(d, dict) else None
            if isinstance(delay, (int, float)) and delay > 0:
                return tag, int(delay), ""
            return tag, 0, str((d or {}).get("message", "no delay"))
        except urllib.error.HTTPError as he:
            body = he.read().decode("utf-8", errors="ignore")
            try:
                msg = json.loads(body).get("message", body)
            except Exception:
                msg = body or str(he)
            return tag, 0, str(msg).strip()
        except Exception as exc:
            return tag, 0, str(exc)

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        for tag, ms, err in pool.map(probe_one, members):
            if ms > 0:
                results[tag] = ms
            elif err:
                errors.append(f"{tag}: {err}")

items = sorted(results.items(), key=lambda x: x[1])
if not items:
    print("No reachable nodes responded to delay test.")
    if errors:
        print(f"Sample errors ({len(errors)} failed):")
        for e in errors[:5]:
            print(f"  - {e[:140]}")
    sys.exit(0)

print(f"Reachable nodes: {len(items)}" + (f" (failed: {len(errors)})" if errors else ""))
for idx, (name, ms) in enumerate(items[:15], start=1):
    print(f"  {idx:2d}. {name:<42s} {ms:4d} ms")
if errors:
    print(f"Sample failure: {errors[0][:140]}")
'
}

cmd_select() {
    require_root
    local secret_file="${RUN_VPN_DIR}/clash_secret"
    if [[ ! -r "$secret_file" ]]; then
        echo "[vpn-ctl] ERROR: Clash API secret not found at ${secret_file}" >&2
        exit 1
    fi
    local secret
    secret="$(tr -d '[:space:]' < "$secret_file")"
    local target="${1:-}"

    local proxies_json
    proxies_json="$(curl -fsS --max-time 5 -H "Authorization: Bearer ${secret}" "${CLASH_API_URL}/proxies")"

    if [[ -z "$target" ]]; then
        printf '%s' "$proxies_json" | python3 -c '
import json, sys
p = json.load(sys.stdin).get("proxies", {})
sel = p.get("proxy-select", {})
auto = p.get("auto-proxy", {})
sel_now = sel.get("now", "n/a")
auto_now = auto.get("now", "n/a")
print(f"Active Selector : {sel_now}" + (f" -> {auto_now}" if sel_now == "auto-proxy" else ""))
print("Available nodes :")
for idx, name in enumerate(sel.get("all", []), start=1):
    hist = (p.get(name) or {}).get("history") or []
    delay = hist[-1].get("delay") if hist else None
    delay_s = f"({int(delay)} ms)" if isinstance(delay, (int, float)) and delay > 0 else "(untested/timeout)"
    if name == "auto-proxy":
        delay_s = f"[resolved: {auto_now}]"
    elif name == "direct":
        delay_s = "[bypass]"
    mark = " *" if name == sel_now else ""
    print(f"  {idx:2d}. {name:<42s} {delay_s}{mark}")
print("\nTip: select by number (vpn-ctl select 2) or exact name.")
'
    else
        local resolved_target
        resolved_target="$(printf '%s' "$proxies_json" | python3 -c '
import json, sys
arg = sys.argv[1].strip()
all_nodes = json.load(sys.stdin).get("proxies", {}).get("proxy-select", {}).get("all", [])
if arg.isdigit():
    idx = int(arg)
    if 1 <= idx <= len(all_nodes):
        print(all_nodes[idx - 1])
        sys.exit(0)
    print(f"ERROR: index {idx} out of range (1..{len(all_nodes)})", file=sys.stderr)
    sys.exit(2)
print(arg)
' "$target")"
        local payload
        payload="$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1]}))' "$resolved_target")"
        curl -fsS -X PUT \
            -H "Authorization: Bearer ${secret}" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "${CLASH_API_URL}/proxies/proxy-select" >/dev/null
        echo "[vpn-ctl] Switched proxy-select -> ${resolved_target}"
    fi
}

cmd_status() {
    # Prefer internal read-only status API (works identically for coder & root, zero secret exposure)
    local api_json=""
    if [[ "${VPN_CTL_OFFLINE_STATUS:-0}" != "1" ]] && command -v curl >/dev/null 2>&1; then
        api_json="$(curl -fsS --max-time 8 "${VPN_STATUS_URL}/api/status?refresh=1" 2>/dev/null || true)"
        if [[ -z "$api_json" ]]; then
            api_json="$(curl -fsS --max-time 3 "${VPN_STATUS_URL}/api/status?fast=1" 2>/dev/null || true)"
        fi
    fi

    if [[ -n "$api_json" ]]; then
        printf '%s' "$api_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
tun = "UP" if d.get("tun_up") else "DOWN"
sb = "RUNNING" if d.get("singbox_running") else "STOPPED"
sel = d.get("selector_now", "n/a")
auto_now = d.get("auto_proxy_now", "")
leaf = d.get("active_node", "n/a")
delay = d.get("delay_ms")
delay_s = f" ({delay} ms)" if delay is not None else ""
node_str = f"{sel} -> {leaf}{delay_s}" if sel == "auto-proxy" and leaf != sel and not leaf.startswith("auto-proxy") else f"{leaf}{delay_s}"
eg = d.get("egress") or {}
if eg.get("ok"):
    ip = eg.get("ip", "")
    country = eg.get("country", "")
    org = eg.get("org", "")
    head = f"{ip} ({country})" if country else (ip or "verified")
    eg_str = f"{head} - {org}" if org else head
else:
    err = eg.get("error") or "no egress"
    eg_str = f"FAILED ({err})"

mode = d.get("mode", "unknown")
state = d.get("state", "unknown")
agent_policy = d.get("agent_policy", "open")
tun_iface = d.get("tun_iface", "sing-tun")
reachable = d.get("reachable_nodes", 0)
total = d.get("total_nodes", 0)
updater = d.get("updater_summary")

print(f"VPN Mode      : {mode}")
print(f"VPN State     : {state}")
print(f"Agent Policy  : {agent_policy}")
print(f"sing-box      : {sb}")
print(f"TUN Interface : {tun_iface} ({tun})")
print(f"Active Node   : {node_str}")
print(f"Reachable     : {reachable} / {total} nodes")
print(f"Live Egress   : {eg_str}")
print("Dashboard URL : http://127.0.0.1:9099")
if not eg.get("ok") and sel not in {"auto-proxy", "direct", "n/a", ""}:
    auto_hint = f" (auto-proxy -> {auto_now})" if auto_now else ""
    print(f"Hint          : Pinned node failing! Run vpn-ctl select auto-proxy{auto_hint}")
if updater:
    print(f"Updater       : {updater}")
errs = d.get("recent_errors") or []
if errs:
    print("Recent Errors :")
    for e in errs[-3:]:
        print(f"  - {e}")
'
        return 0
    fi

    # Graceful offline fallback (used during early startup or unit tests)
    local mode="unknown"
    local state="unknown"
    local policy="open"
    local tun="DOWN"
    [[ -r "${RUN_VPN_DIR}/mode" ]] && mode="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/mode")"
    [[ -r "${RUN_VPN_DIR}/state" ]] && state="$(tr -d '[:space:]' < "${RUN_VPN_DIR}/state")"
    [[ -r "${RUN_VPN_DIR}/policy" ]] && policy="$(tr -d '\r\n' < "${RUN_VPN_DIR}/policy")"
    if ip link show "$TUN_IFACE" >/dev/null 2>&1; then
        tun="UP"
    fi
    echo "VPN Mode      : ${mode}"
    echo "VPN State     : ${state}"
    echo "Agent Policy  : ${policy}"
    echo "TUN Interface : ${TUN_IFACE} (${tun})"
}

cmd_policy() {
    local policy="open"
    [[ -r "${RUN_VPN_DIR}/policy" ]] && policy="$(tr -d '\r\n' < "${RUN_VPN_DIR}/policy")"
    echo "Agent Policy  : ${policy}"
    local cfg_path="${DEV_INFRA_SINGBOX_STATE_DIR:-/var/lib/sing-box}/config.active.json"
    if [[ -r "$cfg_path" ]]; then
        CFG_PATH="$cfg_path" python3 -c '
import json, os
cfg = json.loads(open(os.environ["CFG_PATH"], encoding="utf-8").read())
rules = (cfg.get("route") or {}).get("rules") or []
exact = []
suffix = []
has_reject = False
for r in rules:
    if not isinstance(r, dict):
        continue
    if r.get("action") == "reject":
        has_reject = True
    if r.get("outbound") == "proxy-select":
        exact.extend(r.get("domain") or [])
        suffix.extend(r.get("domain_suffix") or [])
dns_rules = (cfg.get("dns") or {}).get("rules") or []
dns_reject = any(isinstance(r, dict) and r.get("action") == "reject" for r in dns_rules)
print(f"Route Reject  : {has_reject}")
print(f"DNS Reject    : {dns_reject}")
if exact:
    print("Exact Domains : " + ", ".join(sorted(set(exact))))
if suffix:
    print("Suffixes (" + str(len(set(suffix))) + ") : " + ", ".join(sorted(set(suffix))))
'
    fi
}

usage() {
    cat <<EOF
Usage: vpn-ctl <command> [args]

Commands:
  status                    Show VPN mode, state, policy, resolved node, live egress & errors (read-only)
  policy                    Show active AI-agent domain allowlist policy & effective rules (read-only)
  strict                    Enforce strict IPv4+IPv6+Docker DNS kill-switch + fwmark routing (root/host)
  fallback                  Allow fallback to direct egress if VPN drops (root/host)
  proxy                     Run sing-box as internal HTTP/SOCKS5 proxy on 127.0.0.1:2080 without TUN (root/host)
  direct                    Bypass VPN intentionally (root/host)
  update                    Refresh subscription immediately with TCP pre-probe (root/host)
  retest                    Benchmark all nodes in auto-proxy via Clash API (root/host)
  select [number|node-tag]  Show numbered node list or switch active node via Clash API (root/host)
EOF
}

ACTION="${1:-status}"
shift || true

case "$ACTION" in
    status)           cmd_status ;;
    policy)           cmd_policy ;;
    init)             cmd_init ;;
    strict)           cmd_strict ;;
    fallback)         cmd_fallback ;;
    proxy)            cmd_proxy ;;
    direct)           cmd_direct ;;
    update)           cmd_update ;;
    retest)           cmd_retest ;;
    select)           cmd_select "${1:-}" ;;
    bootstrap-allow)  cmd_bootstrap_allow "${1:-}" ;;
    bootstrap-revoke) cmd_bootstrap_revoke ;;
    -h|--help|help)   usage ;;
    *)
        echo "[vpn-ctl] Unknown command: ${ACTION}" >&2
        usage >&2
        exit 1
        ;;
esac
