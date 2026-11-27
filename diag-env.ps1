<#
.SYNOPSIS
    Full end-to-end system diagnostic & audit suite for developer-infra (Windows PowerShell 5.1 & 7+).
    Collects supervisor status, layered L3/DNS/L7 network probes, vpn-ctl + redacted config audit,
    and supervisor logs via collect-logs.ps1 into diagnostics\diag-<timestamp>\.

.EXAMPLE
    .\diag-env.ps1
    .\diag-env.ps1 -LogScope vpn -Lines 50
    .\diag-env.ps1 -LogScope ask
    .\diag-env.ps1 -SkipRetest
#>

[CmdletBinding()]
param(
    [string]$EnvFile = ".env",
    [string]$LogScope = "all",
    [int]$Lines = 50,
    [switch]$SkipRetest,
    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if ($Help) {
    Write-Host @"
Usage: .\diag-env.ps1 [OPTIONS]

Options:
  -EnvFile <path>                          Path to .env file (default: .env)
  -LogScope <all|vpn|gui|dev|pkg|ask>      Logs passed to collect-logs.ps1 (default: all; 'ask' opens menu)
  -Lines <N>                               Tail lines per supervisor log file (default: 50)
  -SkipRetest                              Skip 'vpn-ctl retest' latency sweep
  -Help, -h                                Show this help
"@
    exit 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Error "Docker CLI not found."
    exit 1
}
$dockerExe = $dockerCmd.Source

function Format-Win32Arg([string]$Arg) {
    if ($null -eq $Arg -or $Arg.Length -eq 0) { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    for ($i = 0; $i -lt $Arg.Length; $i++) {
        $ch = $Arg[$i]
        if ($ch -eq '\') {
            $bs++
        } elseif ($ch -eq '"') {
            if ($bs -gt 0) { [void]$sb.Append(('\' * ($bs * 2))) }
            $bs = 0
            [void]$sb.Append('\"')
        } else {
            if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)) }
            $bs = 0
            [void]$sb.Append($ch)
        }
    }
    if ($bs -gt 0) { [void]$sb.Append(('\' * ($bs * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-DockerClean([string[]]$DockerArgs, [string]$StdinText = $null) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $dockerExe
    $psi.Arguments = (($DockerArgs | ForEach-Object { Format-Win32Arg $_ }) -join " ")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($null -ne $StdinText)
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    if ($null -ne $StdinText) {
        $normalized = $StdinText -replace "`r`n", "`n"
        $sw = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, $utf8NoBom)
        $sw.Write($normalized)
        $sw.Flush()
        $sw.Close()
    }

    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    $stderr = $stderrTask.Result

    $combined = $stdout.TrimEnd()
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        if (-not [string]::IsNullOrEmpty($combined)) {
            $combined = $combined + [Environment]::NewLine + $stderr.TrimEnd()
        } else {
            $combined = $stderr.TrimEnd()
        }
    }

    return @{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
        Combined = $combined
    }
}

function Redact-Secrets([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $clean = $Text
    $clean = [regex]::Replace($clean, "(?i)(Authorization:\s*Bearer\s+)[^\s`"']+", '$1<redacted>')
    $clean = [regex]::Replace($clean, "(?i)(https?://[^/\s]+/sub/)[^\s`"']+", '$1<redacted>')
    $clean = [regex]::Replace($clean, "(?i)((?:VPN_SUBSCRIPTION_URL|ANTHROPIC_AUTH_TOKEN|CODE_SERVER_PASSWORD|VNC_PASSWORD|password|secret)\s*[:=]\s*)[^\s`"';]+", '$1<redacted>')
    return $clean
}

function Append-Section([string]$FilePath, [string]$Title, [string]$Body) {
    $block = @(
        "========================================================================",
        "[$Title]",
        "Captured: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "========================================================================",
        (Redact-Secrets $Body.TrimEnd()),
        ""
    ) -join [Environment]::NewLine
    [System.IO.File]::AppendAllText($FilePath, $block + [Environment]::NewLine, $utf8NoBom)
}

function Write-Step([string]$Msg) {
    Write-Host ("  .. " + $Msg) -ForegroundColor DarkGray
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Error "Env file '$EnvFile' not found."
    exit 1
}

$envMap = @{}
foreach ($line in Get-Content -LiteralPath $EnvFile) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith("#")) { continue }
    $idx = $trimmed.IndexOf("=")
    if ($idx -gt 0) {
        $envMap[$trimmed.Substring(0, $idx).Trim()] = $trimmed.Substring($idx + 1).Trim().Trim("'`"")
    }
}
$omniPort = 20128
if ($envMap["OMNIROUTE_PORT"]) { $omniPort = [int]$envMap["OMNIROUTE_PORT"] }

$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$bundleDir = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path (Join-Path "diagnostics" ("diag-" + $ts))))
New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null

$summaryFile = Join-Path $bundleDir "00-summary.txt"
$svcFile     = Join-Path $bundleDir "01-services.txt"
$netFile     = Join-Path $bundleDir "02-network-audit.txt"
$vpnFile     = Join-Path $bundleDir "03-vpn-audit.txt"
$logFileName = "04-logs-" + $LogScope + ".log"
if ($LogScope -eq "ask") { $logFileName = "04-logs-selected.log" }
$logsFile    = Join-Path $bundleDir $logFileName

$createdFiles = @($summaryFile, $svcFile, $netFile, $vpnFile, $logsFile)
$results = New-Object System.Collections.ArrayList
$hints   = New-Object System.Collections.ArrayList

function Record-Check([string]$Status, [string]$Name, [string]$Detail) {
    [void]$results.Add([PSCustomObject]@{ Status = $Status; Name = $Name; Detail = $Detail })
    $color = "Gray"
    if ($Status -eq "PASS") { $color = "Green" }
    elseif ($Status -eq "WARN") { $color = "Yellow" }
    elseif ($Status -eq "FAIL") { $color = "Red" }
    Write-Host ("  [{0,-4}] {1,-32} {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
}

Write-Host ""
Write-Host "=== developer-infra Full System Diagnostic ===" -ForegroundColor Cyan
Write-Host "Bundle directory: $bundleDir" -ForegroundColor DarkCyan
Write-Host ""

# ------------------------------------------------------------------
# 1. Container & Supervisor Status
# ------------------------------------------------------------------
Write-Host "[1/4] Checking Docker & supervisorctl status..." -ForegroundColor Cyan

Write-Step "[1/4.1] Running docker compose ps & resolving container ID..."
$psRes = Invoke-DockerClean @("compose", "--env-file", $EnvFile, "ps", "-a")
Append-Section $svcFile "docker compose ps -a" $psRes.Combined

if ($psRes.Stderr -match 'The \\?"([^\\"]+)" variable is not set') {
    $badVar = $Matches[1]
    Record-Check "WARN" ".env variable interpolation" ("Unescaped " + '$' + $badVar + " detected in " + $EnvFile + " (Compose replaces it with blank!)")
    [void]$hints.Add(("Your " + $EnvFile + " contains an unescaped " + '$' + $badVar + " (probably inside a password). Escape " + '$' + " as " + '$$' + " in .env so Docker Compose does not strip it."))
}

$cidRes = Invoke-DockerClean @("compose", "--env-file", $EnvFile, "ps", "--status", "running", "-q", "ubuntu-dev")
$containerId = ($cidRes.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($containerId)) {
    Record-Check "FAIL" "Container ubuntu-dev" "NOT RUNNING (start with .\run-env.ps1 -AutoPort)"
    [System.IO.File]::WriteAllText($summaryFile, "Container ubuntu-dev is not running.`r`nSee: $svcFile`r`n", $utf8NoBom)
    Write-Host ""
    Write-Host "Created files:" -ForegroundColor Cyan
    Write-Host "  - $summaryFile"
    Write-Host "  - $svcFile"
    exit 1
}
$containerId = $containerId.Trim()
$shortId = $containerId
if ($shortId.Length -gt 12) { $shortId = $shortId.Substring(0, 12) }
$profRes = Invoke-DockerClean @("exec", "-u", "coder", $containerId, "printenv", "DEV_INFRA_PROFILE")
$containerProfile = $profRes.Stdout.Trim().ToLowerInvariant()
if ($containerProfile -notin @("lite", "full")) { $containerProfile = "full" }
Record-Check "PASS" "Container ubuntu-dev" "running (id=$shortId, profile=$containerProfile)"

Write-Step "[1/4.2] Running supervisorctl status..."
$supRes = Invoke-DockerClean @("exec", "-u", "root", $containerId, "supervisorctl", "status")
Append-Section $svcFile "supervisorctl status" $supRes.Combined

Write-Step "[1/4.3] Checking active DISPLAY & locale..."
$dispRes = Invoke-DockerClean @("exec", "-u", "coder", $containerId, "/usr/local/lib/dev-infra/display-detect.sh")
$activeDisp = $dispRes.Stdout.Trim()
if ([string]::IsNullOrWhiteSpace($activeDisp)) { $activeDisp = "unknown" }
$locRes = Invoke-DockerClean @("exec", "-u", "coder", $containerId, "locale")
Append-Section $svcFile "Active DISPLAY & Locale" ("PROFILE=$containerProfile" + [Environment]::NewLine + "DISPLAY=$activeDisp" + [Environment]::NewLine + $locRes.Combined)

$fatalSvcs = @()
$coreDown = @()
foreach ($ln in ($supRes.Stdout -split "`r?`n")) {
    if ($ln -match "^(\S+)\s+FATAL") { $fatalSvcs += $Matches[1] }
}
$requiredCore = @("vpn-sub-updater", "sing-box", "vpn-watchdog", "code-server", "omniroute")
if ($containerProfile -eq "lite") {
    $requiredCore = @("vpn-sub-updater", "sing-box", "vpn-watchdog")
}
foreach ($core in $requiredCore) {
    if ($supRes.Stdout -notmatch ("(?m)^" + [regex]::Escape($core) + "\s+RUNNING")) {
        $coreDown += $core
    }
}
if ($supRes.Stdout -notmatch "(?m)^vpn-status\s+RUNNING") {
    $coreDown += "vpn-status (v2.1+ image needed)"
}
if ($coreDown.Count -eq 0 -and $fatalSvcs.Count -eq 0) {
    Record-Check "PASS" "supervisord services" "All core services RUNNING (profile=$containerProfile, DISPLAY=$activeDisp)"
} elseif ($coreDown.Count -gt 0) {
    Record-Check "FAIL" "supervisord core services" ("Not RUNNING: " + ($coreDown -join ", "))
    if ($coreDown -contains "vpn-status (v2.1+ image needed)") {
        [void]$hints.Add("Container appears to run an older image (missing vpn-status). Rebuild with: .\run-env.ps1 -AutoPort")
    }
} else {
    Record-Check "WARN" "supervisord fallback services" ("FATAL: " + ($fatalSvcs -join ", ") + " (rebuild v2.1+ to clean WSLg EXITED)")
}

# ------------------------------------------------------------------
# 2. Layered Network Audit (Routing, Firewall, ICMP, DNS, L7 TUN & Proxy)
# ------------------------------------------------------------------
Write-Host "[2/4] Running layered network audit (L3/DNS/L7 TUN/Proxy)..." -ForegroundColor Cyan

Write-Step "[2/4.1] Inspecting interfaces, ip rule, ip route, /etc/resolv.conf & iptables DEVINFRA_KS..."
$netCmd = @'
echo "--- ip -br addr ---"
ip -br addr 2>&1 || true
echo ""
echo "--- ip link show sing-tun ---"
ip link show sing-tun 2>&1 || true
echo ""
echo "--- ip rule list ---"
ip rule list 2>&1 || true
echo ""
echo "--- ip route show table main ---"
ip route show table main 2>&1 || true
echo ""
echo "--- ip route show table all (top 35) ---"
ip route show table all 2>&1 | head -n 35 || true
echo ""
echo "--- /etc/resolv.conf ---"
cat /etc/resolv.conf 2>&1 || true
echo ""
echo "--- iptables DEVINFRA_KS ---"
(iptables-nft -S DEVINFRA_KS 2>/dev/null || iptables-legacy -S DEVINFRA_KS 2>/dev/null || iptables -S DEVINFRA_KS 2>/dev/null || echo "(no DEVINFRA_KS chain)")
'@
$netRouteRes = Invoke-DockerClean @("exec", "-i", "-u", "root", $containerId, "bash", "-s") $netCmd
Append-Section $netFile "Routing, DNS & Firewall (DEVINFRA_KS)" $netRouteRes.Combined

$tunUp = ($netRouteRes.Stdout -match "sing-tun:")
if ($tunUp) {
    Record-Check "PASS" "TUN interface (sing-tun)" "UP"
    $gwMatch = [regex]::Match($netRouteRes.Stdout, "default via (\d+\.\d+\.\d+\.\d+) dev eth0")
    $tunIpMatch = [regex]::Match($netRouteRes.Stdout, "(?m)^sing-tun\s+\S+\s+(\d+\.\d+\.\d+\.\d+)/")
    if ($gwMatch.Success -and $tunIpMatch.Success -and ($gwMatch.Groups[1].Value -eq $tunIpMatch.Groups[1].Value)) {
        $collIp = $gwMatch.Groups[1].Value
        Record-Check "FAIL" "TUN / eth0 subnet collision" ("CRITICAL: sing-tun stole Docker gateway IP " + $collIp + "!")
        [void]$hints.Add(("CRITICAL: sing-tun IP (" + $collIp + ") collides with Docker eth0 gateway (" + $collIp + "), blackholing ALL outbound traffic! Rebuild v2.2.2+ image (uses 198.18.0.1/30 & auto-heals persisted volumes)."))
    }
} else {
    Record-Check "FAIL" "TUN interface (sing-tun)" "DOWN"
}

$hasFwmarkRule = ($netRouteRes.Stdout -match "fwmark 0xff.*lookup main")
if ($hasFwmarkRule) {
    Record-Check "PASS" "Policy routing (fwmark 0xff)" "ip rule fwmark 0xff lookup main present"
} else {
    Record-Check "WARN" "Policy routing (fwmark 0xff)" "Missing 'fwmark 0xff lookup main' rule"
    [void]$hints.Add("Missing ip rule 'fwmark 0xff lookup main'. Ensure v2.1+ image is built and run .\vpn-ctl.ps1 strict.")
}

# ICMP Ping checks (explicitly flagging synthetic sub-1ms gVisor replies)
$pingTargets = @("1.1.1.1", "8.8.8.8", "google.com", "github.com")
$pingLog = ""
$pingOkCount = 0
$gvisorLocalPing = $false
$pIdx = 0
foreach ($t in $pingTargets) {
    $pIdx++
    Write-Step "[2/4.2] ICMP ping ($pIdx/$($pingTargets.Count)): $t (timeout 2s)..."
    $pr = Invoke-DockerClean @("exec", "-u", "coder", $containerId, "ping", "-4", "-c", "2", "-W", "2", $t)
    $pingLog += ">>> ping -4 -c 2 -W 2 $t (exit=$($pr.ExitCode))`r`n$($pr.Combined)`r`n"
    if ($pr.ExitCode -eq 0) {
        $pingOkCount++
        if ($pr.Combined -match "time=0\.[0-9]+\s*ms") { $gvisorLocalPing = $true }
    }
}
if ($gvisorLocalPing) {
    $pingLog += "[DIAG NOTE] Sub-1ms ping RTT detected! sing-box stack=gvisor replies to ICMP locally; ping PASS does NOT prove upstream proxy works.`r`n"
}
Append-Section $netFile "ICMP Ping Tests (IPv4)" $pingLog
$pingNote = "$pingOkCount/$($pingTargets.Count) reachable"
if ($gvisorLocalPing) { $pingNote = "$pingOkCount/$($pingTargets.Count) ok (sub-1ms gVisor local echo - NOT L7 proof)" }
$pingStatus = "FAIL"
if ($pingOkCount -gt 0) { $pingStatus = "PASS" }
Record-Check $pingStatus "ICMP ping (IPv4)" $pingNote

# DNS resolution test
Write-Step "[2/4.3] Testing DNS resolution (getent ahosts google.com ipinfo.io)..."
$dnsRes = Invoke-DockerClean @("exec", "-u", "coder", $containerId, "getent", "ahosts", "google.com", "ipinfo.io")
Append-Section $netFile "DNS Resolution (getent ahosts)" $dnsRes.Combined
if ($dnsRes.ExitCode -eq 0 -and $dnsRes.Stdout -match "\d+\.\d+\.\d+\.\d+") {
    Record-Check "PASS" "DNS resolution" "Resolved google.com / ipinfo.io"
} else {
    Record-Check "FAIL" "DNS resolution" "Failed to resolve hostnames (see 02-network-audit.txt)"
}

# Real L7 HTTPS through TUN
Write-Step "[2/4.4] Testing L7 HTTPS via TUN (curl https://ipinfo.io/json, timeout 7s)..."
$curlTun = Invoke-DockerClean @("exec", "-u", "coder", $containerId, "curl", "-4", "-sS", "-v", "--max-time", "7", "https://ipinfo.io/json")
Append-Section $netFile "L7 HTTPS via TUN (curl https://ipinfo.io/json)" ("exit=$($curlTun.ExitCode)`r`n" + $curlTun.Combined)
$l7TunOk = ($curlTun.ExitCode -eq 0 -and $curlTun.Stdout -match '"ip"\s*:')
if ($l7TunOk) {
    $ipMatch = [regex]::Match($curlTun.Stdout, '"ip"\s*:\s*"([^"]+)"')
    $ccMatch = [regex]::Match($curlTun.Stdout, '"country"\s*:\s*"([^"]+)"')
    $ipTxt = "ok"
    if ($ipMatch.Success) { $ipTxt = $ipMatch.Groups[1].Value }
    $ccTxt = "?"
    if ($ccMatch.Success) { $ccTxt = $ccMatch.Groups[1].Value }
    Record-Check "PASS" "L7 HTTPS via TUN (ipinfo.io)" "OK ($ipTxt / $ccTxt)"
} else {
    Record-Check "FAIL" "L7 HTTPS via TUN (ipinfo.io)" "FAILED (exit=$($curlTun.ExitCode)) - see 02-network-audit.txt"
}

# Real L7 HTTPS through internal mixed proxy 127.0.0.1:2080
Write-Step "[2/4.5] Testing L7 HTTPS via internal proxy 127.0.0.1:2080 (timeout 7s)..."
$curlProxy = Invoke-DockerClean @("exec", "-u", "coder", $containerId, "curl", "-4", "-sS", "--proxy", "http://127.0.0.1:2080", "--max-time", "7", "https://ipinfo.io/json")
Append-Section $netFile "L7 HTTPS via internal proxy (127.0.0.1:2080)" ("exit=$($curlProxy.ExitCode)`r`n" + $curlProxy.Combined)
$l7ProxyOk = ($curlProxy.ExitCode -eq 0 -and $curlProxy.Stdout -match '"ip"\s*:')
if ($l7ProxyOk) {
    Record-Check "PASS" "L7 HTTPS via proxy :2080" "OK"
} else {
    Record-Check "WARN" "L7 HTTPS via proxy :2080" "FAILED (exit=$($curlProxy.ExitCode))"
}

# Local services check (uses /healthz with fallback to /api/status?fast=1 so broken VPN never stalls check)
Write-Step "[2/4.6] Checking local loopback services (8080 / 9099 / $omniPort)..."
$localCmd = @"
printf 'code-server(8080): '
if command -v code-server >/dev/null 2>&1; then
  curl -fsS --max-time 2 http://127.0.0.1:8080/healthz >/dev/null 2>&1 && echo OK || echo FAIL
else
  echo 'SKIP(lite)'
fi
printf 'vpn-status(9099): '
(curl -fsS --max-time 2 http://127.0.0.1:9099/healthz >/dev/null 2>&1 || curl -fsS --max-time 6 'http://127.0.0.1:9099/api/status?fast=1' >/dev/null 2>&1) && echo OK || echo FAIL
printf 'omniroute($omniPort): '
if command -v omniroute >/dev/null 2>&1; then
  curl -fsS --max-time 2 http://127.0.0.1:$omniPort >/dev/null 2>&1 && echo OK || echo FAIL
else
  echo 'SKIP(lite)'
fi
"@
$localRes = Invoke-DockerClean @("exec", "-i", "-u", "coder", $containerId, "bash", "-s") $localCmd
Append-Section $netFile "Internal Loopback Services" $localRes.Combined
$localStatus = "FAIL"
if ($containerProfile -eq "lite") {
    if ($localRes.Stdout -match "vpn-status\(9099\):\s*OK") { $localStatus = "PASS" }
} else {
    if ($localRes.Stdout -match "code-server\(8080\):\s*OK") { $localStatus = "PASS" }
}
Record-Check $localStatus "Local services (8080/9099/$omniPort)" ($localRes.Stdout.Trim() -replace "\r?\n", " | ")

# ------------------------------------------------------------------
# 3. VPN-CTL & Redacted Active Config + Direct SO_MARK=255 Probe
# ------------------------------------------------------------------
Write-Host "[3/4] Running vpn-ctl audit & direct upstream SO_MARK=255 probe..." -ForegroundColor Cyan

Write-Step "[3/4.1] Running vpn-ctl status..."
$vpnStatus = Invoke-DockerClean @("exec", "-u", "root", $containerId, "/usr/local/bin/vpn-ctl", "status")
Append-Section $vpnFile "vpn-ctl status" $vpnStatus.Combined

Write-Step "[3/4.2] Running vpn-ctl select (active node & pool list)..."
$vpnSelect = Invoke-DockerClean @("exec", "-u", "root", $containerId, "/usr/local/bin/vpn-ctl", "select")
Append-Section $vpnFile "vpn-ctl select" $vpnSelect.Combined

if (-not $SkipRetest) {
    Write-Step "[3/4.3] Running vpn-ctl retest (Clash API latency sweep, up to 12s)..."
    $vpnRetest = Invoke-DockerClean @("exec", "-u", "root", $containerId, "/usr/local/bin/vpn-ctl", "retest")
    Append-Section $vpnFile "vpn-ctl retest" $vpnRetest.Combined
} else {
    Write-Step "[3/4.3] Skipping vpn-ctl retest (-SkipRetest)."
}

Write-Step "[3/4.4] Inspecting config.active.json & probing 5 TCP nodes directly with SO_MARK=255..."
$inspectPy = @'
import ipaddress, json, socket, time
from pathlib import Path

cfg_path = Path("/var/lib/sing-box/config.active.json")
if not cfg_path.is_file():
    print("CONFIG_MISSING=1")
    raise SystemExit(0)

st = cfg_path.stat()
cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
inbounds = cfg.get("inbounds", [])
ib_tags = [i.get("tag") for i in inbounds]
mtu = next((i.get("mtu") for i in inbounds if i.get("type") == "tun"), None)
outbounds = cfg.get("outbounds", [])
proxies = [o for o in outbounds if o.get("type") not in {"selector", "urltest", "direct", "block", "dns"}]
protos = {}
for p in proxies:
    t = p.get("type", "?")
    protos[t] = protos.get(t, 0) + 1

print(f"CONFIG_MTIME={time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(st.st_mtime))}")
print(f"INBOUNDS={ib_tags}")
print(f"TUN_MTU={mtu}")
print(f"PROXY_COUNT={len(proxies)}")
print(f"PROTOCOLS={protos}")
print("FIRST_10_NODES:")
for i, p in enumerate(proxies[:10], 1):
    print(f"  {i:2d}. [{p.get('type')}] {p.get('tag')} -> {p.get('server')}:{p.get('server_port')}")

reality_nodes = [p for p in proxies if p.get("type") == "vless" and (p.get("tls") or {}).get("reality", {}).get("enabled")]
if reality_nodes:
    print("\nVLESS_REALITY_META (redacted, first 3 nodes):")
    for p in reality_nodes[:3]:
        tls = p.get("tls") or {}
        rel = tls.get("reality") or {}
        utls = tls.get("utls") or {}
        pbk = str(rel.get("public_key") or "")
        sid = str(rel.get("short_id") or "")
        print(
            f"  - {p.get('tag')}: sni={tls.get('server_name')}, fp={utls.get('fingerprint')}, "
            f"utls={bool(utls.get('enabled'))}, flow={p.get('flow') or 'none'}, "
            f"pbk_len={len(pbk)}, pbk_has_space={' ' in pbk}, sid_len={len(sid)}"
        )

print("\nDIRECT_TCP_PROBE_WITH_SO_MARK_255 (first 5 TCP nodes):")
tcp_nodes = [p for p in proxies if p.get("type") != "hysteria2"][:5]
ok_cnt = 0
pub_rtts = []
for p in tcp_nodes:
    host, port = p.get("server"), int(p.get("server_port", 443))
    t0 = time.monotonic()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.settimeout(2.5)
        try:
            s.setsockopt(socket.SOL_SOCKET, 36, 255)
        except OSError:
            pass
        s.connect((host, port))
        ms = int((time.monotonic() - t0) * 1000)
        ok_cnt += 1
        try:
            ip_obj = ipaddress.ip_address(host)
            if not ip_obj.is_private:
                pub_rtts.append(ms)
        except ValueError:
            pass
        print(f"  [OK]   {p.get('tag')} ({host}:{port}) {ms} ms")
    except Exception as e:
        print(f"  [FAIL] {p.get('tag')} ({host}:{port}) -> {e}")
    finally:
        s.close()
print(f"DIRECT_TCP_OK={ok_cnt}/{len(tcp_nodes)}")
if pub_rtts and all(r <= 8 for r in pub_rtts):
    print("LOCAL_SYN_ACK_SUSPECT=1")
'@

$cfgAudit = Invoke-DockerClean @("exec", "-i", "-u", "root", $containerId, "python3", "-") $inspectPy
Append-Section $vpnFile "Redacted config.active.json & Direct SO_MARK=255 Probe" $cfgAudit.Combined

$tcpOkMatch = [regex]::Match($cfgAudit.Stdout, "DIRECT_TCP_OK=(\d+)/(\d+)")
$directTcpOk = -1
$directTcpTotal = 0
if ($tcpOkMatch.Success) {
    $directTcpOk = [int]$tcpOkMatch.Groups[1].Value
    $directTcpTotal = [int]$tcpOkMatch.Groups[2].Value
}

if ($cfgAudit.Stdout -match "TUN_MTU=1400") {
    Record-Check "WARN" "Active sing-box config" ("Stale v2.0 config (MTU=1400, no mixed-in; direct TCP=" + $directTcpOk + "/" + $directTcpTotal + ")")
    [void]$hints.Add("Stale v2.0 config.active.json in singbox-state volume (MTU=1400). Rebuild v2.2+ image and run .\vpn-ctl.ps1 update to regenerate with TCP pre-probe & MTU=1280.")
} elseif ($cfgAudit.Stdout -match "PROXY_COUNT=(\d+)") {
    Record-Check "PASS" "Active sing-box config" ("nodes=" + $Matches[1] + ", direct TCP probe=" + $directTcpOk + "/" + $directTcpTotal)
} else {
    Record-Check "FAIL" "Active sing-box config" "config.active.json missing or unreadable"
}

$selMatch = [regex]::Match($vpnSelect.Stdout, "(?m)^Active Selector\s*:\s*(.+)$")
$autoResMatch = [regex]::Match($vpnSelect.Stdout, "\[resolved:\s*([^\]]+)\]")
$pinnedNonAuto = ($selMatch.Success -and ($selMatch.Groups[1].Value.Trim() -notmatch "^auto-proxy") -and ($selMatch.Groups[1].Value.Trim() -ne "direct"))
$localSynAckSuspect = ($cfgAudit.Stdout -match "LOCAL_SYN_ACK_SUSPECT=1")

if (-not $l7TunOk) {
    if ($pinnedNonAuto) {
        $pinnedName = $selMatch.Groups[1].Value.Trim()
        $autoHint = ""
        if ($autoResMatch.Success) { $autoHint = " (auto-proxy already resolved: " + $autoResMatch.Groups[1].Value.Trim() + ")" }
        [void]$hints.Add(("Active selector is pinned to failing manual node '" + $pinnedName + "'" + $autoHint + ". Run .\vpn-ctl.ps1 select auto-proxy (v2.2.3 watchdog auto-recovers this)."))
    }
    if ($l7ProxyOk) {
        [void]$hints.Add("Internal proxy 127.0.0.1:2080 WORKS while TUN failed -> TUN routing/MTU conflict with host VPN. Try .\vpn-ctl.ps1 proxy + open-chromium --proxy.")
    } elseif ($directTcpTotal -gt 0 -and $directTcpOk -eq 0) {
        [void]$hints.Add("Direct TCP (SO_MARK=255) failed to ALL $directTcpTotal tested nodes! Current nodes are blocked/unreachable from your host IP/VPN. Run .\vpn-ctl.ps1 update (v2.2 auto-recovers via bootstrap-allow + fwmark) or disable Host VPN TUN mode.")
    } elseif ($directTcpOk -gt 0) {
        [void]$hints.Add("Direct TCP to VPN servers works ($directTcpOk/$directTcpTotal), so upstream is reachable, but TLS/VLESS handshake or routing inside sing-box failed. Inspect 04-logs-*.log (sing-box.err.log) & 03-vpn-audit.txt.")
    }
    if ($localSynAckSuspect) {
        [void]$hints.Add("Direct TCP probes returned <=8ms to public IPs (typical of host VPN gVisor TUN local SYN-ACK) - raw TCP connect cannot prove VLESS Reality handshakes succeed.")
    }
}

# ------------------------------------------------------------------
# 4. Collect Supervisor Logs via collect-logs.ps1
# ------------------------------------------------------------------
Write-Host "[4/4] Collecting supervisor logs via collect-logs.ps1..." -ForegroundColor Cyan
$collectScript = Join-Path $scriptDir "collect-logs.ps1"
if (Test-Path -LiteralPath $collectScript) {
    $collectParams = @{
        Lines       = $Lines
        OutFile     = $logsFile
        EnvFile     = $EnvFile
        ContainerId = $containerId
    }
    if ($LogScope -ne "ask") {
        $collectParams["Scope"] = $LogScope
    }
    & $collectScript @collectParams
    Record-Check "PASS" "Supervisor logs collected" "Saved to $logFileName"
    if (-not $l7TunOk -and (Test-Path -LiteralPath $logsFile)) {
        $logsText = [System.IO.File]::ReadAllText($logsFile)
        if ($logsText -match "reality verification failed") {
            [void]$hints.Add("Detected 'reality verification failed' in sing-box.err.log: VLESS Reality handshake rejected by server or intercepted by host VPN/DPI. Switch to auto-proxy (Hysteria2 fallback) or run .\vpn-ctl.ps1 update.")
        }
    }
} else {
    Record-Check "WARN" "Supervisor logs collected" "collect-logs.ps1 not found next to diag-env.ps1"
}

# ------------------------------------------------------------------
# 5. Write & Print Final Summary + Exact File Paths
# ------------------------------------------------------------------
$sumLines = New-Object System.Collections.ArrayList
[void]$sumLines.Add("========================================================================")
[void]$sumLines.Add("developer-infra System Diagnostic Summary")
[void]$sumLines.Add("Timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$sumLines.Add("EnvFile   : $EnvFile")
[void]$sumLines.Add("Profile   : $containerProfile")
[void]$sumLines.Add("========================================================================")
[void]$sumLines.Add("")
[void]$sumLines.Add("Check Results:")
foreach ($r in $results) {
    [void]$sumLines.Add(("  [{0,-4}] {1,-34} {2}" -f $r.Status, $r.Name, $r.Detail))
}
[void]$sumLines.Add("")
if ($hints.Count -gt 0) {
    [void]$sumLines.Add("Root-Cause Hints:")
    foreach ($h in $hints) {
        [void]$sumLines.Add("  * $h")
    }
    [void]$sumLines.Add("")
}
[void]$sumLines.Add("Generated Diagnostic Files:")
foreach ($f in $createdFiles) {
    if (Test-Path -LiteralPath $f) {
        $sz = (Get-Item -LiteralPath $f).Length
        [void]$sumLines.Add("  - $f  ($sz bytes)")
    }
}

$summaryText = ($sumLines -join [Environment]::NewLine) + [Environment]::NewLine
[System.IO.File]::WriteAllText($summaryFile, $summaryText, $utf8NoBom)

Write-Host ""
Write-Host $summaryText
