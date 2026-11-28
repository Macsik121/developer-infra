#!/usr/bin/env python3
"""
Internal read-only VPN Status Dashboard & JSON API (127.0.0.1:9099).
Runs inside the container (never published to host, never exposes secrets).
- GET /           -> Auto-refreshing HTML status page for Chromium startup tab
- GET /api/status -> JSON telemetry consumed by both browser UI and `vpn-ctl status`
"""

from __future__ import annotations

import html
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple

HOST = os.environ.get("VPN_STATUS_BIND", "127.0.0.1")
PORT = int(os.environ.get("VPN_STATUS_PORT", "9099"))
RUN_VPN_DIR = os.environ.get("DEV_INFRA_RUN_DIR", "/run") + "/vpn"
CLASH_API_URL = os.environ.get("CLASH_API_URL", "http://127.0.0.1:9090")
TUN_IFACE = os.environ.get("VPN_TUN_IFACE", "sing-tun")
SUPERVISOR_LOG_DIR = os.environ.get("DEV_INFRA_SUPERVISOR_LOG_DIR", "/var/log/supervisor")

_EGRESS_LOCK = threading.Lock()
_EGRESS_CACHE: Dict[str, Any] = {
    "ts": 0.0,
    "geoip_ts": 0.0,
    "node": "",
    "data": None,
}
EGRESS_CACHE_TTL = 15.0
GEOIP_CACHE_TTL = 180.0

GEOIP_PROVIDERS: Tuple[Tuple[str, str, str], ...] = (
    ("api.ip.sb", "https://api.ip.sb/geoip", "json"),
    ("ipwho.is", "https://ipwho.is/", "json"),
    ("ipinfo.io", "https://ipinfo.io/json", "json"),
    ("ifconfig.me", "https://ifconfig.me/ip", "text"),
)
CONNECTIVITY_204_URLS: Tuple[str, ...] = (
    "https://www.gstatic.com/generate_204",
    "https://cp.cloudflare.com/generate_204",
)


def read_text(path: str, default: str = "") -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return default


def is_tun_up() -> bool:
    try:
        res = subprocess.run(["ip", "link", "show", TUN_IFACE], capture_output=True, timeout=2)
        return res.returncode == 0
    except Exception:
        return False


def is_singbox_running() -> bool:
    try:
        res = subprocess.run(["pgrep", "-x", "sing-box"], capture_output=True, timeout=2)
        return res.returncode == 0
    except Exception:
        return False


def query_clash_proxies() -> Dict[str, Any]:
    secret = read_text(os.path.join(RUN_VPN_DIR, "clash_secret"))
    if not secret:
        return {}
    req = urllib.request.Request(
        f"{CLASH_API_URL}/proxies",
        headers={"Authorization": f"Bearer {secret}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="ignore"))
            return data.get("proxies", {}) if isinstance(data, dict) else {}
    except Exception:
        return {}


def resolve_active_node(proxies: Dict[str, Any]) -> Tuple[str, str, Optional[int], int, int]:
    """Return (selector_now, resolved_leaf_node, delay_ms, reachable_count, total_nodes)."""
    selector = proxies.get("proxy-select", {})
    sel_now = selector.get("now") or "n/a"

    all_nodes = [
        name for name in (proxies.get("auto-proxy", {}).get("all") or [])
        if name not in {"auto-proxy", "proxy-select", "direct"}
    ]
    reachable = 0
    for name in all_nodes:
        hist = (proxies.get(name) or {}).get("history") or []
        if hist and isinstance(hist[-1].get("delay"), (int, float)) and hist[-1]["delay"] > 0:
            reachable += 1

    leaf = sel_now
    if sel_now == "auto-proxy":
        auto = proxies.get("auto-proxy", {})
        leaf = auto.get("now") or (
            f"selecting ({reachable}/{len(all_nodes)} ready)" if all_nodes else "selecting..."
        )

    leaf_obj = proxies.get(leaf, {})
    delay_ms: Optional[int] = None
    history = leaf_obj.get("history") or []
    if isinstance(history, list) and history:
        last_d = history[-1].get("delay")
        if isinstance(last_d, (int, float)) and last_d > 0:
            delay_ms = int(last_d)

    return sel_now, leaf, delay_ms, reachable, len(all_nodes)


def _parse_geoip_payload(provider: str, kind: str, body: str) -> Optional[Dict[str, str]]:
    text = body.strip()
    if not text:
        return None
    if kind == "text":
        ip_line = text.splitlines()[0].strip()
        if ip_line and len(ip_line) <= 64 and " " not in ip_line and "<" not in ip_line:
            return {"ip": ip_line, "country": "", "org": "", "source": provider}
        return None
    payload = json.loads(text)
    if not isinstance(payload, dict):
        return None
    if payload.get("success") is False:
        return None
    ip = str(payload.get("ip") or "").strip()
    if not ip:
        return None
    country = str(payload.get("country_code") or payload.get("country") or "").strip()
    org = str(payload.get("organization") or payload.get("org") or "").strip()
    if not org and isinstance(payload.get("connection"), dict):
        conn = payload["connection"]
        org = str(conn.get("org") or conn.get("isp") or "").strip()
    if not org and payload.get("isp"):
        org = str(payload.get("isp") or "").strip()
    return {"ip": ip, "country": country, "org": org, "source": provider}


def _http_get_text(url: str, timeout: float = 3.0) -> Tuple[bool, str, str]:
    """Bounded IPv4 HTTPS GET using curl (avoids glibc getaddrinfo blocking)."""
    curl_bin = shutil.which("curl")
    if curl_bin:
        try:
            proc = subprocess.run(
                [
                    curl_bin,
                    "-4",
                    "-fsS",
                    "--max-time",
                    str(int(timeout)),
                    "-H",
                    "User-Agent: developer-infra-status/2.2",
                    "-H",
                    "Accept: application/json, text/plain",
                    url,
                ],
                capture_output=True,
                text=True,
                timeout=timeout + 0.8,
            )
            if proc.returncode == 0:
                return True, proc.stdout, ""
            err_msg = (proc.stderr or proc.stdout or f"curl exit {proc.returncode}").strip()
            return False, "", err_msg.splitlines()[-1][:180] if err_msg else f"curl exit {proc.returncode}"
        except subprocess.TimeoutExpired:
            return False, "", f"egress/DNS probe timed out (>{timeout:.1f}s)"
        except Exception as exc:
            return False, "", str(exc)[:180]

    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "developer-infra-status/2.2", "Accept": "application/json, text/plain"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return True, resp.read().decode("utf-8", errors="ignore"), ""
    except Exception as exc:
        return False, "", str(exc)[:180]


def _probe_http_204(timeout: float = 3.0) -> Tuple[bool, str]:
    """Zero-rate-limit HTTPS connectivity verification (HTTP 204/200)."""
    curl_bin = shutil.which("curl")
    last_err = "no connectivity"
    for url in CONNECTIVITY_204_URLS:
        if curl_bin:
            try:
                proc = subprocess.run(
                    [
                        curl_bin,
                        "-4",
                        "-sS",
                        "--max-time",
                        str(int(timeout)),
                        "-o",
                        "/dev/null",
                        "-w",
                        "%{http_code}",
                        url,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=timeout + 0.8,
                )
                code = (proc.stdout or "").strip()
                if proc.returncode == 0 and code in {"200", "204"}:
                    return True, ""
                err_msg = (proc.stderr or f"HTTP {code or '000'}").strip()
                last_err = err_msg.splitlines()[-1][:180]
                continue
            except subprocess.TimeoutExpired:
                last_err = f"egress/DNS probe timed out (>{timeout:.1f}s)"
                continue
            except Exception as exc:
                last_err = str(exc)[:180]
                continue

        try:
            req = urllib.request.Request(url, headers={"User-Agent": "developer-infra-status/2.2"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if getattr(resp, "status", 200) in {200, 204}:
                    return True, ""
        except Exception as exc:
            last_err = str(exc)[:180]
    return False, last_err


def _probe_egress_once() -> Dict[str, Any]:
    """
    Resilient multi-provider L7 HTTPS egress probe with bounded worst-case latency:
    1. Fast zero-rate-limit HTTPS connectivity check (generate_204). If this fails,
       fail fast (~2.5s) instead of waiting on 4 GeoIP providers over a dead tunnel.
    2. If L7 HTTPS is alive, resolve exit IP/geo via multi-provider fallback within
       a 4s budget so shared-VPN HTTP 429 on ipinfo.io never trips DEGRADED_NO_EGRESS.
    """
    result: Dict[str, Any] = {"ok": False, "ip": "", "country": "", "org": "", "error": ""}

    l7_ok, l7_err = _probe_http_204(timeout=2.5)
    if not l7_ok:
        result["error"] = l7_err or "no egress"
        return result

    deadline = time.monotonic() + 4.0
    any_http_429 = False

    for provider, url, kind in GEOIP_PROVIDERS:
        remaining = deadline - time.monotonic()
        if remaining <= 0.4:
            break
        ok, body, err = _http_get_text(url, timeout=min(2.0, remaining))
        if ok:
            try:
                parsed = _parse_geoip_payload(provider, kind, body)
            except Exception:
                continue
            if parsed:
                result["ok"] = True
                result["ip"] = parsed["ip"]
                result["country"] = parsed["country"]
                result["org"] = parsed["org"]
                result["source"] = parsed["source"]
                return result
        elif "429" in err:
            any_http_429 = True

    result["ok"] = True
    result["ip"] = "verified (GeoIP rate-limited)" if any_http_429 else "verified (HTTP 204)"
    result["country"] = ""
    result["org"] = ""
    result["source"] = "generate_204"
    return result


def probe_egress(force: bool = False, active_node: str = "") -> Dict[str, Any]:
    now = time.monotonic()
    with _EGRESS_LOCK:
        cached = _EGRESS_CACHE["data"]
        cached_ts = _EGRESS_CACHE["ts"]
        geoip_ts = _EGRESS_CACHE["geoip_ts"]
        cached_node = _EGRESS_CACHE["node"]

    same_node = (not active_node) or (cached_node == active_node)
    if not force and cached is not None and same_node and (now - cached_ts) < EGRESS_CACHE_TTL:
        return cached

    # Steady-state L7 check: if GeoIP is fresh for this node, verify via zero-rate-limit 204 probe
    if (
        cached is not None
        and cached.get("ok")
        and cached.get("source") != "generate_204"
        and same_node
        and (now - geoip_ts) < GEOIP_CACHE_TTL
    ):
        l7_ok, l7_err = _probe_http_204(timeout=3.0)
        if l7_ok:
            refreshed = dict(cached)
            with _EGRESS_LOCK:
                _EGRESS_CACHE["ts"] = time.monotonic()
                _EGRESS_CACHE["data"] = refreshed
            return refreshed
        failed = {"ok": False, "ip": "", "country": "", "org": "", "error": l7_err}
        with _EGRESS_LOCK:
            _EGRESS_CACHE["ts"] = time.monotonic()
            _EGRESS_CACHE["data"] = failed
        return failed

    result = _probe_egress_once()
    now_after = time.monotonic()
    with _EGRESS_LOCK:
        _EGRESS_CACHE["ts"] = now_after
        _EGRESS_CACHE["data"] = result
        if result.get("ok") and result.get("source") != "generate_204":
            _EGRESS_CACHE["geoip_ts"] = now_after
            _EGRESS_CACHE["node"] = active_node
    return result


def _background_egress_refresher() -> None:
    while True:
        try:
            proxies = query_clash_proxies()
            _, leaf_node, _, _, _ = resolve_active_node(proxies)
            probe_egress(force=True, active_node=leaf_node)
        except Exception:
            pass
        time.sleep(EGRESS_CACHE_TTL)


def tail_singbox_errors(limit: int = 8) -> List[str]:
    log_path = os.path.join(SUPERVISOR_LOG_DIR, "sing-box.err.log")
    if not os.path.isfile(log_path):
        return []
    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()[-200:]
        errs = [
            re.sub(r"https?://[^\s]+", "<url-redacted>", ln.strip())
            for ln in lines
            if ("ERROR" in ln or "FATAL" in ln or "WARN" in ln)
        ]
        return errs[-limit:]
    except OSError:
        return []


def last_updater_line() -> str:
    log_path = os.path.join(SUPERVISOR_LOG_DIR, "vpn-sub-updater.out.log")
    if not os.path.isfile(log_path):
        return ""
    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
            lines = [ln.strip() for ln in f.readlines()[-40:] if "Parsed subscription:" in ln or "Applied dynamic config" in ln or "failed" in ln.lower()]
        return lines[-1] if lines else ""
    except OSError:
        return ""


def collect_status(force_egress: bool = False, skip_egress: bool = False) -> Dict[str, Any]:
    mode = read_text(os.path.join(RUN_VPN_DIR, "mode"), "strict")
    state = read_text(os.path.join(RUN_VPN_DIR, "state"), "UNKNOWN")
    agent_policy = read_text(os.path.join(RUN_VPN_DIR, "policy"), os.environ.get("VPN_AGENT_POLICY", "open") or "open")
    tun_up = is_tun_up()
    sb_running = is_singbox_running()
    proxies = query_clash_proxies()
    sel_now, leaf_node, delay_ms, reachable_count, total_nodes = resolve_active_node(proxies)
    auto_proxy_now = (proxies.get("auto-proxy") or {}).get("now") or ""
    if skip_egress:
        with _EGRESS_LOCK:
            cached = _EGRESS_CACHE["data"]
        egress = cached or {"ok": False, "ip": "", "country": "", "org": "", "error": "fast-mode (skipped)"}
    else:
        egress = probe_egress(force=force_egress, active_node=leaf_node)

    return {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
        "mode": mode,
        "state": state,
        "agent_policy": agent_policy,
        "tun_iface": TUN_IFACE,
        "tun_up": tun_up,
        "singbox_running": sb_running,
        "selector_now": sel_now,
        "auto_proxy_now": auto_proxy_now,
        "active_node": leaf_node,
        "delay_ms": delay_ms,
        "reachable_nodes": reachable_count,
        "total_nodes": total_nodes,
        "egress": egress,
        "updater_summary": last_updater_line(),
        "recent_errors": tail_singbox_errors(8),
    }


def render_html(st: Dict[str, Any]) -> str:
    state = st["state"]
    egress = st["egress"]
    if state == "UP" and egress.get("ok"):
        badge_bg, badge_fg, headline = "#14532d", "#86efac", "VPN CONNECTED & VERIFIED"
    elif state in {"DEGRADED_NO_EGRESS", "DOWN_STRICT", "KILLSWITCH_ERROR"} or (state == "UP" and not egress.get("ok")):
        badge_bg, badge_fg, headline = "#7f1d1d", "#fca5a5", f"ATTENTION: {state}"
    else:
        badge_bg, badge_fg, headline = "#78350f", "#fde68a", f"MODE: {st['mode'].upper()} ({state})"

    errs_html = "".join(f"<li>{html.escape(e)}</li>" for e in st["recent_errors"]) or "<li>No recent errors</li>"
    delay_str = f"{st['delay_ms']} ms" if st["delay_ms"] is not None else "n/a"
    if egress.get("ok"):
        eg_parts = [html.escape(egress.get("ip") or "verified")]
        if egress.get("country"):
            eg_parts[0] += f" ({html.escape(egress['country'])})"
        if egress.get("org"):
            eg_parts.append(html.escape(egress["org"]))
        egress_str = " — ".join(eg_parts)
    else:
        egress_str = f"FAILED: {html.escape(egress.get('error') or 'no egress')}"

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta http-equiv="refresh" content="8" />
  <title>sing-box VPN Status — developer-infra</title>
  <style>
    body {{ font-family: system-ui, -apple-system, sans-serif; background: #0f172a; color: #e2e8f0; margin: 0; padding: 24px; }}
    .wrap {{ max-width: 820px; margin: 0 auto; }}
    .card {{ background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 20px; margin-bottom: 16px; }}
    .badge {{ display: inline-block; padding: 6px 12px; border-radius: 999px; font-weight: 700; font-size: 13px; background: {badge_bg}; color: {badge_fg}; }}
    h1 {{ margin: 12px 0 4px; font-size: 22px; }}
    .muted {{ color: #94a3b8; font-size: 13px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; margin-top: 16px; }}
    .kv {{ background: #0f172a; border: 1px solid #334155; border-radius: 8px; padding: 12px; }}
    .k {{ font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: #94a3b8; }}
    .v {{ font-size: 15px; font-weight: 600; margin-top: 4px; word-break: break-word; }}
    ul {{ margin: 8px 0 0; padding-left: 18px; font-family: ui-monospace, monospace; font-size: 12px; color: #cbd5e1; }}
    li {{ margin-bottom: 4px; }}
    .links a {{ display: inline-block; margin-right: 12px; margin-top: 8px; padding: 8px 14px; border-radius: 8px; background: #334155; color: #f8fafc; text-decoration: none; font-size: 13px; font-weight: 600; }}
    .links a:hover {{ background: #475569; }}
    code {{ background: #0f172a; padding: 2px 6px; border-radius: 4px; font-size: 12px; }}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <span class="badge">{html.escape(headline)}</span>
      <h1>sing-box Tunnel Status</h1>
      <div class="muted">Updated: {html.escape(st['timestamp'])} &middot; Auto-refreshes every 8s &middot; Internal loopback only (127.0.0.1:9099)</div>
      <div class="grid">
        <div class="kv"><div class="k">Mode / State</div><div class="v">{html.escape(st['mode'])} / {html.escape(st['state'])}</div></div>
        <div class="kv"><div class="k">sing-box / TUN</div><div class="v">{'RUNNING' if st['singbox_running'] else 'STOPPED'} / {'UP' if st['tun_up'] else 'DOWN'}</div></div>
        <div class="kv"><div class="k">Active Node</div><div class="v">{html.escape(st['active_node'])} ({delay_str})</div></div>
        <div class="kv"><div class="k">Reachable Nodes</div><div class="v">{st['reachable_nodes']} / {st['total_nodes']}</div></div>
        <div class="kv" style="grid-column: 1 / -1;"><div class="k">Agent Egress Policy</div><div class="v">{html.escape(str(st.get('agent_policy', 'open')))}</div></div>
        <div class="kv" style="grid-column: 1 / -1;"><div class="k">Live Egress</div><div class="v">{egress_str}</div></div>
      </div>
      <div class="links">
        <a href="/?refresh=1">Refresh Now</a>
        <a href="https://ipinfo.io" target="_blank" rel="noreferrer">Open ipinfo.io</a>
        <a href="https://ipleak.net" target="_blank" rel="noreferrer">DNS / WebRTC Leak Test</a>
        <a href="http://127.0.0.1:{os.environ.get('OMNIROUTE_PORT', '20128')}" target="_blank" rel="noreferrer">OmniRoute UI</a>
      </div>
    </div>
    <div class="card">
      <div class="k">Recent sing-box warnings / errors</div>
      <ul>{errs_html}</ul>
      <p class="muted" style="margin-top:12px;">
        Host controls: <code>vpn-ctl status</code> &middot; <code>vpn-ctl select</code> &middot; <code>vpn-ctl retest</code> &middot; <code>vpn-ctl strict / proxy / direct</code>
      </p>
    </div>
  </div>
</body>
</html>
"""


class StatusHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        return

    def _send_bytes(self, status: int, content_type: str, body: bytes) -> None:
        try:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(parsed.query)
        force = q.get("refresh", ["0"])[0] == "1"
        fast = q.get("fast", ["0"])[0] == "1"

        if parsed.path == "/healthz":
            self._send_bytes(200, "application/json; charset=utf-8", b'{"status":"ok"}\n')
            return

        if parsed.path == "/api/status":
            data = collect_status(force_egress=force, skip_egress=fast)
            body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
            self._send_bytes(200, "application/json; charset=utf-8", body)
            return

        if parsed.path in {"/", "/index.html", "/status"}:
            data = collect_status(force_egress=force, skip_egress=fast)
            body = render_html(data).encode("utf-8")
            self._send_bytes(200, "text/html; charset=utf-8", body)
            return

        try:
            self.send_response(404)
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main() -> None:
    threading.Thread(target=_background_egress_refresher, name="egress-refresher", daemon=True).start()
    server = ThreadingHTTPServer((HOST, PORT), StatusHandler)
    print(f"[vpn-status] Listening on http://{HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

