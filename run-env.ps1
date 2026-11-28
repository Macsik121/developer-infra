<#
.SYNOPSIS
    Preflight, port-conflict diagnostics & launch script for Windows (Docker Desktop WSL2/WSLg or Hyper-V) (D1, D2, D9, Patch v2.1).

.EXAMPLE
    .\run-env.ps1
    .\run-env.ps1 -Profile lite -AutoPort
    .\run-env.ps1 -Profile full -AutoPort
    .\run-env.ps1 -Profile lite -LocalBuild -AutoPort
    .\run-env.ps1 -CheckPorts
    .\run-env.ps1 -AutoPort -NoBuild
    .\run-env.ps1 -Mode headless
    .\run-env.ps1 -EnvFile .env.project2 -Detach
#>

[CmdletBinding()]
param(
    [ValidateSet("wslg", "headless")]
    [string]$Mode = "wslg",

    [ValidateSet("", "lite", "full")]
    [string]$Profile = "",

    [string]$EnvFile = ".env",
    [switch]$Detach,
    [switch]$LocalBuild,
    [switch]$NoBuild,
    [switch]$CheckPorts,
    [switch]$AutoPort,
    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if ($Help) {
    Write-Host @"
Usage: .\run-env.ps1 [OPTIONS]

Options:
  -Mode <wslg|headless>    Display mode (default: wslg for Docker Desktop WSL2; use headless for Hyper-V)
  -Profile <lite|full>     Image profile: 'lite' (fast VPN + Chromium) or 'full' (IDE + AI stack; default from .env or full)
  -EnvFile <path>          Path to .env file (default: .env)
  -CheckPorts              Inspect host port availability / owners & host VPN status, then exit
  -AutoPort                Automatically increment (+1) conflicting host ports until free
  -Detach                  Start container without attaching an interactive shell
  -LocalBuild              Force local Docker BuildKit build (--build) instead of pulling pre-built GHCR image
  -NoBuild                 Skip registry pull and --build (start already-cached image)
  -Help, -h                Show this help
"@
    exit 0
}

# 1. Preflight: Docker & Compose v2
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker CLI not found. Install Docker Desktop first."
    exit 1
}

& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker daemon is not running. Start Docker Desktop and try again."
    exit 1
}

& docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Docker Compose v2 is required."
    exit 1
}

# 2. Preflight: .env & strong mandatory passwords (D9)
if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Error "File '$EnvFile' not found. Run: Copy-Item .env.example $EnvFile"
    exit 1
}

$envMap = @{}
foreach ($line in Get-Content -LiteralPath $EnvFile) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith("#")) { continue }
    $idx = $trimmed.IndexOf("=")
    if ($idx -gt 0) {
        $k = $trimmed.Substring(0, $idx).Trim()
        $v = $trimmed.Substring($idx + 1).Trim().Trim("'`"")
        $envMap[$k] = $v
    }
}

function Test-WeakPassword([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -lt 6) { return $true }
    $lower = $Value.ToLowerInvariant()
    if ($lower.StartsWith("change_me") -or $lower -in @("devpassword123", "password", "123456", "12345678", "admin")) {
        return $true
    }
    return $false
}

if (-not $CheckPorts) {
    if (Test-WeakPassword $envMap["CODE_SERVER_PASSWORD"]) {
        Write-Error "Set a strong CODE_SERVER_PASSWORD (>=6 chars, no CHANGE_ME) in $EnvFile."
        exit 1
    }
    if (Test-WeakPassword $envMap["VNC_PASSWORD"]) {
        Write-Error "Set a strong VNC_PASSWORD (>=6 chars, no CHANGE_ME) in $EnvFile."
        exit 1
    }
}

$projectName = if ($envMap["COMPOSE_PROJECT_NAME"]) { $envMap["COMPOSE_PROJECT_NAME"] } else { "devbox-main" }
$bindHost = if ($envMap["BIND_HOST"]) { $envMap["BIND_HOST"] } else { "127.0.0.1" }
$testBindAddr = if ($bindHost -eq "0.0.0.0" -or $bindHost -eq "::") { "127.0.0.1" } else { $bindHost }
$codePort = 8080
if ($envMap["CODE_SERVER_PORT"]) { $codePort = [int]$envMap["CODE_SERVER_PORT"] }
$novncPort = 6901
if ($envMap["NOVNC_PORT"]) { $novncPort = [int]$envMap["NOVNC_PORT"] }
$omniPort = 20128
if ($envMap["OMNIROUTE_PORT"]) { $omniPort = [int]$envMap["OMNIROUTE_PORT"] }
$workspaceDir = if ($envMap["WORKSPACE_DIR"]) { $envMap["WORKSPACE_DIR"] } else { "./workspace" }
$imageRepo = if ($envMap["DEV_INFRA_IMAGE"]) { $envMap["DEV_INFRA_IMAGE"] } else { "ghcr.io/macsik121/developer-infra" }
$buildProfile = $Profile
if ([string]::IsNullOrWhiteSpace($buildProfile)) {
    if ($envMap["DEV_INFRA_PROFILE"]) { $buildProfile = $envMap["DEV_INFRA_PROFILE"].ToLowerInvariant() }
    else { $buildProfile = "full" }
}
if ($buildProfile -notin @("lite", "full")) {
    Write-Error "Invalid DEV_INFRA_PROFILE '$buildProfile'. Expected 'lite' or 'full'."
    exit 1
}

# 3. Host VPN / TUN detection (non-blocking advisory)
try {
    $vpnAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq "Up" -and (
            $_.InterfaceDescription -match "Wintun|TUN|WireGuard|TAP|sing-box|Clash|v2ray|Nekoray|Amnezia|OpenVPN|Hiddify" -or
            $_.Name -match "tun|wg|sing|vpn|nekobox|hiddify|clash"
        )
    }
    if ($vpnAdapters) {
        $names = ($vpnAdapters | ForEach-Object { $_.Name }) -join ", "
        Write-Host "[run-env] Notice: Active host VPN/TUN detected ($names)." -ForegroundColor Yellow
        Write-Host "          Container uses its own isolated sing-box TUN (MTU 1280 + TCP pre-probe)." -ForegroundColor DarkYellow
        Write-Host "          Tip: if upstream blocks double-VPN, switch via .\vpn-ctl.ps1 proxy or .\vpn-ctl.ps1 direct." -ForegroundColor DarkYellow
    }
} catch {}

# 4. Port preflight & developer-infra ownership lookup
function Get-ManagedContainers {
    $list = @()
    try {
        $raw = & docker ps --filter 'label=dev.infra.managed=true' --format '{{.Names}}|{{.Labels}}|{{.Ports}}' 2>$null
        foreach ($row in $raw) {
            if ([string]::IsNullOrWhiteSpace($row)) { continue }
            $parts = $row -split '\|', 3
            if ($parts.Count -eq 3) {
                $proj = ""
                if ($parts[1] -match 'dev\.infra\.project=([^,]+)') {
                    $proj = $Matches[1]
                }
                $list += [PSCustomObject]@{ Name = $parts[0]; Project = $proj; Ports = $parts[2] }
            }
        }
    } catch {}
    return $list
}

function Test-PortBind([string]$Addr, [int]$Port) {
    $ipObj = [System.Net.IPAddress]::Loopback
    try { $ipObj = [System.Net.IPAddress]::Parse($Addr) } catch {}
    $listener = New-Object System.Net.Sockets.TcpListener($ipObj, $Port)
    try {
        $listener.Start()
        $listener.Stop()
        return @{ Ok = $true; Err = ""; Code = 0 }
    } catch {
        try { $listener.Stop() } catch {}
        $errCode = 0
        $ex = $_.Exception
        if ($ex -is [System.Net.Sockets.SocketException]) {
            $errCode = $ex.ErrorCode
        } elseif ($ex.InnerException -is [System.Net.Sockets.SocketException]) {
            $errCode = $ex.InnerException.ErrorCode
        }
        return @{ Ok = $false; Err = $ex.Message; Code = $errCode }
    }
}

function Get-PortOwner([int]$Port, [string]$ErrText, [int]$ErrCode, [string]$CurrentProject, $ManagedList) {
    foreach ($c in $ManagedList) {
        if ($c.Ports -match (":" + $Port + "->")) {
            if ($c.Project -eq $CurrentProject) {
                return @{ IsOwn = $true; Desc = "own developer-infra container ($($c.Name))" }
            }
            return @{ IsOwn = $false; Desc = "developer-infra instance '$($c.Project)' ($($c.Name))" }
        }
    }

    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($conns) {
            $ownerPid = ($conns | Select-Object -First 1).OwningProcess
            $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
            if ($proc) {
                return @{ IsOwn = $false; Desc = "process '$($proc.ProcessName)' (PID $ownerPid)" }
            }
            return @{ IsOwn = $false; Desc = "PID $ownerPid" }
        }
    } catch {}

    if ($ErrCode -eq 10013 -or $ErrText -match "access permissions|forbidden|10013") {
        return @{ IsOwn = $false; Desc = "Windows Hyper-V / WinNAT excluded port range (WSAEACCES 10013)" }
    }
    return @{ IsOwn = $false; Desc = "port busy or reserved ($ErrText)" }
}

$managed = @(Get-ManagedContainers)
$chosenPorts = New-Object 'System.Collections.Generic.HashSet[int]'
$portSpecs = @(
    @{ Service = "code-server"; EnvKey = "CODE_SERVER_PORT"; Port = $codePort },
    @{ Service = "noVNC";       EnvKey = "NOVNC_PORT";       Port = $novncPort },
    @{ Service = "OmniRoute";   EnvKey = "OMNIROUTE_PORT";   Port = $omniPort }
)

$hasConflict = $false
$resolvedMap = @{}

foreach ($spec in $portSpecs) {
    $svc = $spec.Service
    $key = $spec.EnvKey
    $desired = [int]$spec.Port
    $probe = Test-PortBind -Addr $testBindAddr -Port $desired

    if ($probe.Ok -and (-not $chosenPorts.Contains($desired))) {
        [void]$chosenPorts.Add($desired)
        $resolvedMap[$key] = $desired
        if ($CheckPorts) {
            Write-Host ("  [FREE]     {0,-12} {1}:{2}" -f $svc, $bindHost, $desired) -ForegroundColor Green
        }
        continue
    }

    $owner = Get-PortOwner -Port $desired -ErrText $probe.Err -ErrCode $probe.Code -CurrentProject $projectName -ManagedList $managed
    if ($owner.IsOwn -and (-not $chosenPorts.Contains($desired))) {
        [void]$chosenPorts.Add($desired)
        $resolvedMap[$key] = $desired
        if ($CheckPorts) {
            Write-Host ("  [OWN]      {0,-12} {1}:{2} -> {3}" -f $svc, $bindHost, $desired, $owner.Desc) -ForegroundColor Cyan
        }
        continue
    }

    if ($AutoPort -and (-not $CheckPorts)) {
        $found = 0
        for ($candidate = $desired + 1; $candidate -le ($desired + 100); $candidate++) {
            if ($candidate -gt 65535 -or $chosenPorts.Contains($candidate)) { continue }
            $candProbe = Test-PortBind -Addr $testBindAddr -Port $candidate
            if ($candProbe.Ok) {
                $found = $candidate
                break
            }
        }
        if ($found -gt 0) {
            [void]$chosenPorts.Add($found)
            $resolvedMap[$key] = $found
            [Environment]::SetEnvironmentVariable($key, "$found", "Process")
            Write-Host ("[run-env] Port conflict on {0}:{1} ({2}) -> auto-shifted {3} to {4}" -f $bindHost, $desired, $owner.Desc, $key, $found) -ForegroundColor Yellow
            continue
        }
    }

    $hasConflict = $true
    $resolvedMap[$key] = $desired
    Write-Host ("  [CONFLICT] {0,-12} {1}:{2} -> {3}" -f $svc, $bindHost, $desired, $owner.Desc) -ForegroundColor Red
}

if ($CheckPorts) {
    if ($hasConflict) {
        Write-Host ""
        Write-Host "Fix: run '.\run-env.ps1 -AutoPort' or update conflicting ports in $EnvFile." -ForegroundColor Yellow
        exit 1
    }
    Write-Host ""
    Write-Host "All configured host ports are ready for project '$projectName'." -ForegroundColor Green
    exit 0
}

if ($hasConflict) {
    Write-Host ""
    Write-Error "Host port conflict detected. Re-run with '.\run-env.ps1 -AutoPort' or change ports in $EnvFile."
    exit 1
}

$codePort = $resolvedMap["CODE_SERVER_PORT"]
$novncPort = $resolvedMap["NOVNC_PORT"]
$omniPort = $resolvedMap["OMNIROUTE_PORT"]

if (-not (Test-Path -LiteralPath $workspaceDir)) {
    New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null
}

$overlay = if ($Mode -eq "wslg") { "docker-compose.wslg.yaml" } else { "docker-compose.headless.yaml" }
$composeArgs = @("compose", "--env-file", $EnvFile, "-f", "docker-compose.yaml", "-f", $overlay)

[Environment]::SetEnvironmentVariable("DEV_INFRA_PROFILE", $buildProfile, "Process")
[Environment]::SetEnvironmentVariable("DOCKER_BUILDKIT", "1", "Process")
[Environment]::SetEnvironmentVariable("COMPOSE_DOCKER_CLI_BUILD", "1", "Process")

if ($LocalBuild) {
    Write-Host "[run-env] Starting developer-infra (mode=$Mode, profile=$buildProfile, source=local-build, env=$EnvFile)..." -ForegroundColor Cyan
    & docker @composeArgs up -d --build
} elseif ($NoBuild) {
    Write-Host "[run-env] Starting developer-infra (mode=$Mode, profile=$buildProfile, source=cached, env=$EnvFile)..." -ForegroundColor Cyan
    & docker @composeArgs up -d --no-build
} else {
    $imageRef = "${imageRepo}:${buildProfile}"
    Write-Host "[run-env] Pulling pre-built image ($imageRef)..." -ForegroundColor Cyan
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & docker @composeArgs pull ubuntu-dev
    $pullRc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    if ($pullRc -eq 0) {
        Write-Host "[run-env] Starting developer-infra (mode=$Mode, profile=$buildProfile, source=registry, env=$EnvFile)..." -ForegroundColor Cyan
        & docker @composeArgs up -d --no-build
    } else {
        Write-Host "[run-env] Pre-built image unavailable ($imageRef); falling back to local BuildKit build..." -ForegroundColor Yellow
        Write-Host "[run-env] Starting developer-infra (mode=$Mode, profile=$buildProfile, source=local-build, env=$EnvFile)..." -ForegroundColor Cyan
        & docker @composeArgs up -d --build
    }
}
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host ""
if ($buildProfile -eq "lite") {
    Write-Host "Ready (profile=lite: VPN + Chromium verification build):" -ForegroundColor Green
    Write-Host "  noVNC       : http://${bindHost}:${novncPort}/vnc.html"
    Write-Host "  VPN status  : .\vpn-ctl.ps1 status  (in Chromium: http://127.0.0.1:9099)"
    Write-Host "  Diagnostics : .\diag-env.ps1"
    Write-Host "  Upgrade full: .\run-env.ps1 -Profile full -AutoPort"
} else {
    Write-Host "Ready (profile=full):" -ForegroundColor Green
    Write-Host "  code-server : http://${bindHost}:${codePort}"
    Write-Host "  noVNC       : http://${bindHost}:${novncPort}/vnc.html"
    Write-Host "  OmniRoute   : http://${bindHost}:${omniPort}"
    Write-Host "  VPN status  : .\vpn-ctl.ps1 status  (in Chromium: http://127.0.0.1:9099)"
    Write-Host "  Claude Code : .\start-claude.ps1"
}
Write-Host ""

if (-not $Detach) {
    & docker @composeArgs exec -it -u coder -w /home/coder/workspace ubuntu-dev bash
    exit $LASTEXITCODE
}
