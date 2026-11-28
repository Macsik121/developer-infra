import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def check_balanced_delimiters(text: str, filename: str) -> None:
    """Basic structural check for PowerShell scripts: balanced {}, (), and non-here-string quotes."""
    pairs = {"{": "}", "(": ")", "[": "]"}
    closing = set(pairs.values())
    stack = []
    in_single = False
    in_double = False
    in_here_double = False
    in_here_single = False
    lines = text.splitlines()
    for lineno, line in enumerate(lines, start=1):
        stripped = line.strip()
        if in_here_double:
            if stripped == '"@':
                in_here_double = False
            continue
        if in_here_single:
            if stripped == "'@":
                in_here_single = False
            continue
        if stripped.startswith("#"):
            continue
        if '@"' in line:
            in_here_double = True
            continue
        if "@'" in line:
            in_here_single = True
            continue

        i = 0
        while i < len(line):
            ch = line[i]
            if ch == "`" and in_double:
                i += 2
                continue
            if ch == "'" and not in_double:
                in_single = not in_single
            elif ch == '"' and not in_single:
                in_double = not in_double
            elif not in_single and not in_double:
                if ch == "#":
                    break
                if ch in pairs:
                    stack.append((ch, lineno))
                elif ch in closing:
                    if not stack or pairs[stack[-1][0]] != ch:
                        raise AssertionError(f"{filename}:{lineno} unmatched '{ch}'")
                    stack.pop()
            i += 1
        if in_single or in_double:
            raise AssertionError(f"{filename}:{lineno} unclosed quote on line")
    if stack:
        raise AssertionError(f"{filename} unclosed delimiter(s): {stack}")
    if in_here_double or in_here_single:
        raise AssertionError(f"{filename} unclosed here-string")


class TestComposeAndCli(unittest.TestCase):
    def test_base_compose_invariants(self):
        base = (ROOT / "docker-compose.yaml").read_text(encoding="utf-8")
        self.assertNotIn("container_name:", base, "Hardcoded container_name breaks multi-instance (D2)")
        self.assertNotIn("/run/desktop/mnt/host/wslg", base, "WSLg bind-mount must live only in docker-compose.wslg.yaml (D1)")
        self.assertNotIn("devpassword123", base)
        self.assertIn("no-new-privileges:true", base)
        self.assertIn("127.0.0.1", base)
        self.assertIn("stop_grace_period: 20s", base)
        self.assertIn("max-size: \"10m\"", base)
        self.assertIn("max-file: \"3\"", base)
        self.assertIn("soft: 16384", base)
        self.assertIn("hard: 65536", base)
        self.assertIn("dev.infra.managed=true", base)
        self.assertIn("VPN_MTU=", base)
        self.assertIn("VPN_PROBE_NODES=", base)
        self.assertIn("http://127.0.0.1:9099", base)
        for vol in ["vscode-data", "chromium-profile", "claude-state", "omniroute-state", "singbox-state"]:
            self.assertIn(f"{vol}:", base, f"Missing named volume {vol}")

    def test_compose_overlays_exist_and_scoped(self):
        wslg = (ROOT / "docker-compose.wslg.yaml").read_text(encoding="utf-8")
        self.assertIn("/run/desktop/mnt/host/wslg/.X11-unix:/tmp/.X11-unix", wslg)

        headless = (ROOT / "docker-compose.headless.yaml").read_text(encoding="utf-8")
        self.assertIn("DISPLAY=:99", headless)
        self.assertIn("/tmp/.X11-unix", headless)

    def test_env_example_covers_all_compose_variables(self):
        base = (ROOT / "docker-compose.yaml").read_text(encoding="utf-8")
        env_text = (ROOT / ".env.example").read_text(encoding="utf-8")
        env_keys = set(re.findall(r"^([A-Z0-9_]+)=", env_text, re.MULTILINE))
        compose_vars = set(re.findall(r"\$\{([A-Z0-9_]+)(?:[:?][^}]*)?\}", base))
        missing = compose_vars - env_keys
        self.assertEqual(missing, set(), f"Compose vars missing from .env.example: {missing}")

    def test_supervisord_and_dockerfile_v2_1_invariants(self):
        sup = (ROOT / "supervisord.conf").read_text(encoding="utf-8")
        self.assertIn("[program:vpn-status]", sup)
        self.assertIn("vpn-status-server.py", sup)
        # Ensure xvfb, fluxbox, x11vnc, novnc have startsecs=0 so clean WSLg :0 skip never triggers FATAL
        self.assertGreaterEqual(sup.count("startsecs=0"), 5)

        df = (ROOT / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("LANG=C.UTF-8", df)
        self.assertIn("LC_ALL=C.UTF-8", df)
        self.assertIn("vpn-status-server.py", df)

    def test_powershell_scripts_structure_and_isolation(self):
        for ps_name in ["start-claude.ps1", "run-env.ps1", "vpn-ctl.ps1", "collect-logs.ps1", "diag-env.ps1"]:
            raw = (ROOT / ps_name).read_bytes()
            raw.decode("ascii")  # pure 7-bit ASCII avoids Windows PowerShell 5.1 UTF-8-without-BOM issues
            text = raw.decode("utf-8")
            check_balanced_delimiters(text, ps_name)
            self.assertNotRegex(
                text,
                r"\[[A-Za-z0-9_.]+\]\(\s*if\b",
                f"Invalid PowerShell cast around if-statement in {ps_name} (use separate if or $(if ...))",
            )
            self.assertNotIn(
                ".ArgumentList",
                text,
                f"ProcessStartInfo.ArgumentList is unavailable on Windows PowerShell 5.1 (.NET 4.x) in {ps_name}",
            )
            self.assertNotIn("ubuntu24-dev-box", text, f"Legacy container name in {ps_name}")
            self.assertIn("ubuntu-dev", text, f"Missing ubuntu-dev service in {ps_name}")

        # D7: start-claude.ps1 MUST be a thin container wrapper (no local node/omniroute/claude)
        sc_ps1 = (ROOT / "start-claude.ps1").read_text(encoding="utf-8")
        self.assertIn("/usr/local/bin/start-claude", sc_ps1)
        self.assertNotIn("Start-Process", sc_ps1)
        self.assertNotIn("kr/glm-5", sc_ps1)
        self.assertNotIn("npm ", sc_ps1)

        # v2.1 host port preflight & VPN CLI parity
        re_ps1 = (ROOT / "run-env.ps1").read_text(encoding="utf-8")
        self.assertIn("$CheckPorts", re_ps1)
        self.assertIn("$AutoPort", re_ps1)
        self.assertIn("TcpListener", re_ps1)
        self.assertIn("dev.infra.managed=true", re_ps1)

        re_sh = (ROOT / "run-env.sh").read_text(encoding="utf-8")
        self.assertIn("--check-ports", re_sh)
        self.assertIn("--auto-port", re_sh)
        self.assertIn("dev.infra.managed=true", re_sh)

        vc_ps1 = (ROOT / "vpn-ctl.ps1").read_text(encoding="utf-8")
        self.assertIn('"proxy"', vc_ps1)
        self.assertIn('"retest"', vc_ps1)
        self.assertIn('"policy"', vc_ps1)

        # v2.2/v2.2.1 diagnostic & log collection scripts
        for diag_name in ["collect-logs.ps1", "collect-logs.sh", "diag-env.ps1", "diag-env.sh"]:
            self.assertTrue((ROOT / diag_name).is_file(), f"Missing diagnostic script: {diag_name}")
        self.assertIn("[LOG APPENDED]", (ROOT / "collect-logs.ps1").read_text(encoding="utf-8"))
        self.assertIn("[LOG APPENDED]", (ROOT / "collect-logs.sh").read_text(encoding="utf-8"))
        diag_ps1 = (ROOT / "diag-env.ps1").read_text(encoding="utf-8")
        self.assertIn("collect-logs.ps1", diag_ps1)
        self.assertIn("$collectParams = @{", diag_ps1, "diag-env.ps1 must use hashtable splatting for collect-logs.ps1")
        self.assertIn("[1/4.1]", diag_ps1)
        self.assertIn("[2/4.4]", diag_ps1)
        self.assertIn("[3/4.4]", diag_ps1)
        diag_sh = (ROOT / "diag-env.sh").read_text(encoding="utf-8")
        self.assertIn("collect-logs.sh", diag_sh)
        self.assertIn("[1/4.1]", diag_sh)
        self.assertIn("[2/4.4]", diag_sh)
        self.assertIn("[3/4.4]", diag_sh)

    def test_start_claude_sh_uses_writable_models_path(self):
        sc_sh = (ROOT / "start-claude.sh").read_text(encoding="utf-8")
        self.assertIn("${HOME}/.config/omniroute", sc_sh)
        self.assertNotIn("${SCRIPT_DIR}/claude_models.json", sc_sh)
        self.assertIn("VPN_STATE_FILE", sc_sh)

    def test_multistage_lite_and_full_profiles_invariants(self):
        df = (ROOT / "Dockerfile").read_text(encoding="utf-8")
        self.assertTrue(df.startswith("# syntax=docker/dockerfile:1"), "Dockerfile must declare BuildKit syntax header")
        for stage in ["AS base-net", "FROM base-net AS lite", "FROM base-net AS full-deps", "FROM full-deps AS full"]:
            self.assertIn(stage, df, f"Missing multi-stage target '{stage}' in Dockerfile")
        self.assertIn("ENV DEV_INFRA_PROFILE=lite", df)
        self.assertIn("ENV DEV_INFRA_PROFILE=full", df)
        self.assertIn("--mount=type=cache,target=/var/cache/apt", df)
        self.assertIn("--mount=type=cache,target=/root/.npm", df)
        # Ensure heavy full-deps (nodejs/code-server/claude-code/omniroute) live strictly AFTER base-net/lite
        idx_lite_end = df.index("FROM base-net AS full-deps")
        base_and_lite = df[:idx_lite_end]
        for heavy in ["nodesource", "code-server.dev/install.sh", "@anthropic-ai/claude-code", "omniroute@"]:
            self.assertNotIn(heavy, base_and_lite, f"Heavy tool '{heavy}' leaked into base-net/lite stage")

        compose = (ROOT / "docker-compose.yaml").read_text(encoding="utf-8")
        self.assertIn("target: ${DEV_INFRA_PROFILE:-full}", compose)
        self.assertIn("dev.infra.profile=${DEV_INFRA_PROFILE:-full}", compose)

        sup = (ROOT / "supervisord.conf").read_text(encoding="utf-8")
        self.assertIn("if ! command -v code-server", sup)
        self.assertIn("if ! command -v omniroute", sup)
        self.assertGreaterEqual(sup.count("startsecs=0"), 7)

        re_ps1 = (ROOT / "run-env.ps1").read_text(encoding="utf-8")
        self.assertIn('[ValidateSet("", "lite", "full")]', re_ps1)
        self.assertIn("DEV_INFRA_PROFILE", re_ps1)
        self.assertIn("DOCKER_BUILDKIT", re_ps1)

        re_sh = (ROOT / "run-env.sh").read_text(encoding="utf-8")
        self.assertIn("--profile)", re_sh)
        self.assertIn("export DEV_INFRA_PROFILE=", re_sh)
        self.assertIn("export DOCKER_BUILDKIT=1", re_sh)

        diag_ps1 = (ROOT / "diag-env.ps1").read_text(encoding="utf-8")
        self.assertIn("DEV_INFRA_PROFILE", diag_ps1)
        self.assertIn("SKIP(lite)", diag_ps1)

        diag_sh = (ROOT / "diag-env.sh").read_text(encoding="utf-8")
        self.assertIn("DEV_INFRA_PROFILE", diag_sh)
        self.assertIn("SKIP(lite)", diag_sh)

    def test_ci_ghcr_workflows_and_pull_first_invariants(self):
        ci_path = ROOT / ".github" / "workflows" / "ci.yml"
        rel_path = ROOT / ".github" / "workflows" / "release-images.yml"
        self.assertTrue(ci_path.is_file(), "Missing .github/workflows/ci.yml")
        self.assertTrue(rel_path.is_file(), "Missing .github/workflows/release-images.yml")

        ci_text = ci_path.read_text(encoding="utf-8")
        self.assertIn("python3 -m unittest discover -s tests -v", ci_text)
        self.assertIn("target: lite", ci_text)
        self.assertIn("docker-compose.wslg.yaml", ci_text)
        self.assertIn("docker-compose.headless.yaml", ci_text)

        rel_text = rel_path.read_text(encoding="utf-8")
        self.assertIn("packages: write", rel_text)
        self.assertIn("ghcr.io", rel_text)
        self.assertIn("linux/amd64,linux/arm64", rel_text)
        self.assertIn("target: lite", rel_text)
        self.assertIn("target: full", rel_text)
        self.assertIn("SING_BOX_SHA256_ARM64", rel_text)
        self.assertIn("export_lite_tarball", rel_text)

        compose = (ROOT / "docker-compose.yaml").read_text(encoding="utf-8")
        self.assertIn(
            "image: ${DEV_INFRA_IMAGE:-ghcr.io/macsik121/developer-infra}:${DEV_INFRA_PROFILE:-full}",
            compose,
        )

        dockerignore = (ROOT / ".dockerignore").read_text(encoding="utf-8")
        self.assertIn(".github/", dockerignore)

        re_ps1 = (ROOT / "run-env.ps1").read_text(encoding="utf-8")
        self.assertIn("[switch]$LocalBuild", re_ps1)
        self.assertIn("DEV_INFRA_IMAGE", re_ps1)
        self.assertIn("pull ubuntu-dev", re_ps1)
        self.assertIn("up -d --no-build", re_ps1)
        self.assertIn("up -d --build", re_ps1)

        re_sh = (ROOT / "run-env.sh").read_text(encoding="utf-8")
        self.assertIn("--local-build)", re_sh)
        self.assertIn("DEV_INFRA_IMAGE", re_sh)
        self.assertIn("pull ubuntu-dev", re_sh)
        self.assertIn("up -d --no-build", re_sh)
        self.assertIn("up -d --build", re_sh)


if __name__ == "__main__":
    unittest.main()
