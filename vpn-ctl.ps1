<#
.SYNOPSIS
    Host wrapper for VPN kill-switch and node control inside ubuntu-dev (D6, D8, Patch v2.1).

.EXAMPLE
    .\vpn-ctl.ps1 status
    .\vpn-ctl.ps1 policy
    .\vpn-ctl.ps1 strict
    .\vpn-ctl.ps1 fallback
    .\vpn-ctl.ps1 proxy
    .\vpn-ctl.ps1 direct
    .\vpn-ctl.ps1 update
    .\vpn-ctl.ps1 retest
    .\vpn-ctl.ps1 select
    .\vpn-ctl.ps1 select 2
    .\vpn-ctl.ps1 select "NL-Reality-1"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("status", "policy", "strict", "fallback", "proxy", "direct", "update", "retest", "select", "help")]
    [string]$Action = "status",

    [Parameter(Position = 1)]
    [string]$Target = "",

    [string]$EnvFile = ".env"
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$argsList = @("compose", "--env-file", $EnvFile, "exec", "-T", "-u", "root", "ubuntu-dev", "/usr/local/bin/vpn-ctl", $Action)
if (-not [string]::IsNullOrWhiteSpace($Target)) {
    $argsList += $Target
}

& docker @argsList
exit $LASTEXITCODE
