<#
.SYNOPSIS
    Thin Windows host wrapper that launches Claude Code INSIDE the isolated
    developer-infra container (D3, D7). Never runs Node, OmniRoute, or Claude
    on the Windows host.

.EXAMPLE
    .\start-claude.ps1
    .\start-claude.ps1 -Command "claude" -Model 1
    .\start-claude.ps1 -AddModel
    .\start-claude.ps1 -RemoveModel
#>

[CmdletBinding()]
param(
    [Alias("c")]
    [string]$Command = "",

    [Alias("m")]
    [int]$Model = 0,

    [switch]$AddModel,
    [switch]$RemoveModel,

    [string]$EnvFile = ".env",

    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Write-Host @"
Usage: .\start-claude.ps1 [OPTIONS]

Runs Claude Code via the supervised OmniRoute proxy INSIDE the ubuntu-dev container.

Options:
  -Command, -c <str>   Claude command to execute inside container (e.g. "claude")
  -Model,   -m <int>   Model ID from ~/.config/omniroute/claude_models.json
  -AddModel            Add a model entry inside the container
  -RemoveModel         Remove a model entry inside the container
  -EnvFile <path>      Path to .env file (default: .env)
  -Help, -h            Show this help message
"@
    exit 0
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker CLI not found. Install Docker Desktop with WSL2 backend first."
    exit 1
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Error "Environment file '$EnvFile' not found. Run 'Copy-Item .env.example .env' and configure passwords first."
    exit 1
}

$composeArgs = @("compose", "--env-file", $EnvFile)

# Verify container service ubuntu-dev is running
$running = & docker @composeArgs ps --status running --services 2>$null
if (-not ($running -contains "ubuntu-dev")) {
    Write-Error "Service 'ubuntu-dev' is not running. Start the environment first with .\run-env.ps1"
    exit 1
}

$execArgs = @("compose", "--env-file", $EnvFile, "exec", "-it", "-u", "coder", "-w", "/home/coder/workspace")

if (-not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
    $execArgs += @("-e", "ANTHROPIC_AUTH_TOKEN=$($env:ANTHROPIC_AUTH_TOKEN)")
}

$execArgs += @("ubuntu-dev", "/usr/local/bin/start-claude")

if ($AddModel) {
    $execArgs += "--add-model"
} elseif ($RemoveModel) {
    $execArgs += "--remove-model"
} else {
    if (-not [string]::IsNullOrWhiteSpace($Command)) {
        $execArgs += @("--command", $Command)
    }
    if ($Model -gt 0) {
        $execArgs += @("--model", "$Model")
    }
}

& docker @execArgs
exit $LASTEXITCODE
