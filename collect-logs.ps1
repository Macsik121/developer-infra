<#
.SYNOPSIS
    Interactive & CLI supervisor log collector for developer-infra (Windows PowerShell 5.1 & 7+).

.EXAMPLE
    .\collect-logs.ps1
    .\collect-logs.ps1 -Scope vpn -Lines 50
    .\collect-logs.ps1 -Scope all -Lines 30 -OutFile diagnostics\my-logs.log
    .\collect-logs.ps1 -Scope sing-box -Lines 100
#>

[CmdletBinding()]
param(
    [string]$Scope = "",
    [int]$Lines = 50,
    [string]$OutFile = "",
    [string]$EnvFile = ".env",
    [string]$ContainerId = "",
    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if ($Help) {
    Write-Host @"
Usage: .\collect-logs.ps1 [OPTIONS]

Options:
  -Scope <all|vpn|gui|dev|service-name>  Log group or single supervisor package (interactive menu if omitted)
  -Lines <N>                             Number of tail lines per .out/.err log (default: 50)
  -OutFile <path>                        Target output file path (default: diagnostics\logs-<scope>-<ts>.log)
  -EnvFile <path>                        Path to .env file (default: .env)
  -ContainerId <id>                      Optional pre-resolved container ID (skips docker compose lookup)
  -Help, -h                              Show this help

Groups:
  all  : sing-box, vpn-sub-updater, vpn-watchdog, vpn-status, xvfb, fluxbox, x11vnc, novnc, chromium, code-server, omniroute
  vpn  : sing-box, vpn-sub-updater, vpn-watchdog, vpn-status
  gui  : xvfb, fluxbox, x11vnc, novnc, chromium
  dev  : code-server, omniroute
"@
    exit 0
}

$allPackages = @(
    "sing-box",
    "vpn-sub-updater",
    "vpn-watchdog",
    "vpn-status",
    "xvfb",
    "fluxbox",
    "x11vnc",
    "novnc",
    "chromium",
    "code-server",
    "omniroute"
)
$vpnPackages = @("sing-box", "vpn-sub-updater", "vpn-watchdog", "vpn-status")
$guiPackages = @("xvfb", "fluxbox", "x11vnc", "novnc", "chromium")
$devPackages = @("code-server", "omniroute")

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Error "Docker CLI not found."
    exit 1
}
$dockerExe = $dockerCmd.Source
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

    return @{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
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

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Error "Env file '$EnvFile' not found."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ContainerId)) {
    $cidRes = Invoke-DockerClean @("compose", "--env-file", $EnvFile, "ps", "-q", "ubuntu-dev")
    $ContainerId = ($cidRes.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($ContainerId)) {
        Write-Error "Container 'ubuntu-dev' is not running. Start it with .\run-env.ps1 -AutoPort"
        exit 1
    }
    $ContainerId = $ContainerId.Trim()
}

# Interactive prompt if -Scope was not provided
$selectedPackages = @()
$scopeLabel = $Scope.Trim().ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($scopeLabel)) {
    Write-Host ""
    Write-Host "=== developer-infra Log Collector ===" -ForegroundColor Cyan
    Write-Host "Select which supervisor logs to collect:"
    Write-Host "  1) All packages (all)"
    Write-Host "  2) VPN / TUN stack (sing-box, vpn-sub-updater, vpn-watchdog, vpn-status)"
    Write-Host "  3) Graphics / GUI stack (xvfb, fluxbox, x11vnc, novnc, chromium)"
    Write-Host "  4) IDE & AI stack (code-server, omniroute)"
    Write-Host "  5) Single package (choose one)"
    Write-Host ""
    $choice = (Read-Host "Enter choice [1-5, default: 1]").Trim()
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

    switch ($choice) {
        "1" { $scopeLabel = "all" }
        "2" { $scopeLabel = "vpn" }
        "3" { $scopeLabel = "gui" }
        "4" { $scopeLabel = "dev" }
        "5" {
            Write-Host ""
            Write-Host "Available packages:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $allPackages.Count; $i++) {
                Write-Host ("  {0,2}) {1}" -f ($i + 1), $allPackages[$i])
            }
            $pkgPick = (Read-Host "Enter number [1-$($allPackages.Count)] or package name").Trim()
            $pickInt = 0
            if ([int]::TryParse($pkgPick, [ref]$pickInt) -and $pickInt -ge 1 -and $pickInt -le $allPackages.Count) {
                $scopeLabel = $allPackages[$pickInt - 1]
            } elseif (-not [string]::IsNullOrWhiteSpace($pkgPick)) {
                $scopeLabel = $pkgPick.ToLowerInvariant()
            } else {
                $scopeLabel = "sing-box"
            }
        }
        default { $scopeLabel = $choice.ToLowerInvariant() }
    }

    $linesInput = (Read-Host "Tail lines per log file [default: $Lines]").Trim()
    $parsedLines = 0
    if ([int]::TryParse($linesInput, [ref]$parsedLines) -and $parsedLines -gt 0) {
        $Lines = $parsedLines
    }
}

switch ($scopeLabel) {
    "all" { $selectedPackages = $allPackages }
    "vpn" { $selectedPackages = $vpnPackages }
    "gui" { $selectedPackages = $guiPackages }
    "dev" { $selectedPackages = $devPackages }
    default {
        if ($allPackages -contains $scopeLabel) {
            $selectedPackages = @($scopeLabel)
        } else {
            Write-Error "Unknown scope or package '$scopeLabel'. Allowed: all, vpn, gui, dev, or one of: $($allPackages -join ', ')"
            exit 1
        }
    }
}

if ($Lines -lt 1) { $Lines = 50 }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $diagDir = Join-Path (Get-Location).Path "diagnostics"
    if (-not (Test-Path -LiteralPath $diagDir)) {
        New-Item -ItemType Directory -Path $diagDir -Force | Out-Null
    }
    $OutFile = Join-Path $diagDir ("logs-" + $scopeLabel + "-" + $timestamp + ".log")
} else {
    $parentDir = Split-Path -Parent $OutFile
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and (-not (Test-Path -LiteralPath $parentDir))) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
}

$absOut = [System.IO.Path]::GetFullPath($OutFile)

$header = @(
    "########################################################################",
    "# developer-infra Supervisor Log Bundle",
    "# Scope    : $scopeLabel",
    "# Packages : $($selectedPackages -join ', ')",
    "# Tail     : $Lines lines per file",
    "# Created  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "########################################################################",
    ""
) -join [Environment]::NewLine

[System.IO.File]::WriteAllText($absOut, $header + [Environment]::NewLine, $utf8NoBom)

$capturedCount = 0
$pkgIdx = 0
$pkgTotal = $selectedPackages.Count
foreach ($pkg in $selectedPackages) {
    $pkgIdx++
    Write-Host ("  .. [collect-logs {0}/{1}] Reading {2} (out + err, tail={3})..." -f $pkgIdx, $pkgTotal, $pkg, $Lines) -ForegroundColor DarkGray
    foreach ($stream in @("out", "err")) {
        $logPath = "/var/log/supervisor/$pkg.$stream.log"
        $nowStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        $bashScript = "if [ -f '$logPath' ]; then if [ -s '$logPath' ]; then tail -n $Lines '$logPath'; else echo '(file exists, empty)'; fi; else echo '(file not found)'; fi"
        $res = Invoke-DockerClean @("exec", "-i", "-u", "root", $ContainerId, "bash", "-s") $bashScript
        $rawOut = $res.Stdout
        if (-not [string]::IsNullOrWhiteSpace($res.Stderr)) {
            $rawOut = ($rawOut.TrimEnd() + [Environment]::NewLine + $res.Stderr.TrimEnd()).Trim()
        }
        $body = Redact-Secrets ($rawOut.TrimEnd())

        $section = @(
            "========================================================================",
            "[LOG APPENDED] $logPath  (tail -n $Lines)",
            "Package  : $pkg | Stream: $stream | Captured: $nowStr",
            "========================================================================",
            $body,
            ""
        ) -join [Environment]::NewLine

        [System.IO.File]::AppendAllText($absOut, $section + [Environment]::NewLine, $utf8NoBom)
        $capturedCount++
    }
}

Write-Host "[collect-logs] Collected $capturedCount log streams ($scopeLabel, tail=$Lines)." -ForegroundColor Green
Write-Host "[collect-logs] Saved to: $absOut" -ForegroundColor Cyan
