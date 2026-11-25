import importlib.util
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
            base_env["VPN_SUBSCRIPTION_URL"] = "https://auth.quattro-cloud.ru/secret-path"
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


if __name__ == "__main__":
    unittest.main()
