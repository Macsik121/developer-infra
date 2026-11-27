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
import subprocess
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

_EGRESS_CACHE: Dict[str, Any] = {"ts": 0.0, "data": None}
EGRESS_CACHE_TTL = 15.0


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
    leaf = sel_now
    if sel_now == "auto-proxy":
        auto = proxies.get("auto-proxy", {})
        leaf = auto.get("now") or "auto-proxy (selecting...)"

    leaf_obj = proxies.get(leaf, {})
    delay_ms: Optional[int] = None
    history = leaf_obj.get("history") or []
    if isinstance(history, list) and history:
        last_d = history[-1].get("delay")
        if isinstance(last_d, (int, float)) and last_d > 0:
            delay_ms = int(last_d)

    all_nodes = [
        name for name in (proxies.get("auto-proxy", {}).get("all") or [])
        if name not in {"auto-proxy", "proxy-select", "direct"}
    ]
    reachable = 0
    for name in all_nodes:
        hist = (proxies.get(name) or {}).get("history") or []
        if hist and isinstance(hist[-1].get("delay"), (int, float)) and hist[-1]["delay"] > 0:
            reachable += 1

    return sel_now, leaf, delay_ms, reachable, len(all_nodes)


def probe_egress(force: bool = False) -> Dict[str, Any]:
    now = time.monotonic()
    if not force and _EGRESS_CACHE["data"] is not None and (now - _EGRESS_CACHE["ts"]) < EGRESS_CACHE_TTL:
        return _EGRESS_CACHE["data"]

    result: Dict[str, Any] = {"ok": False, "ip": "", "country": "", "org": "", "error": ""}
    try:
        req = urllib.request.Request(
            "https://ipinfo.io/json",
            headers={"User-Agent": "developer-infra-status/2.1", "Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            payload = json.loads(resp.read().decode("utf-8", errors="ignore"))
            result["ok"] = True
            result["ip"] = str(payload.get("ip", ""))
            result["country"] = str(payload.get("country", ""))
            result["org"] = str(payload.get("org", ""))
    except Exception as exc:
        result["error"] = str(exc)[:180]

    _EGRESS_CACHE["ts"] = now
    _EGRESS_CACHE["data"] = result
    return result


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
    tun_up = is_tun_up()
    sb_running = is_singbox_running()
    proxies = query_clash_proxies()
    sel_now, leaf_node, delay_ms, reachable_count, total_nodes = resolve_active_node(proxies)
    if skip_egress:
        egress = _EGRESS_CACHE["data"] or {"ok": False, "ip": "", "country": "", "org": "", "error": "fast-mode (skipped)"}
    else:
        egress = probe_egress(force=force_egress)

    return {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
        "mode": mode,
        "state": state,
        "tun_iface": TUN_IFACE,
        "tun_up": tun_up,
        "singbox_running": sb_running,
        "selector_now": sel_now,
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
    egress_str = (
        f"{html.escape(egress['ip'])} ({html.escape(egress['country'])}) — {html.escape(egress['org'])}"
        if egress.get("ok")
        else f"FAILED: {html.escape(egress.get('error') or 'no egress')}"
    )

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
        <div class="kv" style="grid-column: 1 / -1;"><div class="k">Live Egress (ipinfo.io)</div><div class="v">{egress_str}</div></div>
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
        Host controls: <code>vpn-ctl status</code> &middot; <code>vpn-ctl select</code> &middot; <code>vpn-ctl retest</code> &middot; <code>vpn-ctl strict | proxy | direct</code>
      </p>
    </div>
  </div>
</body>
</html>
"""


class StatusHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        return

    def do_GET(self) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(parsed.query)
        force = q.get("refresh", ["0"])[0] == "1"
        fast = q.get("fast", ["0"])[0] == "1"

        if parsed.path == "/healthz":
            body = b'{"status":"ok"}\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path == "/api/status":
            data = collect_status(force_egress=force, skip_egress=fast)
            body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path in {"/", "/index.html", "/status"}:
            data = collect_status(force_egress=force, skip_egress=fast)
            body = render_html(data).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), StatusHandler)
    print(f"[vpn-status] Listening on http://{HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
