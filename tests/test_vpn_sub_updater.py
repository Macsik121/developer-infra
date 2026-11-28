import base64
import importlib.util
import json
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent.parent / "container" / "vpn-sub-updater.py"
spec = importlib.util.spec_from_file_location("vpn_sub_updater", MODULE_PATH)
updater = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(updater)


class TestVpnSubUpdater(unittest.TestCase):
    # All 6 exact observed URI signatures from F8 (using synthetic non-secret hosts/keys)
    F8_URIS = [
        # 1. vless TCP + Reality [encryption,flow,fp,headerType,pbk,security,sid,sni,type]
        "vless://11111111-1111-4111-8111-111111111111@nl1.example.net:443"
        "?encryption=none&flow=xtls-rprx-vision&fp=chrome&headerType=none"
        "&pbk=PublicKeyExample12345&security=reality&sid=abcd1234&sni=www.cloudflare.com&type=tcp#NL-Reality-1",
        # 2. vless gRPC + TLS + pcs (pinned self-signed cert SHA256 -> governed by allow_insecure)
        "vless://22222222-2222-4222-8222-222222222222@de1.example.net:443"
        "?encryption=none&fp=firefox&mode=gun&pcs=deadbeef&security=tls"
        "&serviceName=grpc-svc&sni=cdn.example.net&type=grpc#DE-GRPC-PinnedCert",
        # 3. vless gRPC + TLS + allowInsecure=1
        "vless://33333333-3333-4333-8333-333333333333@fr1.example.net:443"
        "?allowInsecure=1&encryption=none&fp=chrome&mode=gun&security=tls"
        "&serviceName=grpc-alt&sni=fr.example.net&type=grpc#FR-GRPC-Insecure",
        # 4. hysteria2 [alpn,insecure,obfs,obfs-password,sni] (insecure=1)
        "hysteria2://hy2passA@us1.example.net:8443"
        "?alpn=h3&insecure=1&obfs=salamander&obfs-password=obfspw1&sni=us1.example.net#US-HY2-Full",
        # 5. hysteria2 [insecure,obfs,obfs-password,sni] (insecure=0 -> safe!)
        "hysteria2://hy2passB@fi1.example.net:8443"
        "?insecure=0&obfs=salamander&obfs-password=obfspw2&sni=fi1.example.net#FI-HY2-Safe",
        # 6. hysteria2 [alpn,insecure,sni] (insecure=1)
        "hysteria2://hy2passC@sg1.example.net:443"
        "?alpn=h3,h2&insecure=1&sni=sg1.example.net#SG-HY2-NoObfs",
    ]

    def test_f8_all_six_formats_strict_insecure_default(self):
        nodes, stats = updater.parse_subscription_uris(
            self.F8_URIS, allow_insecure=False, protocol_order=["vless", "hysteria2"], max_nodes=30
        )
        self.assertEqual(stats["total_uris"], 6)
        # #2 (pcs= self-signed pin), #3 (allowInsecure=1), #4 (insecure=1), #6 (insecure=1)
        self.assertEqual(stats["skipped_insecure"], 4)
        self.assertEqual(stats["selected"], 2)  # #1, #5
        tags = [n["tag"] for n in nodes]
        self.assertEqual(tags, ["NL-Reality-1", "FI-HY2-Safe"])

        # Verify Reality fields
        nl = nodes[0]
        self.assertEqual(nl["type"], "vless")
        self.assertEqual(nl["flow"], "xtls-rprx-vision")
        self.assertEqual(nl["tls"]["reality"]["public_key"], "PublicKeyExample12345")
        self.assertEqual(nl["tls"]["reality"]["short_id"], "abcd1234")
        self.assertEqual(nl["tls"]["utls"]["fingerprint"], "chrome")

        # Verify Hysteria2 safe (insecure=0) with obfs
        fi = nodes[1]
        self.assertEqual(fi["type"], "hysteria2")
        self.assertEqual(fi["obfs"], {"type": "salamander", "password": "obfspw2"})
        self.assertNotIn("insecure", fi["tls"])

    def test_f8_all_six_formats_with_allow_insecure_enabled(self):
        nodes, stats = updater.parse_subscription_uris(
            self.F8_URIS, allow_insecure=True, protocol_order=["vless", "hysteria2"], max_nodes=30
        )
        self.assertEqual(stats["skipped_insecure"], 0)
        self.assertEqual(stats["selected"], 6)
        by_tag = {n["tag"]: n for n in nodes}
        self.assertEqual(by_tag["DE-GRPC-PinnedCert"]["transport"], {"type": "grpc", "service_name": "grpc-svc"})
        self.assertTrue(by_tag["DE-GRPC-PinnedCert"]["tls"]["insecure"])
        self.assertTrue(by_tag["FR-GRPC-Insecure"]["tls"]["insecure"])
        self.assertEqual(by_tag["US-HY2-Full"]["tls"]["alpn"], ["h3"])
        self.assertEqual(by_tag["SG-HY2-NoObfs"]["tls"]["alpn"], ["h3", "h2"])
        self.assertNotIn("obfs", by_tag["SG-HY2-NoObfs"])

    def test_sanitize_tag_collapses_spaces_after_stripping_emojis(self):
        cleaned = updater.sanitize_tag("%F0%9F%9A%80%20%D0%90%D0%B2%D1%82%D0%BE%20%E2%9A%A1%20%D0%A1%D0%B0%D0%BC%D1%8B%D0%B9%20%20%D0%B1%D1%8B%D1%81%D1%82%D1%80%D1%8B%D0%B9", "fallback")
        self.assertEqual(cleaned, "Авто Самый быстрый")
        self.assertNotIn("  ", cleaned)

    def test_ru_bridge_deprioritized_and_balanced_protocols(self):
        uris = [
            "vless://11111111-1111-4111-8111-000000000001@ru1.example.net:443?security=reality&pbk=K1&type=tcp#LTE Авто - Германия",
            "vless://11111111-1111-4111-8111-000000000002@ru2.example.net:443?security=reality&pbk=K2&type=tcp#Италия (Мост)",
            "vless://11111111-1111-4111-8111-000000000003@ru3.example.net:443?security=reality&pbk=K3&type=tcp#Россия",
            "vless://11111111-1111-4111-8111-000000000004@nl1.example.net:443?security=reality&pbk=K4&type=tcp#Нидерланды",
            "vless://11111111-1111-4111-8111-000000000005@de1.example.net:443?security=reality&pbk=K5&type=tcp#Германия",
            "hysteria2://pw1@fi1.example.net:8443?insecure=0&sni=fi1.example.net#Финляндия HY2",
        ]
        nodes, _ = updater.parse_subscription_uris(uris, max_nodes=3)
        tags = [n["tag"] for n in nodes]
        self.assertEqual(tags, ["Нидерланды", "Германия", "Финляндия HY2"])

    def test_base64_and_plain_decoding(self):
        plain = "\n".join(self.F8_URIS).encode("utf-8")
        self.assertEqual(len(updater.decode_subscription_payload(plain)), 6)

        b64 = base64.b64encode(plain)
        self.assertEqual(len(updater.decode_subscription_payload(b64)), 6)

        b64_unpadded = b64.rstrip(b"=")
        self.assertEqual(len(updater.decode_subscription_payload(b64_unpadded)), 6)

    def test_ssrf_and_deduplication_and_filtering(self):
        uris = [
            "vless://11111111-1111-4111-8111-111111111111@127.0.0.1:443?security=tls#Local1",
            "vless://11111111-1111-4111-8111-111111111111@localhost:443?security=tls#Local2",
            "vless://11111111-1111-4111-8111-111111111111@[::1]:443?security=tls#Local3",
            "hysteria2://pw@0.0.0.0:443?sni=a.com#Local4",
            "hysteria2://pw@169.254.169.254:443?sni=a.com#MetaSSRF",
            self.F8_URIS[0],
            self.F8_URIS[0],  # duplicate
            "vless://44444444-4444-4444-8444-444444444444@info.example.net:443?security=tls#Traffic-Info-Expired",
        ]
        nodes, stats = updater.parse_subscription_uris(
            uris, node_exclude=r"(expired|traffic|info)", max_nodes=30
        )
        self.assertEqual(stats["skipped_ssrf"], 5)
        self.assertEqual(stats["skipped_duplicate"], 1)
        self.assertEqual(stats["skipped_filtered"], 1)
        self.assertEqual(len(nodes), 1)

    def test_scale_600_nodes_cap_balanced_and_performance(self):
        uris = []
        for i in range(600):
            if i % 2 == 0:
                uris.append(
                    f"hysteria2://pw{i}@hy{i}.example.net:443?insecure=0&sni=hy{i}.example.net#HY-{i}"
                )
            else:
                uris.append(
                    f"vless://11111111-1111-4111-8111-{i:012d}@vl{i}.example.net:443"
                    f"?encryption=none&fp=chrome&pbk=Key{i}&security=reality&sni=www.cloudflare.com&type=tcp#VL-{i}"
                )

        t0 = time.monotonic()
        nodes, stats = updater.parse_subscription_uris(
            uris, protocol_order=["vless", "hysteria2"], max_nodes=30
        )
        elapsed = time.monotonic() - t0

        self.assertEqual(stats["total_uris"], 600)
        self.assertEqual(len(nodes), 30)
        vless_count = sum(1 for n in nodes if n["type"] == "vless")
        hy2_count = sum(1 for n in nodes if n["type"] == "hysteria2")
        self.assertEqual(vless_count, 21)
        self.assertEqual(hy2_count, 9)
        self.assertLess(elapsed, 1.0, f"Parsing 600 nodes took too long: {elapsed:.3f}s")

    def test_singbox_1_12_schema_invariants_and_proxy_only_mode(self):
        nodes, _ = updater.parse_subscription_uris(self.F8_URIS, allow_insecure=False)
        cfg = updater.build_singbox_config(nodes, clash_secret="secret-xyz")

        inbounds_by_tag = {ib["tag"]: ib for ib in cfg["inbounds"]}
        self.assertIn("tun-in", inbounds_by_tag)
        self.assertIn("mixed-in", inbounds_by_tag)
        tun = inbounds_by_tag["tun-in"]
        self.assertEqual(tun["stack"], "gvisor")
        self.assertEqual(tun["mtu"], 1280)
        self.assertEqual(tun["interface_name"], "sing-tun")
        mixed = inbounds_by_tag["mixed-in"]
        self.assertEqual(mixed["listen"], "127.0.0.1")
        self.assertEqual(mixed["listen_port"], 2080)

        self.assertEqual(cfg["route"]["default_mark"], 255)
        self.assertEqual(cfg["outbounds"][-1]["routing_mark"], 255)
        self.assertEqual(cfg["experimental"]["cache_file"]["path"], "/var/lib/sing-box/cache.db")
        self.assertEqual(cfg["experimental"]["clash_api"]["external_controller"], "127.0.0.1:9090")
        self.assertEqual(cfg["experimental"]["clash_api"]["secret"], "secret-xyz")
        self.assertEqual(cfg["outbounds"][0]["type"], "selector")
        self.assertEqual(cfg["outbounds"][1]["type"], "urltest")
        self.assertEqual(cfg["outbounds"][1]["interval"], "1m")
        self.assertEqual(cfg["outbounds"][1]["idle_timeout"], "30m")

        # Proxy-only mode: omits tun-in, retains internal 127.0.0.1:2080 mixed-in
        proxy_cfg = updater.build_singbox_config(nodes, clash_secret="secret-xyz", proxy_only=True)
        proxy_tags = [ib["tag"] for ib in proxy_cfg["inbounds"]]
        self.assertEqual(proxy_tags, ["mixed-in"])

    def test_harden_static_config_drops_empty_tag_outbound(self):
        broken_static = {
            "outbounds": [
                {"type": "vless", "tag": "good-node"},
                {"type": "vless", "tag": ""},  # mimics F7 outbounds[2]
                {"type": "direct", "tag": "direct"},
            ],
            "route": {"auto_detect_interface": True},
        }
        fixed = updater.harden_static_config(broken_static, clash_secret="sec123")
        self.assertEqual([o["tag"] for o in fixed["outbounds"]], ["good-node", "direct"])
        self.assertEqual(fixed["outbounds"][1]["routing_mark"], 255)
        self.assertEqual(fixed["route"]["default_mark"], 255)
        self.assertEqual(fixed["experimental"]["clash_api"]["secret"], "sec123")

    def test_redact_url_never_leaks_secret_path(self):
        url = "https://sub.example.com/sub/SUPER_SECRET_TOKEN_999?flag=1"
        redacted = updater.redact_url(url)
        self.assertEqual(redacted, "https://sub.example.com/<redacted>")
        self.assertNotIn("SUPER_SECRET_TOKEN_999", redacted)

    @unittest.skipIf(os.name == "nt", "POSIX shell stub — run inside Docker container on Windows")
    def test_atomic_apply_keeps_previous_config_on_validation_failure(self):
        nodes, _ = updater.parse_subscription_uris(self.F8_URIS, allow_insecure=False)
        cfg1 = updater.build_singbox_config(nodes[:1], clash_secret="s1")
        cfg2 = updater.build_singbox_config(nodes[:2], clash_secret="s2")

        with tempfile.TemporaryDirectory() as td:
            ok_bin = os.path.join(td, "sing-box-ok")
            fail_bin = os.path.join(td, "sing-box-fail")
            Path(ok_bin).write_text("#!/bin/sh\nexit 0\n")
            Path(fail_bin).write_text("#!/bin/sh\necho 'invalid schema' >&2; exit 1\n")
            os.chmod(ok_bin, 0o755)
            os.chmod(fail_bin, 0o755)

            ok, changed, err = updater.atomic_apply_config(cfg1, state_dir=td, sing_box_bin=ok_bin)
            self.assertTrue(ok)
            self.assertTrue(changed)
            self.assertEqual(err, "")
            active = os.path.join(td, "config.active.json")
            self.assertEqual(stat.S_IMODE(os.stat(active).st_mode), 0o600)
            before = Path(active).read_text()

            ok2, changed2, err2 = updater.atomic_apply_config(cfg2, state_dir=td, sing_box_bin=fail_bin)
            self.assertFalse(ok2)
            self.assertFalse(changed2)
            self.assertIn("invalid schema", err2)
            self.assertEqual(Path(active).read_text(), before)

    def test_dead_tunnel_recovery_retries_with_bootstrap_and_fwmark(self):
        from unittest import mock

        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run_vpn"
            state_dir = Path(td) / "state"
            run_dir.mkdir()
            state_dir.mkdir()
            (run_dir / "subscription_url").write_text("https://sub.example.net/sub/secret", encoding="utf-8")
            (run_dir / "clash_secret").write_text("sec-abc", encoding="utf-8")
            (run_dir / "mode").write_text("strict", encoding="utf-8")
            # Simulate stale existing config.active.json from an older release
            (state_dir / "config.active.json").write_text('{"stale": true}\n', encoding="utf-8")

            fetch_calls = []
            bootstrap_calls = []
            restarted = []

            def fake_fetch(url, use_fwmark=False, **_kwargs):
                fetch_calls.append(use_fwmark)
                if not use_fwmark:
                    raise OSError("tunnel timeout")
                return self.F8_URIS[0].encode("utf-8")

            with mock.patch.object(updater, "RUN_VPN_DIR", str(run_dir)), \
                 mock.patch.object(updater, "STATE_DIR", str(state_dir)), \
                 mock.patch.object(updater, "fetch_subscription_bytes", side_effect=fake_fetch), \
                 mock.patch.object(updater, "run_bootstrap_cmd", side_effect=lambda a, arg=None: bootstrap_calls.append((a, arg))), \
                 mock.patch.object(updater, "validate_config_with_singbox", return_value=(True, "")), \
                 mock.patch.object(updater, "restart_singbox", side_effect=lambda: restarted.append(True)), \
                 mock.patch.dict(os.environ, {"VPN_PROBE_NODES": "0"}):
                ok = updater.perform_update(cold_start=True)

            self.assertTrue(ok)
            self.assertEqual(fetch_calls, [False, True])
            self.assertEqual(
                bootstrap_calls,
                [("bootstrap-allow", "sub.example.net"), ("bootstrap-revoke", None)],
            )
            self.assertEqual(restarted, [True])

    def test_offline_fallback_resyncs_clash_secret_in_persisted_config(self):
        from unittest import mock

        nodes, _ = updater.parse_subscription_uris(self.F8_URIS, allow_insecure=False)
        stale_cfg = updater.build_singbox_config(nodes[:1], clash_secret="old-boot-secret")

        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run_vpn"
            state_dir = Path(td) / "state"
            run_dir.mkdir()
            state_dir.mkdir()
            (run_dir / "subscription_url").write_text("https://sub.example.net/sub/secret", encoding="utf-8")
            (run_dir / "clash_secret").write_text("new-boot-secret-999", encoding="utf-8")
            (run_dir / "mode").write_text("strict", encoding="utf-8")
            active_path = state_dir / "config.active.json"
            active_path.write_text(json.dumps(stale_cfg), encoding="utf-8")

            restarted = []

            with mock.patch.object(updater, "RUN_VPN_DIR", str(run_dir)), \
                 mock.patch.object(updater, "STATE_DIR", str(state_dir)), \
                 mock.patch.object(updater, "fetch_subscription_bytes", side_effect=OSError("offline")), \
                 mock.patch.object(updater, "run_bootstrap_cmd"), \
                 mock.patch.object(updater, "validate_config_with_singbox", return_value=(True, "")), \
                 mock.patch.object(updater, "restart_singbox", side_effect=lambda: restarted.append(True)):
                ok = updater.perform_update(cold_start=True)

            self.assertFalse(ok)
            updated = json.loads(active_path.read_text(encoding="utf-8"))
            self.assertEqual(updated["experimental"]["clash_api"]["secret"], "new-boot-secret-999")
            self.assertEqual(restarted, [True])

    def test_tun_address_defaults_to_non_docker_range_and_avoids_collisions(self):
        import ipaddress

        nodes, _ = updater.parse_subscription_uris(self.F8_URIS, allow_insecure=False)
        cfg = updater.build_singbox_config(nodes[:1], clash_secret="sec")
        tun = next(ib for ib in cfg["inbounds"] if ib["type"] == "tun")
        self.assertEqual(tun["address"], ["198.18.0.1/30"])

        docker_172_19 = [ipaddress.ip_network("172.19.0.0/16")]
        self.assertEqual(updater.pick_safe_tun_address("172.19.0.1/30", existing_nets=docker_172_19), "198.18.0.1/30")

        busy_198_18 = [ipaddress.ip_network("198.18.0.0/16")]
        self.assertEqual(updater.pick_safe_tun_address("198.18.0.1/30", existing_nets=busy_198_18), "198.19.0.1/30")

    def test_heal_colliding_active_config_migrates_172_19_before_fetch(self):
        import ipaddress
        from unittest import mock

        nodes, _ = updater.parse_subscription_uris(self.F8_URIS, allow_insecure=False)
        legacy_cfg = updater.build_singbox_config(nodes[:1], clash_secret="old-sec", tun_address="172.19.0.1/30")

        with tempfile.TemporaryDirectory() as td:
            state_dir = Path(td)
            active_path = state_dir / "config.active.json"
            active_path.write_text(json.dumps(legacy_cfg), encoding="utf-8")
            restarted = []

            with mock.patch.object(updater, "STATE_DIR", str(state_dir)), \
                 mock.patch.object(updater, "validate_config_with_singbox", return_value=(True, "")), \
                 mock.patch.object(updater, "restart_singbox", side_effect=lambda: restarted.append(True)), \
                 mock.patch.object(updater.time, "sleep"):
                healed = updater.heal_colliding_active_config(
                    str(active_path),
                    clash_secret="fresh-sec",
                    safe_tun_addr="198.18.0.1/30",
                    existing_nets=[ipaddress.ip_network("172.19.0.0/16")],
                )

            self.assertTrue(healed)
            self.assertEqual(restarted, [True])
            new_cfg = json.loads(active_path.read_text(encoding="utf-8"))
            tun = next(ib for ib in new_cfg["inbounds"] if ib["type"] == "tun")
            self.assertEqual(tun["address"], ["198.18.0.1/30"])
            self.assertEqual(new_cfg["experimental"]["clash_api"]["secret"], "fresh-sec")

    def test_parse_dns_a_response_handles_compression_pointer(self):
        import struct

        txid = 0x4242
        query = updater._encode_dns_query("auth.example.ru", txid)
        # Build minimal DNS response: header (ANCOUNT=1) + question + compressed answer pointer (0xC00C) -> 203.0.113.42
        header = struct.pack("!HHHHHH", txid, 0x8180, 1, 1, 0, 0)
        question = query[12:]
        answer = struct.pack("!HHHIH", 0xC00C, 1, 1, 60, 4) + bytes([203, 0, 113, 42])
        ips = updater._parse_dns_a_response(header + question + answer, txid)
        self.assertEqual(ips, ["203.0.113.42"])
        self.assertEqual(updater._parse_dns_a_response(header + question + answer, 0x1111), [])

    def test_vless_reality_preserves_plus_in_pbk_defaults_utls_and_uses_doh_remote(self):
        uri = (
            "vless://11111111-1111-4111-8111-111111111111@nl2.example.net:443"
            "?encryption=none&flow=xtls-rprx-vision"
            "&pbk=AbCd+EfGh1234567890&security=reality&sid=abcd&sni=www.cloudflare.com&type=tcp#NL-PlusKey"
        )
        nodes, _ = updater.parse_subscription_uris([uri], allow_insecure=False)
        self.assertEqual(len(nodes), 1)
        tls = nodes[0]["tls"]
        self.assertEqual(tls["reality"]["public_key"], "AbCd+EfGh1234567890")
        self.assertEqual(tls["utls"], {"enabled": True, "fingerprint": "chrome"})

        cfg = updater.build_singbox_config(nodes, clash_secret="sec")
        dns_remote = next(s for s in cfg["dns"]["servers"] if s["tag"] == "dns-remote")
        self.assertEqual(dns_remote["type"], "https")
        self.assertEqual(dns_remote["server_port"], 443)
        self.assertEqual(dns_remote["path"], "/dns-query")
        self.assertEqual(dns_remote["detour"], "proxy-select")

    def test_agent_policy_open_mode_leaves_route_and_dns_untouched(self):
        nodes, _ = updater.parse_subscription_uris(self.F8_URIS, allow_insecure=False)
        cfg = updater.build_singbox_config(nodes, clash_secret="sec", agent_policy="open")
        self.assertNotIn("rules", cfg["dns"])
        self.assertFalse(any(r.get("action") == "reject" for r in cfg["route"]["rules"]))
        self.assertEqual(cfg["route"]["final"], "proxy-select")

    def test_agent_policy_allowlist_presets_sanitization_and_reject_rules(self):
        info = updater.resolve_agent_policy(
            policy="allowlist",
            presets_raw="ai,git,unknown_preset",
            custom_domains_raw="*.example.org, =api.custom.dev, localhost, 1.2.3.4, bad*host.com, https://nope.io",
            extra_exact_domains=["sub.provider.net", "api.github.com"],
        )
        self.assertEqual(info["policy"], "allowlist")
        self.assertEqual(info["presets"], ["ai", "git"])
        self.assertIn("anthropic.com", info["suffix_domains"])
        self.assertIn("github.com", info["suffix_domains"])
        self.assertIn("example.org", info["suffix_domains"])
        # Exact domains: infra probes + custom exact + subscription host, deduplicating api.github.com (covered by github.com)
        self.assertIn("ipinfo.io", info["exact_domains"])
        self.assertIn("www.gstatic.com", info["exact_domains"])
        self.assertIn("api.custom.dev", info["exact_domains"])
        self.assertIn("sub.provider.net", info["exact_domains"])
        self.assertNotIn("api.github.com", info["exact_domains"])
        # Invalid/SSRF/IP/wildcard entries rejected cleanly
        self.assertIn("preset:unknown_preset", info["invalid_entries"])
        self.assertIn("localhost", info["invalid_entries"])
        self.assertIn("1.2.3.4", info["invalid_entries"])
        self.assertIn("bad*host.com", info["invalid_entries"])

        nodes, _ = updater.parse_subscription_uris(self.F8_URIS, allow_insecure=False)
        cfg = updater.build_singbox_config(
            nodes,
            clash_secret="sec",
            agent_policy="allowlist",
            allow_presets="ai,pkg",
            allow_domains="=internal-api.company.dev,*.mytool.io",
            extra_exact_domains=["sub.example.com"],
        )
        route_rules = cfg["route"]["rules"]
        self.assertEqual(route_rules[0], {"protocol": "dns", "action": "hijack-dns"})
        self.assertEqual(route_rules[1], {"ip_is_private": True, "outbound": "direct"})
        self.assertEqual(route_rules[-1], {"network": ["tcp", "udp"], "action": "reject"})
        exact_rule = next(r for r in route_rules if "domain" in r)
        suffix_rule = next(r for r in route_rules if "domain_suffix" in r)
        self.assertEqual(exact_rule["outbound"], "proxy-select")
        self.assertIn("internal-api.company.dev", exact_rule["domain"])
        self.assertIn("sub.example.com", exact_rule["domain"])
        self.assertEqual(suffix_rule["outbound"], "proxy-select")
        self.assertIn("anthropic.com", suffix_rule["domain_suffix"])
        self.assertIn("pypi.org", suffix_rule["domain_suffix"])
        self.assertIn("mytool.io", suffix_rule["domain_suffix"])

        dns_rules = cfg["dns"]["rules"]
        self.assertEqual(dns_rules[-1]["action"], "reject")
        self.assertIn("A", dns_rules[-1]["query_type"])
        dns_suffix_rule = next(r for r in dns_rules if "domain_suffix" in r)
        self.assertEqual(dns_suffix_rule["server"], "dns-remote")
        self.assertIn("mytool.io", dns_suffix_rule["domain_suffix"])

        # Static config hardening also honors allowlist policy
        hardened = updater.harden_static_config(
            {"inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}]},
            clash_secret="sec",
            agent_policy="allowlist",
            allow_presets="none",
            allow_domains="allowed.dev",
        )
        self.assertEqual(hardened["route"]["rules"][-1], {"network": ["tcp", "udp"], "action": "reject"})
        self.assertEqual(hardened["dns"]["rules"][-1]["action"], "reject")


if __name__ == "__main__":
    unittest.main()

