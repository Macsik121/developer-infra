#!/usr/bin/env python3
"""
Dynamic sing-box 1.12 subscription updater for developer-infra (D5, F7, F8, Patch v2.1).

Features:
- Parses plain or base64 URI lists containing vless:// (TCP Reality, gRPC TLS)
  and hysteria2:// (obfs, alpn, sni, insecure) links.
- Enforces 5 MB download cap, 15s timeout, SSRF host filtering, deduplication,
  VPN_ALLOW_INSECURE=0 default (treating vless `pcs=` pinned self-signed certs
  under the same policy), RU/bridge deprioritization, balanced multi-protocol
  selection, optional parallel TCP reachability pre-probe (SO_MARK=255),
  regex include/exclude filters, and VPN_MAX_NODES=30 cap.
- Preserves Chesterton's Fence invariants: stack="gvisor", configurable MTU
  (default 1280 for nested-VPN safety), route.default_mark=255, internal
  127.0.0.1:2080 mixed proxy inbound (and proxy-only mode without tun-in),
  cache_file="/var/lib/sing-box/cache.db", and authenticated Clash API.
- Validates candidate configs atomically via `sing-box check` before swapping,
  with 3-step cold-start fallback (subscription -> last-good -> static config).
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import hashlib
import http.client
import ipaddress
import json
import os
import random
import re
import signal
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

MAX_SUB_BYTES = 5 * 1024 * 1024  # 5 MB cap (ST-5)
FETCH_TIMEOUT = 15  # seconds
SO_MARK = 36  # Linux socket option for fwmark (0xff = 255)
DEFAULT_FWMARK = 255
# RFC 2544 / Clash standard TUN range — never allocated by Docker bridge networks (172.17-31.x.x).
DEFAULT_TUN_ADDRESS = "198.18.0.1/30"
FALLBACK_TUN_ADDRESSES = (
    "198.18.0.1/30",
    "198.19.0.1/30",
    "100.64.254.1/30",
    "100.65.254.1/30",
)

# RU/BY mobile/bridge nodes commonly drop TCP SYN when reached through another VPN/foreign IP.
LOW_PRIORITY_TAG_RE = re.compile(
    r"(lte\s*авто|мост|россия|беларусь|\bru\b|\bby\b|mobile|whitelist)",
    re.IGNORECASE,
)

RUN_VPN_DIR = os.environ.get("DEV_INFRA_RUN_DIR", "/run") + "/vpn"
STATE_DIR = os.environ.get("DEV_INFRA_SINGBOX_STATE_DIR", "/var/lib/sing-box")
ETC_SINGBOX_DIR = os.environ.get("DEV_INFRA_ETC_SINGBOX_DIR", "/etc/sing-box")
SING_BOX_BIN = os.environ.get("SING_BOX_BIN", "/usr/local/bin/sing-box")
VPN_CTL_BIN = os.environ.get("VPN_CTL_BIN", "/usr/local/bin/vpn-ctl")

# WP-3 (D12): Opt-in AI-agent domain allowlist presets (used only when VPN_AGENT_POLICY=allowlist)
INTERNAL_INFRA_EXACT_DOMAINS: Tuple[str, ...] = (
    "api.ip.sb",
    "ipwho.is",
    "ipinfo.io",
    "ifconfig.me",
    "www.gstatic.com",
    "cp.cloudflare.com",
)
AGENT_POLICY_PRESETS: Dict[str, Tuple[str, ...]] = {
    "ai": (
        "anthropic.com",
        "claude.ai",
        "openai.com",
        "googleapis.com",
        "openrouter.ai",
        "deepseek.com",
        "nvidia.com",
        "huggingface.co",
        "hf.co",
    ),
    "git": (
        "github.com",
        "githubusercontent.com",
        "githubassets.com",
        "github.io",
        "gitlab.com",
        "bitbucket.org",
    ),
    "pkg": (
        "npmjs.org",
        "npmjs.com",
        "yarnpkg.com",
        "pypi.org",
        "pythonhosted.org",
        "ubuntu.com",
        "debian.org",
        "launchpad.net",
        "docker.io",
        "docker.com",
        "ghcr.io",
        "crates.io",
        "pkg.go.dev",
        "proxy.golang.org",
    ),
    "docs": (
        "stackoverflow.com",
        "mozilla.org",
        "python.org",
        "nodejs.org",
        "postgresql.org",
        "kubernetes.io",
    ),
}
_VALID_DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"
)
_DNS_REJECT_QTYPES: List[str] = ["A", "AAAA", "CNAME", "HTTPS", "SVCB", "TXT", "SRV", "MX"]


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] [vpn-sub-updater] {msg}", flush=True)


def redact_url(url: str) -> str:
    """Redact credentials, path tokens, and query parameters from subscription URLs."""
    try:
        parsed = urllib.parse.urlsplit(url.strip())
        if not parsed.scheme or not parsed.hostname:
            return "<redacted-url>"
        port_part = f":{parsed.port}" if parsed.port else ""
        return f"{parsed.scheme}://{parsed.hostname}{port_part}/<redacted>"
    except Exception:
        return "<redacted-url>"


def is_truthy(val: Optional[str]) -> bool:
    if val is None:
        return False
    return val.strip().lower() in {"1", "true", "yes", "on"}


def is_ssrf_host(host: str) -> bool:
    """Reject loopback, unspecified, link-local, and localhost targets (ST-5)."""
    if not host:
        return True
    cleaned = host.strip().lower().strip("[]")
    if cleaned in {"localhost", "localhost.localdomain", "ip6-localhost", "ip6-loopback"}:
        return True
    if cleaned.endswith(".localhost"):
        return True
    try:
        ip = ipaddress.ip_address(cleaned)
        if ip.is_loopback or ip.is_unspecified or ip.is_link_local or ip.is_multicast:
            return True
    except ValueError:
        if any(ch.isspace() or ord(ch) < 32 for ch in cleaned):
            return True
    return False


def decode_subscription_payload(raw_bytes: bytes) -> List[str]:
    """Decode plain URI list or base64-encoded URI list into raw URI lines."""
    text = raw_bytes.decode("utf-8", errors="ignore").strip()
    if not text:
        return []

    def extract_uris(content: str) -> List[str]:
        return [
            line.strip()
            for line in content.splitlines()
            if line.strip() and "://" in line and not line.strip().startswith("#")
        ]

    direct_lines = extract_uris(text)
    if direct_lines:
        return direct_lines

    compact = re.sub(r"\s+", "", text)
    padding = (-len(compact)) % 4
    padded = compact + ("=" * padding)
    for decoder in (base64.b64decode, base64.urlsafe_b64decode):
        try:
            decoded = decoder(padded).decode("utf-8", errors="ignore")
            lines = extract_uris(decoded)
            if lines:
                return lines
        except Exception:
            continue
    return []


def sanitize_tag(raw_tag: str, fallback: str) -> str:
    tag = urllib.parse.unquote(raw_tag or "").strip()
    tag = re.sub(r"[\r\n\t]+", " ", tag)
    tag = re.sub(r"[^\w\-\.\s\(\)\[\]/:+@]+", "", tag)
    tag = re.sub(r"\s+", " ", tag).strip()
    return tag[:64] if tag else fallback


def is_low_priority_tag(tag: str) -> bool:
    return bool(LOW_PRIORITY_TAG_RE.search(tag or ""))


def parse_vless_uri(
    uri: str, allow_insecure: bool, stats: Dict[str, int]
) -> Optional[Dict[str, Any]]:
    """
    Parse vless:// URIs matching observed F8 signatures:
    1. TCP + Reality: [encryption,flow,fp,headerType,pbk,security,sid,sni,type]
    2. gRPC + TLS + pcs (pinned self-signed cert SHA256): [encryption,fp,mode,pcs,security,serviceName,sni,type]
    3. gRPC + TLS + allowInsecure: [allowInsecure,encryption,fp,mode,security,serviceName,sni,type]
    """
    try:
        parsed = urllib.parse.urlsplit(uri)
    except ValueError:
        stats["skipped_invalid"] += 1
        return None

    uuid = urllib.parse.unquote(parsed.username or "").strip()
    host = parsed.hostname or ""
    try:
        port = parsed.port or 443
    except ValueError:
        stats["skipped_invalid"] += 1
        return None

    if not uuid or not host or not (1 <= port <= 65535):
        stats["skipped_invalid"] += 1
        return None
    if is_ssrf_host(host):
        stats["skipped_ssrf"] += 1
        return None

    q = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query, keep_blank_values=True).items()}
    security = (q.get("security") or "").strip().lower()
    net_type = (q.get("type") or "tcp").strip().lower()
    sni = (q.get("sni") or host).strip()
    fp = (q.get("fp") or "").strip()
    flow = (q.get("flow") or "").strip()
    # urllib.parse.parse_qs turns unescaped '+' in query strings into spaces;
    # restore '+' so standard-base64 Reality public keys are never corrupted.
    pbk = (q.get("pbk") or "").strip().replace(" ", "+")
    sid = (q.get("sid") or "").strip()
    alpn_raw = (q.get("alpn") or "").strip()
    pcs = (q.get("pcs") or "").strip()
    service_name = (q.get("serviceName") or q.get("path") or "").strip()

    # Non-empty `pcs` indicates a self-signed cert pin (Xray-specific); sing-box 1.12
    # cannot verify it via system CA without tls.insecure, so treat under allow_insecure.
    insecure_flag = (
        is_truthy(q.get("allowInsecure"))
        or is_truthy(q.get("insecure"))
        or (security == "tls" and bool(pcs))
    )

    if insecure_flag and not allow_insecure:
        stats["skipped_insecure"] += 1
        return None

    tag = sanitize_tag(parsed.fragment, f"vless-{host}-{port}")
    outbound: Dict[str, Any] = {
        "type": "vless",
        "tag": tag,
        "server": host,
        "server_port": port,
        "uuid": uuid,
        "domain_resolver": "dns-direct",
    }

    if flow and net_type == "tcp":
        outbound["flow"] = flow

    if security in {"tls", "reality"}:
        tls_cfg: Dict[str, Any] = {
            "enabled": True,
            "server_name": sni,
        }
        if security == "reality":
            if not pbk:
                stats["skipped_invalid"] += 1
                return None
            # sing-box requires uTLS enabled for Reality; default to chrome if URI omitted fp=
            tls_cfg["utls"] = {"enabled": True, "fingerprint": fp or "chrome"}
            reality_cfg: Dict[str, Any] = {
                "enabled": True,
                "public_key": pbk,
            }
            if sid:
                reality_cfg["short_id"] = sid
            tls_cfg["reality"] = reality_cfg
        else:
            if fp:
                tls_cfg["utls"] = {"enabled": True, "fingerprint": fp}
            if alpn_raw:
                alpn_list = [item.strip() for item in alpn_raw.split(",") if item.strip()]
                if alpn_list:
                    tls_cfg["alpn"] = alpn_list
            if insecure_flag and allow_insecure:
                tls_cfg["insecure"] = True
        outbound["tls"] = tls_cfg

    if net_type == "grpc":
        transport: Dict[str, Any] = {"type": "grpc"}
        if service_name:
            transport["service_name"] = service_name
        outbound["transport"] = transport
    elif net_type == "ws":
        transport = {"type": "ws"}
        if q.get("path"):
            transport["path"] = q["path"]
        if q.get("host"):
            transport["headers"] = {"Host": q["host"]}
        outbound["transport"] = transport
    elif net_type not in {"tcp", ""}:
        stats["skipped_unsupported"] += 1
        return None

    return outbound


def parse_hysteria2_uri(
    uri: str, allow_insecure: bool, stats: Dict[str, int]
) -> Optional[Dict[str, Any]]:
    """
    Parse hysteria2:// (or hy2://) URIs matching observed F8 signatures:
    - [alpn,insecure,obfs,obfs-password,sni]
    - [insecure,obfs,obfs-password,sni]
    - [alpn,insecure,sni]
    """
    try:
        parsed = urllib.parse.urlsplit(uri)
    except ValueError:
        stats["skipped_invalid"] += 1
        return None

    password = urllib.parse.unquote(parsed.username or "").strip()
    if parsed.password:
        password = f"{password}:{urllib.parse.unquote(parsed.password)}"
    host = parsed.hostname or ""
    try:
        port = parsed.port or 443
    except ValueError:
        stats["skipped_invalid"] += 1
        return None

    if not password or not host or not (1 <= port <= 65535):
        stats["skipped_invalid"] += 1
        return None
    if is_ssrf_host(host):
        stats["skipped_ssrf"] += 1
        return None

    q = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query, keep_blank_values=True).items()}
    sni = (q.get("sni") or host).strip()
    alpn_raw = (q.get("alpn") or "").strip()
    obfs_type = (q.get("obfs") or "").strip()
    obfs_pass = (q.get("obfs-password") or "").strip()
    insecure_flag = is_truthy(q.get("insecure")) or is_truthy(q.get("allowInsecure"))

    if insecure_flag and not allow_insecure:
        stats["skipped_insecure"] += 1
        return None

    tag = sanitize_tag(parsed.fragment, f"hy2-{host}-{port}")
    tls_cfg: Dict[str, Any] = {
        "enabled": True,
        "server_name": sni,
    }
    if alpn_raw:
        alpn_list = [item.strip() for item in alpn_raw.split(",") if item.strip()]
        if alpn_list:
            tls_cfg["alpn"] = alpn_list
    if insecure_flag and allow_insecure:
        tls_cfg["insecure"] = True

    outbound: Dict[str, Any] = {
        "type": "hysteria2",
        "tag": tag,
        "server": host,
        "server_port": port,
        "password": password,
        "domain_resolver": "dns-direct",
        "tls": tls_cfg,
    }

    if obfs_type:
        outbound["obfs"] = {
            "type": obfs_type,
            "password": obfs_pass,
        }

    return outbound


def _select_balanced_nodes(
    parsed_nodes: List[Dict[str, Any]],
    protocol_order: List[str],
    max_nodes: int,
) -> List[Dict[str, Any]]:
    """
    Order nodes by priority (standard international nodes before RU/LTE/bridge nodes)
    and select a balanced mix across available protocols in protocol_order:
    - Primary protocol gets at least 70% of slots (when available).
    - Secondary protocols get up to 30% of slots (min 1 each if max_nodes >= 3),
      so both VLESS (TCP) and Hysteria2 (UDP/QUIC) are present in the active pool.
    """
    cap = max(1, max_nodes)
    order = [p.strip().lower() for p in protocol_order if p.strip()]
    if not order:
        order = ["vless", "hysteria2"]

    buckets: Dict[str, List[Dict[str, Any]]] = {p: [] for p in order}
    other: List[Dict[str, Any]] = []
    for node in parsed_nodes:
        proto = node["type"]
        if proto in buckets:
            buckets[proto].append(node)
        else:
            other.append(node)

    # Stable sort within each protocol bucket: normal nodes first, RU/bridge/LTE last
    for proto in buckets:
        buckets[proto].sort(key=lambda n: 1 if is_low_priority_tag(n["tag"]) else 0)
    other.sort(key=lambda n: 1 if is_low_priority_tag(n["tag"]) else 0)

    present_protos = [p for p in order if buckets[p]]
    if not present_protos:
        return other[:cap]

    if len(present_protos) == 1 or cap < 3:
        combined: List[Dict[str, Any]] = []
        for p in present_protos:
            combined.extend(buckets[p])
        combined.extend(other)
        return combined[:cap]

    primary = present_protos[0]
    secondaries = present_protos[1:]
    sec_budget_total = max(1, int(cap * 0.30))
    sec_selected: List[Dict[str, Any]] = []

    # Round-robin pick from secondary protocols up to secondary budget
    sec_cursors = {p: 0 for p in secondaries}
    while len(sec_selected) < sec_budget_total:
        progressed = False
        for p in secondaries:
            if len(sec_selected) >= sec_budget_total:
                break
            idx = sec_cursors[p]
            if idx < len(buckets[p]):
                sec_selected.append(buckets[p][idx])
                sec_cursors[p] = idx + 1
                progressed = True
        if not progressed:
            break

    primary_budget = cap - len(sec_selected)
    prim_selected = buckets[primary][:primary_budget]
    selected = prim_selected + sec_selected

    # Fill any remaining slots if primary had fewer nodes than its budget
    if len(selected) < cap:
        leftovers: List[Dict[str, Any]] = []
        leftovers.extend(buckets[primary][len(prim_selected):])
        for p in secondaries:
            leftovers.extend(buckets[p][sec_cursors[p]:])
        leftovers.extend(other)
        selected.extend(leftovers[: cap - len(selected)])

    return selected[:cap]


def _assign_unique_tags(nodes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    used_tags = {"proxy-select", "auto-proxy", "direct"}
    for node in nodes:
        base_tag = node["tag"]
        candidate = base_tag
        suffix = 2
        while candidate in used_tags:
            candidate = f"{base_tag}-{suffix}"
            suffix += 1
        node["tag"] = candidate
        used_tags.add(candidate)
    return nodes


def parse_subscription_uris(
    uris: List[str],
    allow_insecure: bool = False,
    node_filter: str = "",
    node_exclude: str = "",
    protocol_order: Optional[List[str]] = None,
    max_nodes: int = 30,
) -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    """Parse, validate, filter, deduplicate, prioritize, balance, and cap subscription URIs."""
    stats: Dict[str, int] = {
        "total_uris": len(uris),
        "parsed": 0,
        "skipped_insecure": 0,
        "skipped_ssrf": 0,
        "skipped_invalid": 0,
        "skipped_unsupported": 0,
        "skipped_filtered": 0,
        "skipped_duplicate": 0,
        "selected": 0,
    }

    inc_re = re.compile(node_filter, re.IGNORECASE) if node_filter.strip() else None
    exc_re = re.compile(node_exclude, re.IGNORECASE) if node_exclude.strip() else None

    seen_keys = set()
    parsed_nodes: List[Dict[str, Any]] = []

    for uri in uris:
        scheme = uri.split("://", 1)[0].strip().lower()
        node: Optional[Dict[str, Any]] = None
        if scheme == "vless":
            node = parse_vless_uri(uri, allow_insecure, stats)
        elif scheme in {"hysteria2", "hy2"}:
            node = parse_hysteria2_uri(uri, allow_insecure, stats)
        else:
            stats["skipped_unsupported"] += 1
            continue

        if node is None:
            continue

        stats["parsed"] += 1
        tag = node["tag"]

        if inc_re and not inc_re.search(tag):
            stats["skipped_filtered"] += 1
            continue
        if exc_re and exc_re.search(tag):
            stats["skipped_filtered"] += 1
            continue

        dedup_key = (
            node["type"],
            node["server"].lower(),
            node["server_port"],
            node.get("uuid") or node.get("password") or "",
            (node.get("tls") or {}).get("server_name", ""),
            (node.get("transport") or {}).get("service_name", ""),
        )
        if dedup_key in seen_keys:
            stats["skipped_duplicate"] += 1
            continue
        seen_keys.add(dedup_key)
        parsed_nodes.append(node)

    order = [p.strip().lower() for p in (protocol_order or ["vless", "hysteria2"]) if p.strip()]
    capped = _select_balanced_nodes(parsed_nodes, order, max_nodes=max_nodes)
    _assign_unique_tags(capped)

    stats["selected"] = len(capped)
    return capped, stats


def _encode_dns_query(hostname: str, txid: int) -> bytes:
    header = struct.pack("!HHHHHH", txid, 0x0100, 1, 0, 0, 0)
    labels = b"".join(
        bytes([len(part)]) + part.encode("ascii")
        for part in hostname.strip(".").split(".")
        if part
    )
    return header + labels + b"\x00" + struct.pack("!HH", 1, 1)  # QTYPE=A, QCLASS=IN


def _skip_dns_name(packet: bytes, offset: int) -> int:
    n = len(packet)
    while offset < n:
        length = packet[offset]
        if length == 0:
            return offset + 1
        if (length & 0xC0) == 0xC0:
            return offset + 2
        offset += 1 + length
    return n


def _parse_dns_a_response(packet: bytes, expected_txid: int) -> List[str]:
    if len(packet) < 12:
        return []
    txid, _flags, qdcount, ancount, _nscount, _arcount = struct.unpack("!HHHHHH", packet[:12])
    if txid != expected_txid:
        return []
    offset = 12
    for _ in range(qdcount):
        offset = _skip_dns_name(packet, offset)
        offset += 4  # QTYPE + QCLASS
    ips: List[str] = []
    for _ in range(ancount):
        if offset >= len(packet):
            break
        offset = _skip_dns_name(packet, offset)
        if offset + 10 > len(packet):
            break
        rtype, rclass, _ttl, rdlength = struct.unpack("!HHIH", packet[offset : offset + 10])
        offset += 10
        if offset + rdlength > len(packet):
            break
        if rtype == 1 and rclass == 1 and rdlength == 4:
            ips.append(str(ipaddress.IPv4Address(packet[offset : offset + 4])))
        offset += rdlength
    return ips


def _resolve_ipv4_marked(
    host: str,
    dns_servers: Tuple[str, ...] = ("1.1.1.1", "8.8.8.8"),
    timeout: float = 2.0,
    fwmark: int = DEFAULT_FWMARK,
) -> List[str]:
    """
    Resolve an IPv4 address using UDP/53 with SO_MARK=255 so DNS bypasses a dead sing-tun
    and Docker's 127.0.0.11 resolver during dead-tunnel recovery and TCP pre-probing.
    """
    cleaned = host.strip().strip("[]")
    try:
        ipaddress.IPv4Address(cleaned)
        return [cleaned]
    except ValueError:
        pass

    for server in dns_servers:
        txid = random.randint(1, 65534)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.settimeout(timeout)
            try:
                sock.setsockopt(socket.SOL_SOCKET, SO_MARK, fwmark)
            except OSError:
                pass
            sock.sendto(_encode_dns_query(cleaned, txid), (server, 53))
            resp, _ = sock.recvfrom(1500)
            ips = _parse_dns_a_response(resp, txid)
            if ips:
                return ips
        except OSError:
            continue
        finally:
            try:
                sock.close()
            except OSError:
                pass
    return []


def get_host_ipv4_networks(exclude_ifaces: Tuple[str, ...] = ("lo", "sing-tun")) -> List[ipaddress.IPv4Network]:
    """Return IPv4 networks currently assigned to container non-TUN interfaces (e.g. eth0)."""
    nets: List[ipaddress.IPv4Network] = []
    try:
        res = subprocess.run(
            ["ip", "-4", "-o", "addr", "show"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if res.returncode != 0:
            return nets
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            iface = parts[1].split("@")[0]
            if iface in exclude_ifaces:
                continue
            for idx, tok in enumerate(parts):
                if tok == "inet" and idx + 1 < len(parts):
                    try:
                        nets.append(ipaddress.ip_network(parts[idx + 1], strict=False))
                    except ValueError:
                        pass
                    break
    except Exception:
        pass
    return nets


def tun_cidr_overlaps(cidr: str, existing_nets: List[ipaddress.IPv4Network]) -> bool:
    try:
        tun_net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return True
    if not isinstance(tun_net, ipaddress.IPv4Network):
        return False
    return any(tun_net.overlaps(net) for net in existing_nets)


def pick_safe_tun_address(
    preferred: str = DEFAULT_TUN_ADDRESS,
    existing_nets: Optional[List[ipaddress.IPv4Network]] = None,
) -> str:
    """Pick a /30 TUN interface CIDR guaranteed not to collide with Docker's eth0 bridge subnet."""
    nets = get_host_ipv4_networks() if existing_nets is None else existing_nets
    candidates = [preferred, *FALLBACK_TUN_ADDRESSES]
    for cand in candidates:
        if not cand:
            continue
        if not tun_cidr_overlaps(cand, nets):
            return cand
    return DEFAULT_TUN_ADDRESS


def _probe_single_node(node: Dict[str, Any], timeout: float = 1.5, fwmark: int = DEFAULT_FWMARK) -> Tuple[bool, float]:
    """
    Verify upstream reachability using SO_MARK=255 so probes bypass sing-tun.
    - TCP protocols (vless): real TCP connect handshake.
    - UDP protocols (hysteria2): verify IP/DNS resolvability (cannot TCP-probe QUIC).
    """
    host = node["server"]
    port = int(node["server_port"])
    t0 = time.monotonic()

    if node["type"] == "hysteria2":
        if _resolve_ipv4_marked(host, timeout=min(timeout, 1.5), fwmark=fwmark):
            return True, (time.monotonic() - t0) * 1000.0
        try:
            socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)
            return True, (time.monotonic() - t0) * 1000.0
        except OSError:
            return False, 9999.0

    target_ips = _resolve_ipv4_marked(host, timeout=min(timeout, 1.5), fwmark=fwmark)
    if not target_ips:
        try:
            infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
            target_ips = [info[4][0] for info in infos[:2]]
        except OSError:
            return False, 9999.0

    for ip_str in target_ips[:2]:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.settimeout(timeout)
            try:
                sock.setsockopt(socket.SOL_SOCKET, SO_MARK, fwmark)
            except OSError:
                pass
            sock.connect((ip_str, port))
            return True, (time.monotonic() - t0) * 1000.0
        except OSError:
            continue
        finally:
            try:
                sock.close()
            except OSError:
                pass
    return False, 9999.0


def probe_reachable_nodes(
    candidates: List[Dict[str, Any]],
    protocol_order: List[str],
    max_nodes: int = 30,
    timeout: float = 1.5,
    max_workers: int = 24,
) -> Tuple[List[Dict[str, Any]], int, int]:
    """
    Probe up to 120 prioritized candidates in parallel and pick the fastest reachable nodes
    preserving protocol balance. Falls back to unprobed list if 0 succeed.
    Returns (selected_nodes, probed_count, reachable_count).
    """
    if not candidates:
        return [], 0, 0

    probe_pool = candidates[: min(len(candidates), max(max_nodes * 4, 120))]
    results: List[Tuple[Dict[str, Any], float]] = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=min(max_workers, len(probe_pool))) as pool:
        future_map = {pool.submit(_probe_single_node, node, timeout): node for node in probe_pool}
        for fut in concurrent.futures.as_completed(future_map):
            node = future_map[fut]
            try:
                ok, rtt_ms = fut.result()
                if ok:
                    results.append((node, rtt_ms))
            except Exception:
                continue

    if not results:
        fallback = _select_balanced_nodes(candidates, protocol_order, max_nodes=max_nodes)
        return _assign_unique_tags(fallback), len(probe_pool), 0

    # Sort reachable nodes by (low_priority_flag, rtt_ms)
    results.sort(key=lambda item: (1 if is_low_priority_tag(item[0]["tag"]) else 0, item[1]))
    reachable_nodes = [item[0] for item in results]
    selected = _select_balanced_nodes(reachable_nodes, protocol_order, max_nodes=max_nodes)
    _assign_unique_tags(selected)
    return selected, len(probe_pool), len(reachable_nodes)


def _normalize_domain_entry(raw: str) -> Tuple[Optional[str], bool]:
    """
    Validate and normalize a domain allowlist entry.
    Returns (domain, is_exact):
      - '=host.example.com' -> ('host.example.com', True)
      - '*.example.com' or '.example.com' or 'example.com' -> ('example.com', False)
      - Invalid / wildcard-only / IP / SSRF -> (None, False)
    """
    token = (raw or "").strip().lower()
    if not token:
        return None, False
    is_exact = False
    if token.startswith("="):
        is_exact = True
        token = token[1:].strip()
    elif token.startswith("*."):
        token = token[2:].strip()
    elif token.startswith("."):
        token = token[1:].strip()
    token = token.rstrip(".")
    if not token or "*" in token or "/" in token or ":" in token:
        return None, False
    if is_ssrf_host(token):
        return None, False
    try:
        ipaddress.ip_address(token)
        return None, False
    except ValueError:
        pass
    if not _VALID_DOMAIN_RE.match(token):
        return None, False
    return token, is_exact


def resolve_agent_policy(
    policy: str = "open",
    presets_raw: str = "ai,git,pkg",
    custom_domains_raw: str = "",
    extra_exact_domains: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """
    Resolve VPN_AGENT_POLICY ('open' | 'allowlist') into normalized exact & suffix domain lists.
    Default 'open' preserves unrestricted VPN egress with zero extra rules.
    """
    mode = (policy or "open").strip().lower()
    if mode not in {"open", "allowlist"}:
        log(f"Warning: unknown VPN_AGENT_POLICY '{mode}'; defaulting to 'open'")
        mode = "open"

    if mode == "open":
        return {
            "policy": "open",
            "presets": [],
            "exact_domains": [],
            "suffix_domains": [],
            "invalid_entries": [],
            "summary": "open",
        }

    chosen_presets: List[str] = []
    invalid_entries: List[str] = []
    suffix_set = set()
    exact_set = set(INTERNAL_INFRA_EXACT_DOMAINS)

    for raw_preset in (presets_raw or "").split(","):
        p = raw_preset.strip().lower()
        if not p or p == "none":
            continue
        if p in AGENT_POLICY_PRESETS:
            if p not in chosen_presets:
                chosen_presets.append(p)
            suffix_set.update(AGENT_POLICY_PRESETS[p])
        else:
            invalid_entries.append(f"preset:{p}")

    for raw_dom in (custom_domains_raw or "").split(","):
        if not raw_dom.strip():
            continue
        dom, is_exact = _normalize_domain_entry(raw_dom)
        if dom is None:
            invalid_entries.append(raw_dom.strip())
            continue
        if is_exact:
            exact_set.add(dom)
        else:
            suffix_set.add(dom)

    for extra in extra_exact_domains or []:
        dom, _ = _normalize_domain_entry(f"={extra}")
        if dom:
            exact_set.add(dom)

    # Remove exact domains already covered by an allowed suffix to keep rules compact
    exact_domains = sorted(
        d for d in exact_set if not any(d == s or d.endswith("." + s) for s in suffix_set)
    )
    suffix_domains = sorted(suffix_set)
    presets_label = ",".join(chosen_presets) if chosen_presets else "none"
    total_rules = len(exact_domains) + len(suffix_domains)
    summary = f"allowlist (presets={presets_label}, domains={total_rules})"
    return {
        "policy": "allowlist",
        "presets": chosen_presets,
        "exact_domains": exact_domains,
        "suffix_domains": suffix_domains,
        "invalid_entries": invalid_entries,
        "summary": summary,
    }


def apply_agent_policy_rules(cfg: Dict[str, Any], policy_info: Dict[str, Any]) -> None:
    """
    Inject sing-box 1.12 route & DNS allowlist rules in-place when policy == 'allowlist'.
    Leaves 'open' configs untouched.
    """
    if policy_info.get("policy") != "allowlist":
        return

    exact_domains: List[str] = list(policy_info.get("exact_domains") or [])
    suffix_domains: List[str] = list(policy_info.get("suffix_domains") or [])

    route = cfg.setdefault("route", {})
    base_rules: List[Dict[str, Any]] = [
        {"protocol": "dns", "action": "hijack-dns"},
        {"ip_is_private": True, "outbound": "direct"},
    ]
    if exact_domains:
        base_rules.append({"domain": exact_domains, "outbound": "proxy-select"})
    if suffix_domains:
        base_rules.append({"domain_suffix": suffix_domains, "outbound": "proxy-select"})
    base_rules.append({"network": ["tcp", "udp"], "action": "reject"})
    route["rules"] = base_rules

    dns = cfg.setdefault("dns", {})
    dns_rules: List[Dict[str, Any]] = []
    if exact_domains:
        dns_rules.append({"domain": exact_domains, "server": "dns-remote"})
    if suffix_domains:
        dns_rules.append({"domain_suffix": suffix_domains, "server": "dns-remote"})
    dns_rules.append({"query_type": list(_DNS_REJECT_QTYPES), "action": "reject"})
    dns["rules"] = dns_rules


def write_policy_state(policy_info: Dict[str, Any]) -> None:
    """Publish read-only policy summary to /run/vpn/policy (0644) for coder & vpn-status."""
    try:
        os.makedirs(RUN_VPN_DIR, exist_ok=True)
        path = os.path.join(RUN_VPN_DIR, "policy")
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(policy_info.get("summary", "open") + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except OSError:
        pass


def build_singbox_config(
    nodes: List[Dict[str, Any]],
    clash_secret: str,
    cache_path: str = "/var/lib/sing-box/cache.db",
    mtu: int = 1280,
    proxy_only: bool = False,
    tun_address: str = DEFAULT_TUN_ADDRESS,
    agent_policy: str = "open",
    allow_presets: str = "ai,git,pkg",
    allow_domains: str = "",
    extra_exact_domains: Optional[List[str]] = None,
) -> Dict[str, Any]:
    """Build modern sing-box 1.12 configuration preserving all F7/D5/D6/D12/v2.2 invariants."""
    if not nodes:
        raise ValueError("Cannot build sing-box config with zero valid proxy nodes")

    safe_mtu = max(1200, min(1500, int(mtu)))
    node_tags = [n["tag"] for n in nodes]
    outbounds: List[Dict[str, Any]] = [
        {
            "type": "selector",
            "tag": "proxy-select",
            "outbounds": ["auto-proxy", *node_tags, "direct"],
            "default": "auto-proxy",
        },
        {
            "type": "urltest",
            "tag": "auto-proxy",
            "outbounds": node_tags,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "1m",
            "tolerance": 80,
            "idle_timeout": "30m",
        },
        *nodes,
        {
            "type": "direct",
            "tag": "direct",
            "routing_mark": DEFAULT_FWMARK,
        },
    ]

    inbounds: List[Dict[str, Any]] = []
    if not proxy_only:
        inbounds.append(
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "sing-tun",
                "address": [tun_address],
                "mtu": safe_mtu,
                "auto_route": True,
                "strict_route": True,
                "stack": "gvisor",
                "sniff": True,
            }
        )

    # Always expose an internal loopback mixed HTTP/SOCKS5 proxy inside the container
    # (never published to host, zero conflict with host port 2080).
    inbounds.append(
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": 2080,
            "sniff": True,
        }
    )

    cfg: Dict[str, Any] = {
        "log": {
            "level": "info",
            "timestamp": True,
        },
        "dns": {
            "servers": [
                {
                    "tag": "dns-remote",
                    "type": "https",
                    "server": "1.1.1.1",
                    "server_port": 443,
                    "path": "/dns-query",
                    "detour": "proxy-select",
                },
                {
                    "tag": "dns-direct",
                    "type": "https",
                    "server": "1.1.1.1",
                    "server_port": 443,
                    "path": "/dns-query",
                },
            ],
            "final": "dns-remote",
            "strategy": "ipv4_only",
        },
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {
            "auto_detect_interface": True,
            "default_mark": DEFAULT_FWMARK,
            "default_domain_resolver": "dns-direct",
            "rules": [
                {
                    "protocol": "dns",
                    "action": "hijack-dns",
                },
                {
                    "ip_is_private": True,
                    "outbound": "direct",
                },
            ],
            "final": "proxy-select",
        },
        "experimental": {
            "cache_file": {
                "enabled": True,
                "path": cache_path,
            },
            "clash_api": {
                "external_controller": "127.0.0.1:9090",
                "secret": clash_secret,
            },
        },
    }

    policy_info = resolve_agent_policy(
        policy=agent_policy,
        presets_raw=allow_presets,
        custom_domains_raw=allow_domains,
        extra_exact_domains=extra_exact_domains,
    )
    apply_agent_policy_rules(cfg, policy_info)
    return cfg


def harden_static_config(
    raw_cfg: Dict[str, Any],
    clash_secret: str,
    cache_path: str = "/var/lib/sing-box/cache.db",
    tun_address: str = DEFAULT_TUN_ADDRESS,
    agent_policy: str = "open",
    allow_presets: str = "ai,git,pkg",
    allow_domains: str = "",
) -> Dict[str, Any]:
    """
    Sanitize fallback static /etc/sing-box/config.json:
    - Drops broken empty-tag outbounds (like F7's outbounds[2]).
    - Rewrites colliding 172.16-31.x.x TUN addresses to a safe non-Docker CIDR.
    - Enforces route.default_mark=255, cache_file in /var/lib/sing-box, and Clash API secret.
    - Applies optional VPN_AGENT_POLICY allowlist rules when enabled.
    """
    cfg = json.loads(json.dumps(raw_cfg))

    inbounds = cfg.get("inbounds", [])
    if isinstance(inbounds, list):
        for ib in inbounds:
            if isinstance(ib, dict) and ib.get("type") == "tun":
                addrs = ib.get("address") or ([ib["inet4_address"]] if ib.get("inet4_address") else [])
                if any(str(a).startswith("172.") for a in addrs):
                    ib["address"] = [tun_address]
                    ib.pop("inet4_address", None)

    outbounds = cfg.get("outbounds", [])
    if isinstance(outbounds, list):
        cleaned = [ob for ob in outbounds if isinstance(ob, dict) and ob.get("tag")]
        for ob in cleaned:
            if ob.get("type") == "direct":
                ob["routing_mark"] = DEFAULT_FWMARK
        cfg["outbounds"] = cleaned

    route = cfg.setdefault("route", {})
    route["auto_detect_interface"] = True
    route["default_mark"] = DEFAULT_FWMARK

    policy_info = resolve_agent_policy(
        policy=agent_policy,
        presets_raw=allow_presets,
        custom_domains_raw=allow_domains,
    )
    apply_agent_policy_rules(cfg, policy_info)

    exp = cfg.setdefault("experimental", {})
    exp["cache_file"] = {"enabled": True, "path": cache_path}
    exp["clash_api"] = {
        "external_controller": "127.0.0.1:9090",
        "secret": clash_secret,
    }
    return cfg


def _create_marked_connection(
    address: Tuple[str, int],
    timeout: float = FETCH_TIMEOUT,
    source_address: Optional[Tuple[str, int]] = None,
    fwmark: int = DEFAULT_FWMARK,
) -> socket.socket:
    host, port = address
    last_err: Optional[OSError] = None
    # Prefer direct SO_MARK=255 UDP DNS first so dead sing-tun / 127.0.0.11 never blocks recovery
    ips = _resolve_ipv4_marked(host, timeout=min(float(timeout), 3.0), fwmark=fwmark)
    if not ips:
        ips = [
            res[4][0]
            for res in socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
        ]

    for ip_str in ips:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.settimeout(timeout)
            try:
                sock.setsockopt(socket.SOL_SOCKET, SO_MARK, fwmark)
            except OSError:
                pass
            if source_address:
                sock.bind(source_address)
            sock.connect((ip_str, port))
            return sock
        except OSError as exc:
            last_err = exc
            try:
                sock.close()
            except OSError:
                pass
    if last_err is not None:
        raise last_err
    raise OSError(f"Could not connect to {host}:{port}")


class _MarkedHTTPConnection(http.client.HTTPConnection):
    def connect(self) -> None:
        self.sock = _create_marked_connection((self.host, self.port), self.timeout or FETCH_TIMEOUT, self.source_address)


class _MarkedHTTPSConnection(http.client.HTTPSConnection):
    def connect(self) -> None:
        raw_sock = _create_marked_connection((self.host, self.port), self.timeout or FETCH_TIMEOUT, self.source_address)
        ctx = self._context if hasattr(self, "_context") else ssl.create_default_context()
        self.sock = ctx.wrap_socket(raw_sock, server_hostname=self.host)


class _MarkedHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req: urllib.request.Request) -> Any:
        return self.do_open(_MarkedHTTPConnection, req)


class _MarkedHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req: urllib.request.Request) -> Any:
        return self.do_open(_MarkedHTTPSConnection, req, context=ssl.create_default_context())


def fetch_subscription_bytes(
    url: str,
    max_bytes: int = MAX_SUB_BYTES,
    timeout: int = FETCH_TIMEOUT,
    use_fwmark: bool = False,
) -> bytes:
    """Download subscription payload with strict size cap, timeout, and optional SO_MARK=255 bypass."""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError(f"Unsupported subscription scheme: {parsed.scheme}")
    if is_ssrf_host(parsed.hostname or ""):
        raise ValueError("Subscription URL points to a blocked local/SSRF host")

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "sing-box/1.12.8 (developer-infra)",
            "Accept": "text/plain, */*",
        },
    )
    opener = (
        urllib.request.build_opener(_MarkedHTTPHandler(), _MarkedHTTPSHandler())
        if use_fwmark
        else urllib.request.build_opener()
    )
    chunks: List[bytes] = []
    total = 0
    with opener.open(req, timeout=timeout) as resp:
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise ValueError(f"Subscription payload exceeded {max_bytes} byte limit")
            chunks.append(chunk)
    return b"".join(chunks)


def validate_config_with_singbox(config_path: str, sing_box_bin: str = SING_BOX_BIN) -> Tuple[bool, str]:
    """Run `sing-box check -c <config_path>` before swapping active config."""
    try:
        res = subprocess.run(
            [sing_box_bin, "check", "-c", config_path],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if res.returncode == 0:
            return True, ""
        return False, (res.stderr or res.stdout).strip()
    except Exception as exc:
        return False, str(exc)


def read_text_file(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def write_secure_json(path: str, data: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def file_sha256(path: str) -> str:
    if not os.path.isfile(path):
        return ""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            h.update(block)
    return h.hexdigest()


def atomic_apply_config(
    cfg: Dict[str, Any],
    state_dir: Optional[str] = None,
    sing_box_bin: Optional[str] = None,
    save_last_good: bool = True,
) -> Tuple[bool, bool, str]:
    """
    Validate and atomically replace config.active.json.
    Returns: (success, changed, error_message)
    """
    if state_dir is None:
        state_dir = STATE_DIR
    if sing_box_bin is None:
        sing_box_bin = SING_BOX_BIN
    new_path = os.path.join(state_dir, "config.new.json")
    active_path = os.path.join(state_dir, "config.active.json")
    last_good_path = os.path.join(state_dir, "config.last-good.json")

    write_secure_json(new_path, cfg)
    ok, err = validate_config_with_singbox(new_path, sing_box_bin=sing_box_bin)
    if not ok:
        try:
            os.remove(new_path)
        except OSError:
            pass
        return False, False, err

    old_hash = file_sha256(active_path)
    new_hash = file_sha256(new_path)
    changed = old_hash != new_hash

    os.replace(new_path, active_path)
    os.chmod(active_path, 0o600)
    if save_last_good:
        write_secure_json(last_good_path, cfg)

    return True, changed, ""


def restart_singbox() -> None:
    try:
        res = subprocess.run(
            ["supervisorctl", "restart", "sing-box"],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if res.returncode == 0:
            log("Reloaded sing-box via supervisorctl")
        else:
            log(f"supervisorctl restart sing-box returned {res.returncode}: {res.stderr.strip()}")
    except Exception as exc:
        log(f"Could not restart sing-box automatically: {exc}")


def run_bootstrap_cmd(action: str, arg: Optional[str] = None) -> None:
    if not os.path.exists(VPN_CTL_BIN):
        return
    cmd = [VPN_CTL_BIN, action]
    if arg:
        cmd.append(arg)
    try:
        subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    except Exception:
        pass


def heal_colliding_active_config(
    active_path: str,
    clash_secret: str,
    safe_tun_addr: str,
    existing_nets: Optional[List[ipaddress.IPv4Network]] = None,
) -> bool:
    """
    If a persisted config.active.json assigns a TUN CIDR (e.g. legacy 172.19.0.1/30)
    that collides with Docker's eth0 bridge subnet (e.g. 172.19.0.2/16), sing-tun hijacks
    Docker's default gateway and breaks ALL eth0 egress including SO_MARK=255 recovery.
    Patch it immediately and reload sing-box BEFORE attempting subscription fetch.
    """
    if not os.path.isfile(active_path):
        return False
    nets = get_host_ipv4_networks() if existing_nets is None else existing_nets
    if not nets:
        return False
    try:
        with open(active_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        if not isinstance(cfg, dict):
            return False
        inbounds = cfg.get("inbounds")
        if not isinstance(inbounds, list):
            return False

        collided = False
        for ib in inbounds:
            if not isinstance(ib, dict) or ib.get("type") != "tun":
                continue
            addrs = ib.get("address")
            if isinstance(addrs, str):
                addrs = [addrs]
            if not addrs and ib.get("inet4_address"):
                addrs = [ib["inet4_address"]]
            if isinstance(addrs, list) and any(tun_cidr_overlaps(str(a), nets) for a in addrs):
                ib["address"] = [safe_tun_addr]
                ib.pop("inet4_address", None)
                collided = True

        if not collided:
            return False

        exp = cfg.setdefault("experimental", {})
        if isinstance(exp, dict):
            clash = exp.setdefault("clash_api", {})
            if isinstance(clash, dict):
                clash["secret"] = clash_secret

        ok, changed, err = atomic_apply_config(cfg, save_last_good=False)
        if ok and changed:
            log(
                f"Auto-healed persisted config.active.json: migrated colliding TUN subnet -> {safe_tun_addr} "
                f"(prevented Docker eth0 gateway hijack)"
            )
            restart_singbox()
            time.sleep(1.5)
            return True
        if not ok:
            log(f"Could not auto-heal colliding TUN subnet in config.active.json: {err}")
    except Exception as exc:
        log(f"Error checking persisted config.active.json for TUN subnet collision: {exc}")
    return False


def perform_update(cold_start: bool = False) -> bool:
    sub_url = read_text_file(os.path.join(RUN_VPN_DIR, "subscription_url"))
    clash_secret = read_text_file(os.path.join(RUN_VPN_DIR, "clash_secret")) or "dev-infra-secret"
    current_mode = read_text_file(os.path.join(RUN_VPN_DIR, "mode")) or "strict"
    proxy_only = current_mode == "proxy"

    active_path = os.path.join(STATE_DIR, "config.active.json")
    last_good_path = os.path.join(STATE_DIR, "config.last-good.json")
    static_path = os.path.join(ETC_SINGBOX_DIR, "config.json")

    allow_insecure = is_truthy(os.environ.get("VPN_ALLOW_INSECURE", "0"))
    probe_enabled = is_truthy(os.environ.get("VPN_PROBE_NODES", "1"))
    node_filter = os.environ.get("VPN_NODE_FILTER", "")
    node_exclude = os.environ.get("VPN_NODE_EXCLUDE", "")
    preferred_tun = os.environ.get("VPN_TUN_ADDRESS", DEFAULT_TUN_ADDRESS).strip() or DEFAULT_TUN_ADDRESS
    safe_tun_addr = pick_safe_tun_address(preferred=preferred_tun)
    protocol_order = [
        p.strip() for p in os.environ.get("VPN_PROTOCOL_ORDER", "vless,hysteria2").split(",")
    ]
    try:
        max_nodes = int(os.environ.get("VPN_MAX_NODES", "30"))
    except ValueError:
        max_nodes = 30
    try:
        mtu = int(os.environ.get("VPN_MTU", "1280"))
    except ValueError:
        mtu = 1280

    agent_policy = os.environ.get("VPN_AGENT_POLICY", "open").strip().lower() or "open"
    allow_presets = os.environ.get("VPN_ALLOW_PRESETS", "ai,git,pkg")
    allow_domains = os.environ.get("VPN_ALLOW_DOMAINS", "")
    sub_host_for_policy = urllib.parse.urlsplit(sub_url).hostname or "" if sub_url else ""
    extra_policy_exact = [sub_host_for_policy] if sub_host_for_policy else []
    policy_info = resolve_agent_policy(
        policy=agent_policy,
        presets_raw=allow_presets,
        custom_domains_raw=allow_domains,
        extra_exact_domains=extra_policy_exact,
    )
    write_policy_state(policy_info)
    if policy_info["invalid_entries"]:
        log(f"Warning: ignored invalid VPN_ALLOW_PRESETS/VPN_ALLOW_DOMAINS entries: {policy_info['invalid_entries']}")

    # Step 0: Immediately heal any legacy persisted config whose TUN CIDR collides with eth0
    heal_colliding_active_config(active_path, clash_secret=clash_secret, safe_tun_addr=safe_tun_addr)

    # Step 1: Attempt dynamic subscription fetch
    if sub_url:
        redacted = redact_url(sub_url)
        sub_host = urllib.parse.urlsplit(sub_url).hostname or ""
        had_existing_active = os.path.isfile(active_path)
        bootstrap_opened = False
        try:
            if cold_start and sub_host and not had_existing_active:
                log(f"Cold-start bootstrap: temporarily allowing HTTPS to {sub_host}")
                run_bootstrap_cmd("bootstrap-allow", sub_host)
                bootstrap_opened = True

            log(f"Fetching subscription from {redacted}")
            try:
                raw_bytes = fetch_subscription_bytes(sub_url, use_fwmark=bootstrap_opened)
            except Exception as tunnel_exc:
                # Dead-tunnel recovery: if existing config.active.json has stale/dead nodes,
                # retry once directly over eth0 using scoped bootstrap-allow + SO_MARK=255.
                if sub_host and not bootstrap_opened:
                    log(
                        f"Tunnel fetch failed ({tunnel_exc}); retrying once via scoped "
                        f"bootstrap-allow + fwmark 0xff for {sub_host}"
                    )
                    run_bootstrap_cmd("bootstrap-allow", sub_host)
                    bootstrap_opened = True
                    raw_bytes = fetch_subscription_bytes(sub_url, use_fwmark=True)
                else:
                    raise

            uris = decode_subscription_payload(raw_bytes)

            # Parse a wide pool first so TCP pre-probe can filter out unreachable RU/bridge nodes
            pool_cap = max(max_nodes * 4, 120) if probe_enabled else max_nodes
            candidates, stats = parse_subscription_uris(
                uris,
                allow_insecure=allow_insecure,
                node_filter=node_filter,
                node_exclude=node_exclude,
                protocol_order=protocol_order,
                max_nodes=pool_cap,
            )

            if probe_enabled and candidates:
                nodes, probed_n, reachable_n = probe_reachable_nodes(
                    candidates,
                    protocol_order=protocol_order,
                    max_nodes=max_nodes,
                )
                log(
                    f"TCP pre-probe: probed={probed_n} reachable={reachable_n} "
                    f"selected={len(nodes)} (mode={current_mode}, mtu={mtu}, tun={safe_tun_addr})"
                )
            else:
                nodes = candidates[:max_nodes]

            log(
                f"Parsed subscription: total={stats['total_uris']} parsed={stats['parsed']} "
                f"selected={len(nodes)} skipped_insecure={stats['skipped_insecure']} "
                f"skipped_ssrf={stats['skipped_ssrf']} skipped_filtered={stats['skipped_filtered']} "
                f"skipped_dup={stats['skipped_duplicate']}"
            )
            if stats["skipped_insecure"] > 0 and not allow_insecure:
                log(
                    "Notice: insecure/pinned-self-signed nodes were skipped (VPN_ALLOW_INSECURE=0). "
                    "Set VPN_ALLOW_INSECURE=1 in .env if you explicitly trust them."
                )

            if nodes:
                cfg = build_singbox_config(
                    nodes,
                    clash_secret=clash_secret,
                    cache_path=os.path.join(STATE_DIR, "cache.db"),
                    mtu=mtu,
                    proxy_only=proxy_only,
                    tun_address=safe_tun_addr,
                    agent_policy=agent_policy,
                    allow_presets=allow_presets,
                    allow_domains=allow_domains,
                    extra_exact_domains=extra_policy_exact,
                )
                ok, changed, err = atomic_apply_config(cfg)
                if ok:
                    log(
                        f"Applied dynamic config ({len(nodes)} nodes, proxy_only={proxy_only}, "
                        f"policy={policy_info['summary']}, changed={changed})"
                    )
                    if changed and (not cold_start or had_existing_active):
                        restart_singbox()
                    return True
                log(f"Validation failed for dynamic config: {err}")
            else:
                log("No usable proxy nodes remained after parsing/filtering")
        except Exception as exc:
            log(f"Subscription update failed ({redacted}): {exc}")
        finally:
            if bootstrap_opened:
                run_bootstrap_cmd("bootstrap-revoke")

    # Step 2: Cold-start fallback to config.last-good.json (resync clash_api.secret & safe TUN CIDR)
    if not os.path.isfile(active_path) and os.path.isfile(last_good_path):
        try:
            with open(last_good_path, "r", encoding="utf-8") as f:
                lg_cfg = json.load(f)
            if isinstance(lg_cfg, dict):
                exp = lg_cfg.setdefault("experimental", {})
                if isinstance(exp, dict):
                    clash = exp.setdefault("clash_api", {})
                    if isinstance(clash, dict):
                        clash["secret"] = clash_secret
                for ib in (lg_cfg.get("inbounds") or []):
                    if isinstance(ib, dict) and ib.get("type") == "tun":
                        ib["address"] = [safe_tun_addr]
                        ib.pop("inet4_address", None)
            ok, _, err = atomic_apply_config(lg_cfg, save_last_good=False)
            if ok:
                log("Cold-start fallback: restored config.last-good.json (synced clash_secret & TUN CIDR)")
                return True
            log(f"config.last-good.json failed validation: {err}")
        except Exception as exc:
            log(f"Could not load config.last-good.json: {exc}")

    # Step 3: Fallback to static /etc/sing-box/config.json
    if not os.path.isfile(active_path) and os.path.isfile(static_path):
        try:
            with open(static_path, "r", encoding="utf-8") as f:
                static_cfg = json.load(f)
            hardened = harden_static_config(
                static_cfg,
                clash_secret=clash_secret,
                cache_path=os.path.join(STATE_DIR, "cache.db"),
                tun_address=safe_tun_addr,
                agent_policy=agent_policy,
                allow_presets=allow_presets,
                allow_domains=allow_domains,
            )
            ok, _, err = atomic_apply_config(hardened, save_last_good=True)
            if ok:
                log("Fallback: applied hardened static /etc/sing-box/config.json")
                return True
            log(f"Static /etc/sing-box/config.json failed validation: {err}")
        except Exception as exc:
            log(f"Could not load static /etc/sing-box/config.json: {exc}")

    # Step 4: If keeping an existing config.active.json after a failed update,
    # ensure its clash_api.secret matches the current boot's /run/vpn/clash_secret
    # so vpn-ctl select / retest / vpn-status never hit HTTP 401.
    if os.path.isfile(active_path):
        try:
            with open(active_path, "r", encoding="utf-8") as f:
                cur_cfg = json.load(f)
            if isinstance(cur_cfg, dict):
                exp = cur_cfg.get("experimental")
                clash = exp.get("clash_api") if isinstance(exp, dict) else None
                if isinstance(clash, dict) and clash.get("secret") != clash_secret:
                    clash["secret"] = clash_secret
                    ok, changed, err = atomic_apply_config(cur_cfg, save_last_good=False)
                    if ok and changed:
                        log("Synced current clash_secret into persisted config.active.json")
                        restart_singbox()
                    elif not ok:
                        log(f"Could not resync clash_secret in config.active.json: {err}")
        except Exception as exc:
            log(f"Could not inspect existing config.active.json for clash_secret sync: {exc}")

    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="developer-infra sing-box subscription updater")
    parser.add_argument("--once", action="store_true", help="Run a single update cycle and exit")
    parser.add_argument("--daemon", action="store_true", help="Run continuously on schedule")
    args = parser.parse_args()

    if args.once or not args.daemon:
        ok = perform_update(cold_start=not os.path.isfile(os.path.join(STATE_DIR, "config.active.json")))
        return 0 if ok else 1

    running = True

    def _stop(_signum: int, _frame: Any) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    update_interval = int(os.environ.get("VPN_UPDATE_INTERVAL", "3600"))
    retry_interval = int(os.environ.get("VPN_RETRY_INTERVAL", "600"))

    first = True
    while running:
        ok = perform_update(cold_start=first)
        first = False
        sleep_secs = update_interval if ok else retry_interval
        log(f"Next update check in {sleep_secs}s")
        for _ in range(max(1, sleep_secs)):
            if not running:
                break
            time.sleep(1)

    return 0


if __name__ == "__main__":
    sys.exit(main())
