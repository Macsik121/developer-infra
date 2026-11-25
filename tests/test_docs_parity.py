import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class TestDocsParity(unittest.TestCase):
    def test_readme_has_no_stale_references(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        for stale in [
            "OMNIROUTE_API_KEY",
            "/etc/sing-box/start-claude.sh",
            "ubuntu24-dev-box",
            "README-my.md",
        ]:
            self.assertNotIn(stale, readme, f"Stale reference '{stale}' found in README.md")

    def test_readme_referenced_files_exist(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        expected_files = [
            "docker-compose.yaml",
            "docker-compose.wslg.yaml",
            "docker-compose.headless.yaml",
            ".env.example",
            "sing-box/config.json.example",
            "run-env.ps1",
            "run-env.sh",
            "vpn-ctl.ps1",
            "vpn-ctl.sh",
            "start-claude.ps1",
            "scripts/smoke-test.sh",
        ]
        for rel in expected_files:
            self.assertTrue((ROOT / rel).exists(), f"Referenced file missing: {rel}")
            self.assertIn(rel.split("/")[-1], readme, f"File {rel} not documented in README.md")

    def test_readme_env_vars_exist_in_env_example(self):
        env_text = (ROOT / ".env.example").read_text(encoding="utf-8")
        env_keys = set(re.findall(r"^([A-Z0-9_]+)=", env_text, re.MULTILINE))
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        for key in [
            "CODE_SERVER_PASSWORD",
            "VNC_PASSWORD",
            "VPN_SUBSCRIPTION_URL",
            "VPN_ALLOW_INSECURE",
            "VPN_MTU",
            "VPN_PROBE_NODES",
            "CHROMIUM_START_URL",
            "BIND_HOST",
            "COMPOSE_PROJECT_NAME",
            "WORKSPACE_DIR",
            "CODE_SERVER_PORT",
            "NOVNC_PORT",
            "OMNIROUTE_PORT",
            "CHROMIUM_DISABLE_GPU",
            "ANTHROPIC_AUTH_TOKEN",
        ]:
            self.assertIn(key, env_keys, f"{key} missing from .env.example")
            self.assertIn(key, readme, f"{key} missing from README.md")


if __name__ == "__main__":
    unittest.main()
