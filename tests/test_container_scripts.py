import importlib.util
import json
import os
import socket
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class TestContainerScripts(unittest.TestCase):
    def _make_exec(self, path: Path, content: str) -> Path:
        path.write_text(content, encoding="utf-8")
        os.chmod(path, 0o755)
        return path

    @unittest.skipIf(os.name == "nt", "POSIX shell test — run inside Docker container on Windows")
    def test_display_detect_switches_between_0_and_99(self):
        with tempfile.TemporaryDirectory() as td:
            bin_dir = Path(td) / "bin"
            bin_dir.mkdir()
            xdpy = self._make_exec(bin_dir / "xdpyinfo", "#!/bin/sh\nexit 0\n")

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["X11_SOCKET_PATH"] = str(Path(td) / "missing")
            out = subprocess.check_output(
                ["bash", str(ROOT / "container/display-detect.sh")], env=env, text=True
            ).strip()
            self.assertEqual(out, ":99")

            sock_path = Path(td) / "X0"
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.bind(str(sock_path))
                env["X11_SOCKET_PATH"] = str(sock_path)
                out = subprocess.check_output(
                    ["bash", str(ROOT / "container/display-detect.sh")], env=env, text=True
                ).strip()
                self.assertEqual(out, ":0")

                self._make_exec(xdpy, "#!/bin/sh\nexit 1\n")
                out = subprocess.check_output(
                    ["bash", str(ROOT / "container/display-detect.sh")], env=env, text=True
                ).strip()
                self.assertEqual(out, ":99")
            finally:
                s.close()

    @unittest.skipIf(os.name == "nt", "POSIX shell test — run inside Docker container on Windows")
    def test_start_chromium_cleans_lock_blanks_xdg_and_supports_proxy_flag(self):
        with tempfile.TemporaryDirectory() as td:
            bin_dir = Path(td) / "bin"
            prof_dir = Path(td) / "profile"
            bin_dir.mkdir()
            prof_dir.mkdir()
            lock = prof_dir / "SingletonLock"
            lock.write_text("stale-lock")

            detect = self._make_exec(bin_dir / "detect.sh", "#!/bin/sh\necho :0\n")
            chrome = self._make_exec(
                bin_dir / "chromium",
                '#!/bin/sh\nprintf "XDG=%s|DISP=%s|ARGS=%s\\n" "$XDG_RUNTIME_DIR" "$DISPLAY" "$*"\n',
            )
            self._make_exec(bin_dir / "pgrep", "#!/bin/sh\nexit 1\n")

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "HOME": td,
                    "CHROMIUM_PROFILE_DIR": str(prof_dir),
                    "DISPLAY_DETECT_BIN": str(detect),
                    "CHROMIUM_BIN": str(chrome),
                    "XDG_RUNTIME_DIR": "/must/be/cleared",
                }
            )
            out = subprocess.check_output(
                ["bash", str(ROOT / "container/start-chromium.sh")], env=env, text=True
            ).strip()
            self.assertFalse(lock.exists())
            self.assertTrue(out.startswith("XDG=|DISP=:0|"), out)
            self.assertIn("--ozone-platform=x11", out)
            self.assertIn("--disable-features=dbus,DnsOverHttps", out)
            self.assertIn("--force-webrtc-ip-handling-policy=disable_non_proxied_udp", out)
            self.assertIn("--disable-quic", out)
            self.assertIn("http://127.0.0.1:9099", out)
            self.assertNotIn("--disable-software-rasterizer", out)

            out_proxy = subprocess.check_output(
                ["bash", str(ROOT / "container/start-chromium.sh"), "--proxy"], env=env, text=True
            ).strip()
            self.assertIn("--proxy-server=http://127.0.0.1:2080", out_proxy)

    @unittest.skipIf(os.name == "nt", "POSIX shell test — run inside Docker container on Windows")
    def test_entrypoint_stages_secrets_and_unsets_env(self):
        with tempfile.TemporaryDirectory() as td:
            bin_dir = Path(td) / "bin"
            bin_dir.mkdir()
            fake_vnc = self._make_exec(bin_dir / "x11vnc", '#!/bin/sh\necho "OBF:$2" > "$3"\n')

            base_env = os.environ.copy()
            base_env.update(
                {
                    "DEV_INFRA_RUN_DIR": str(Path(td) / "run"),
                    "DEV_INFRA_HOME_DIR": str(Path(td) / "home"),
                    "DEV_INFRA_SINGBOX_STATE_DIR": str(Path(td) / "sb"),
                    "DEV_INFRA_SUPERVISOR_LOG_DIR": str(Path(td) / "logs"),
                    "DEV_INFRA_SKIP_CHOWN": "1",
                    "DEV_INFRA_SKIP_VPN_INIT": "1",
                    "DEV_INFRA_SKIP_RESOLV_BACKUP": "1",
                    "X11VNC_BIN": str(fake_vnc),
                    "DEV_INFRA_SUPERVISORD_CMD": "env",
                    "CODE_SERVER_PASSWORD": "devpassword123",
                    "VNC_PASSWORD": "StrongVncPassword123!",
                }
            )
            bad = subprocess.run(
                ["bash", str(ROOT / "container/entrypoint.sh")],
                env=base_env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(bad.returncode, 0)

            base_env["CODE_SERVER_PASSWORD"] = "RealStrongCodePass#99"
            base_env["VPN_SUBSCRIPTION_URL"] = "https://sub.example.com/secret-path"
            base_env["VPN_FAIL_MODE"] = "proxy"
            ok = subprocess.run(
                ["bash", str(ROOT / "container/entrypoint.sh")],
                env=base_env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(ok.returncode, 0, ok.stderr)
            for leaked in ["VPN_SUBSCRIPTION_URL=", "VNC_PASSWORD=", "CODE_SERVER_PASSWORD="]:
                self.assertNotIn(leaked, ok.stdout)

            sub_file = Path(td) / "run/vpn/subscription_url"
            self.assertEqual(stat.S_IMODE(os.stat(sub_file).st_mode), 0o600)
            self.assertEqual((Path(td) / "run/vpn/mode").read_text().strip(), "proxy")

    @unittest.skipIf(os.name == "nt", "POSIX shell test — run inside Docker container on Windows")
    def test_vpn_ctl_strict_nft_fallback_fwmark_dns_block_and_failsafe_halt(self):
        with tempfile.TemporaryDirectory() as td:
            bin_dir = Path(td) / "bin"
            run_dir = Path(td) / "run"
            bin_dir.mkdir()
            log_file = Path(td) / "ipt.log"

            # Fake iptables-nft fails on xt_mark, iptables-legacy succeeds (returns 1 on -D)
            self._make_exec(bin_dir / "iptables-nft", "#!/bin/sh\nexit 1\n")
            self._make_exec(
                bin_dir / "iptables-legacy",
                f'#!/bin/sh\necho "IPT4:$*" >> "{log_file}"\n[ "$1" = "-D" ] && exit 1\nexit 0\n',
            )
            self._make_exec(
                bin_dir / "ip6tables-legacy",
                f'#!/bin/sh\necho "IPT6:$*" >> "{log_file}"\n[ "$1" = "-D" ] && exit 1\nexit 0\n',
            )
            self._make_exec(
                bin_dir / "ip",
                f'#!/bin/sh\necho "IP:$*" >> "{log_file}"\n[ "$1" = "link" ] && exit 1\nexit 0\n',
            )

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "DEV_INFRA_RUN_DIR": str(run_dir),
                    "VPN_CTL_ALLOW_NONROOT_TEST": "1",
                    "VPN_CTL_SKIP_RESOLV": "1",
                    "VPN_CTL_OFFLINE_STATUS": "1",
                }
            )
            res = subprocess.run(
                ["bash", str(ROOT / "container/vpn-ctl.sh"), "strict"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            rules = log_file.read_text()
            self.assertIn("IP:rule add fwmark 0xff lookup main pref 100", rules)
            self.assertIn("IPT4:-A DEVINFRA_KS -m mark --mark 0xff -j ACCEPT", rules)
            self.assertIn("IPT4:-A DEVINFRA_KS -d 127.0.0.11 -j REJECT --reject-with icmp-admin-prohibited", rules)
            self.assertIn("IPT4:-A DEVINFRA_KS -j REJECT --reject-with icmp-admin-prohibited", rules)
            self.assertIn("IPT6:-A DEVINFRA_KS -j REJECT --reject-with icmp6-adm-prohibited", rules)
            self.assertEqual((run_dir / "vpn/mode").read_text().strip(), "strict")
            self.assertEqual((run_dir / "vpn/state").read_text().strip(), "DOWN_STRICT")

            # Verify read-only status succeeds
            res_st = subprocess.run(
                ["bash", str(ROOT / "container/vpn-ctl.sh"), "status"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res_st.returncode, 0)
            self.assertIn("VPN Mode      : strict", res_st.stdout)
            self.assertIn("VPN State     : DOWN_STRICT", res_st.stdout)

            # Now test fail-safe halt when ALL backends reject xt_mark
            self._make_exec(bin_dir / "iptables-legacy", "#!/bin/sh\nexit 1\n")
            self._make_exec(bin_dir / "iptables", "#!/bin/sh\nexit 1\n")
            env["PATH"] = f"{bin_dir}:/usr/bin:/bin"
            env["VPN_IPTABLES_BIN"] = str(bin_dir / "iptables-nft")
            res_halt = subprocess.run(
                ["bash", str(ROOT / "container/vpn-ctl.sh"), "strict"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res_halt.returncode, 0)
            self.assertEqual((run_dir / "vpn/state").read_text().strip(), "KILLSWITCH_ERROR")

    def test_vpn_status_server_resolves_leaf_node_and_renders_html(self):
        status_mod_path = ROOT / "container" / "vpn-status-server.py"
        spec = importlib.util.spec_from_file_location("vpn_status_server", status_mod_path)
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        proxies = {
            "proxy-select": {"now": "auto-proxy", "all": ["auto-proxy", "NL-1", "DE-2", "direct"]},
            "auto-proxy": {"now": "NL-1", "all": ["NL-1", "DE-2"]},
            "NL-1": {"history": [{"delay": 115}]},
            "DE-2": {"history": [{"delay": 0}]},
        }
        sel, leaf, delay, reachable, total = mod.resolve_active_node(proxies)
        self.assertEqual(sel, "auto-proxy")
        self.assertEqual(leaf, "NL-1")
        self.assertEqual(delay, 115)
        self.assertEqual(reachable, 1)
        self.assertEqual(total, 2)

        html_out = mod.render_html(
            {
                "timestamp": "2026-11-25 00:00:00 UTC",
                "mode": "strict",
                "state": "UP",
                "tun_iface": "sing-tun",
                "tun_up": True,
                "singbox_running": True,
                "selector_now": sel,
                "active_node": leaf,
                "delay_ms": delay,
                "reachable_nodes": reachable,
                "total_nodes": total,
                "egress": {"ok": True, "ip": "203.0.113.10", "country": "NL", "org": "AS64500 Example"},
                "updater_summary": "selected=30",
                "recent_errors": [],
            }
        )
        self.assertIn("VPN CONNECTED &amp; VERIFIED", html_out)
        self.assertIn("203.0.113.10", html_out)
        self.assertIn("NL-1 (115 ms)", html_out)

    @unittest.skipIf(os.name == "nt", "POSIX shell test — run inside Docker container on Windows")
    def test_vpn_ctl_online_status_parses_api_json(self):
        with tempfile.TemporaryDirectory() as td:
            bin_dir = Path(td) / "bin"
            bin_dir.mkdir()
            payload_file = Path(td) / "status.json"
            payload_file.write_text(
                '{"mode":"strict","state":"UP","tun_iface":"sing-tun","tun_up":true,'
                '"singbox_running":true,"selector_now":"auto-proxy","active_node":"NL-1",'
                '"delay_ms":115,"reachable_nodes":12,"total_nodes":30,'
                '"egress":{"ok":true,"ip":"203.0.113.10","country":"NL","org":"AS64500 Example"},'
                '"updater_summary":"selected=30","recent_errors":[]}',
                encoding="utf-8",
            )
            self._make_exec(bin_dir / "curl", f'#!/bin/sh\ncat "{payload_file}"\n')

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env.pop("VPN_CTL_OFFLINE_STATUS", None)

            res = subprocess.run(
                ["bash", str(ROOT / "container/vpn-ctl.sh"), "status"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("VPN Mode      : strict", res.stdout)
            self.assertIn("Active Node   : auto-proxy -> NL-1 (115 ms)", res.stdout)
            self.assertIn("Live Egress   : 203.0.113.10 (NL) - AS64500 Example", res.stdout)
            self.assertIn("Updater       : selected=30", res.stdout)

            # Also verify degraded egress branch
            payload_file.write_text(
                '{"mode":"strict","state":"DEGRADED_NO_EGRESS","tun_iface":"sing-tun","tun_up":true,'
                '"singbox_running":true,"selector_now":"auto-proxy","active_node":"NL-1",'
                '"delay_ms":null,"reachable_nodes":0,"total_nodes":30,'
                '"egress":{"ok":false,"error":"timed out"},"recent_errors":["err1"]}',
                encoding="utf-8",
            )
            res2 = subprocess.run(
                ["bash", str(ROOT / "container/vpn-ctl.sh"), "status"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res2.returncode, 0, res2.stderr)
            self.assertIn("Live Egress   : FAILED (timed out)", res2.stdout)
            self.assertIn("  - err1", res2.stdout)

    def test_all_inline_python_snippets_compile(self):
        import re

        sh_files = (
            list((ROOT / "container").glob("*.sh"))
            + list((ROOT / "scripts").glob("*.sh"))
            + list(ROOT.glob("*.sh"))
        )
        pattern = re.compile(r"python3\s+-c\s+'([^']*)'", re.DOTALL)
        checked = 0
        for sh_path in sh_files:
            text = sh_path.read_text(encoding="utf-8")
            for idx, m in enumerate(pattern.finditer(text), start=1):
                code = m.group(1)
                compile(code, f"{sh_path.name}#snippet{idx}", "exec")
                checked += 1
        self.assertGreaterEqual(checked, 8, "Expected inline python3 -c snippets in shell scripts")

    @unittest.skipIf(os.name == "nt", "POSIX shell test — run inside Docker container on Windows")
    def test_vpn_watchdog_auto_failover_switches_dead_pinned_node_to_auto_proxy(self):
        with tempfile.TemporaryDirectory() as td:
            bin_dir = Path(td) / "bin"
            run_dir = Path(td) / "run"
            (run_dir / "vpn").mkdir(parents=True)
            bin_dir.mkdir()
            (run_dir / "vpn" / "mode").write_text("strict\n", encoding="utf-8")
            (run_dir / "vpn" / "state").write_text("UP\n", encoding="utf-8")

            ctl_log = Path(td) / "ctl.log"
            payload_file = Path(td) / "status.json"
            # Simulates exact live failure: pinned dead VLESS node while 6 Hysteria2 nodes work in auto-proxy
            payload_file.write_text(
                '{"mode":"strict","state":"UP","tun_up":true,"singbox_running":true,'
                '"selector_now":"Belgium-Dead","auto_proxy_now":"Switzerland-HY2",'
                '"active_node":"Belgium-Dead","reachable_nodes":6,"total_nodes":30,'
                '"egress":{"ok":false,"error":"reality verification failed"}}',
                encoding="utf-8",
            )
            self._make_exec(bin_dir / "ip", "#!/bin/sh\nexit 0\n")
            self._make_exec(bin_dir / "curl", f'#!/bin/sh\ncat "{payload_file}"\n')
            fake_ctl = self._make_exec(
                bin_dir / "vpn-ctl",
                f'#!/bin/sh\necho "$*" >> "{ctl_log}"\nexit 0\n',
            )

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "DEV_INFRA_RUN_DIR": str(run_dir),
                    "VPN_CTL_BIN": str(fake_ctl),
                    "VPN_GUI_NOTIFICATIONS": "0",
                    "VPN_AUTO_FAILOVER": "1",
                    "VPN_L7_CHECK_EVERY": "1",
                    "VPN_FAIL_THRESHOLD": "1",
                    "VPN_WATCHDOG_ONCE": "1",
                }
            )
            res = subprocess.run(
                ["bash", str(ROOT / "container/vpn-watchdog.sh")],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual((run_dir / "vpn" / "state").read_text().strip(), "DEGRADED_NO_EGRESS")
            self.assertIn("select auto-proxy", ctl_log.read_text(encoding="utf-8"))

    @unittest.skipIf(os.name == "nt", "POSIX bash script test — run inside Docker container on Windows")
    def test_vpn_ctl_policy_reports_active_allowlist_rules(self):
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "run"
            state_dir = Path(td) / "state"
            (run_dir / "vpn").mkdir(parents=True)
            state_dir.mkdir(parents=True)
            (run_dir / "vpn" / "policy").write_text("allowlist (presets=ai,git, domains=17)\n", encoding="utf-8")
            (state_dir / "config.active.json").write_text(
                json.dumps(
                    {
                        "dns": {"rules": [{"domain_suffix": ["github.com"], "server": "dns-remote"}, {"query_type": ["A"], "action": "reject"}]},
                        "route": {
                            "rules": [
                                {"domain": ["ipinfo.io"], "outbound": "proxy-select"},
                                {"domain_suffix": ["anthropic.com", "github.com"], "outbound": "proxy-select"},
                                {"network": ["tcp", "udp"], "action": "reject"},
                            ]
                        },
                    }
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env.update(
                {
                    "DEV_INFRA_RUN_DIR": str(run_dir),
                    "DEV_INFRA_SINGBOX_STATE_DIR": str(state_dir),
                }
            )
            res = subprocess.run(
                ["bash", str(ROOT / "container/vpn-ctl.sh"), "policy"],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("Agent Policy  : allowlist (presets=ai,git, domains=17)", res.stdout)
            self.assertIn("Route Reject  : True", res.stdout)
            self.assertIn("DNS Reject    : True", res.stdout)
            self.assertIn("anthropic.com, github.com", res.stdout)

    def test_vpn_status_server_429_fallback_and_204_steady_state(self):
        import importlib.util
        from unittest import mock

        spec = importlib.util.spec_from_file_location("vpn_status_server_429", ROOT / "container/vpn-status-server.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        # 1. When primary GeoIP returns 429, second provider succeeds cleanly
        def fake_get_second_ok(url, timeout=3.0):
            if "api.ip.sb" in url:
                return False, "", "curl: (22) The requested URL returned error: 429"
            if "ipwho.is" in url:
                return True, '{"success":true,"ip":"198.51.100.7","country_code":"DE","connection":{"org":"Hetzner"}}', ""
            return False, "", "unexpected"

        with (
            mock.patch.object(mod, "_probe_http_204", return_value=(True, "")),
            mock.patch.object(mod, "_http_get_text", side_effect=fake_get_second_ok),
        ):
            res = mod._probe_egress_once()
        self.assertTrue(res["ok"])
        self.assertEqual(res["ip"], "198.51.100.7")
        self.assertEqual(res["country"], "DE")
        self.assertEqual(res["org"], "Hetzner")
        self.assertEqual(res["source"], "ipwho.is")

        # 2. When ALL GeoIP providers return HTTP 429, generate_204 proves VPN is UP (never false DEGRADED)
        with (
            mock.patch.object(mod, "_probe_http_204", return_value=(True, "")),
            mock.patch.object(mod, "_http_get_text", return_value=(False, "", "curl: (22) error: 429")),
        ):
            res_204 = mod._probe_egress_once()
        self.assertTrue(res_204["ok"])
        self.assertIn("rate-limited", res_204["ip"])
        self.assertEqual(res_204["source"], "generate_204")

        # 2b. When generate_204 fails (dead tunnel), fail fast without querying GeoIP providers
        with (
            mock.patch.object(mod, "_probe_http_204", return_value=(False, "egress/DNS probe timed out (>2.5s)")),
            mock.patch.object(mod, "_http_get_text") as m_geo_dead,
        ):
            res_dead = mod._probe_egress_once()
        self.assertFalse(res_dead["ok"])
        self.assertEqual(m_geo_dead.call_count, 0)

        # 3. Steady-state force refresh reuses fresh GeoIP cache via zero-rate-limit 204 probe
        mod._EGRESS_CACHE.update({"ts": 0.0, "geoip_ts": 0.0, "node": "", "data": None})
        with (
            mock.patch.object(mod, "_http_get_text", side_effect=fake_get_second_ok) as m_geo,
            mock.patch.object(mod, "_probe_http_204", return_value=(True, "")) as m_204,
        ):
            first = mod.probe_egress(force=True, active_node="DE-1")
            second = mod.probe_egress(force=True, active_node="DE-1")
        self.assertTrue(first["ok"] and second["ok"])
        self.assertEqual(second["ip"], "198.51.100.7")
        self.assertEqual(m_204.call_count, 2, "Both initial and steady-state checks verify via 204 probe")
        self.assertEqual(m_geo.call_count, 2, "GeoIP providers should not be re-queried within GEOIP_CACHE_TTL")

        # 4. Banner must never use ambiguous shell pipe `vpn-ctl status |`
        banner = (ROOT / "container/bashrc-vpn-banner.sh").read_text(encoding="utf-8")
        self.assertNotIn("vpn-ctl status |", banner)


if __name__ == "__main__":
    unittest.main()


