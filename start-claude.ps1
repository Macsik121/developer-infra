<#
.SYNOPSIS
    Launches Claude Code with model selection via OmniRoute proxy.

.DESCRIPTION
    Validates dependencies, manages persistent model configurations, starts the OmniRoute
    proxy if needed, configures environment variables, and launches Claude Code.

.PARAMETER Command
    The Claude command to run (e.g., "claude" or "claude make team work").

.PARAMETER Model
    The model ID number to use. If omitted or out of range, prompts interactively.

.PARAMETER AddModel
    Switch to launch directly into the Add Model workflow.

.PARAMETER RemoveModel
    Switch to launch directly into the Remove Model workflow.

.EXAMPLE
    .\start_claude.ps1
    .\start_claude.ps1 -Command "claude" -Model 1
    .\start_claude.ps1 -AddModel
#>

[CmdletBinding()]
param(
    [string]$Command = "",
    [int]$Model = 0,
    [switch]$AddModel,
    [switch]$RemoveModel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:MODELS_FILE = Join-Path $PSScriptRoot "claude_models.json"
$script:OMNIROUTE_PORT = 20128
$script:OMNIROUTE_URL = "http://localhost:$($script:OMNIROUTE_PORT)"

function Write-ColorOutput {
    param(
        [AllowEmptyString()][string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Test-Dependencies {
    $requiredCommands = @("node", "omniroute", "claude")
    $missing = @()

    foreach ($cmd in $requiredCommands) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            $missing += $cmd
        }
    }

    if ($missing.Count -gt 0) {
        Write-ColorOutput "ERROR: Missing required dependencies: $($missing -join ', ')" "Red"
        Write-ColorOutput "Please ensure Node.js, OmniRoute (npm i -g omniroute), and Claude Code CLI are installed and in your PATH." "Yellow"
        exit 1
    }
}

function Get-DefaultModels {
    return [ordered]@{
        1  = "kr/claude-sonnet-4.5"
        2  = "kr/glm-5[1m]"
        3  = "agentrouter/claude-opus-5"
        4  = "agentrouter/claude-opus-4.8"
        5  = "agentrouter/deepseek-v4-flash"
        6  = "antigravity/claude-sonnet-4-6"
        7  = "antigravity/claude-opus-4-6-thinking"
        8  = "antigravity/gemini-3.1-flash-lite"
        9  = "nvidia/nvidia/nemotron-3-super-120b-a12b"
        10 = "nvidia/nvidia/nemotron-3-ultra-550b-a55b"
    }
}

function Get-Models {
    if (Test-Path $script:MODELS_FILE) {
        try {
            $modelsJson = Get-Content $script:MODELS_FILE -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($modelsJson)) {
                $modelsObj = $modelsJson | ConvertFrom-Json
                $models = @{}
                foreach ($prop in $modelsObj.PSObject.Properties) {
                    $models[[int]$prop.Name] = [string]$prop.Value
                }
                if ($models.Count -gt 0) {
                    return (Renumber-Models -Models $models)
                }
            }
        }
        catch {
            Write-ColorOutput "Warning: Could not parse $($script:MODELS_FILE). Falling back to default models." "Yellow"
        }
    }

    $defaults = @{}
    $orderedDefaults = Get-DefaultModels
    foreach ($key in $orderedDefaults.Keys) {
        $defaults[[int]$key] = $orderedDefaults[$key]
    }
    return $defaults
}

function Renumber-Models {
    param([hashtable]$Models)

    $sortedValues = $Models.GetEnumerator() | Sort-Object { [int]$_.Key } | ForEach-Object { $_.Value }
    $renumbered = @{}
    $newId = 1

    foreach ($val in $sortedValues) {
        $renumbered[$newId] = $val
        $newId++
    }

    return $renumbered
}

function Save-Models {
    param([hashtable]$Models)

    $orderedJson = [ordered]@{}
    $Models.GetEnumerator() | Sort-Object { [int]$_.Key } | ForEach-Object {
        $orderedJson[$_.Key.ToString()] = $_.Value
    }

    $orderedJson | ConvertTo-Json | Set-Content -Path $script:MODELS_FILE -Encoding UTF8
    Write-ColorOutput "Models saved to: $($script:MODELS_FILE)" "Green"
}

function Show-ModelList {
    param([hashtable]$Models)

    $Models.GetEnumerator() | Sort-Object { [int]$_.Key } | ForEach-Object {
        Write-Host (" {0,2}. {1}" -f $_.Key, $_.Value)
    }
    Write-Host ""
}

function Add-Model {
    Write-ColorOutput "`n=== Add New Model ===" "Cyan"
    $newModelString = (Read-Host "Enter model string (e.g., 'provider/model-name')").Trim()

    if ([string]::IsNullOrWhiteSpace($newModelString)) {
        Write-ColorOutput "ERROR: Model string cannot be empty." "Red"
        exit 1
    }

    $models = Renumber-Models -Models (Get-Models)
    $nextId = $models.Count + 1
    $models[$nextId] = $newModelString

    Save-Models -Models $models

    Write-ColorOutput "`nModel added successfully!" "Green"
    Write-ColorOutput "  ID: $nextId" "White"
    Write-ColorOutput "  Model: $newModelString" "White"
}

function Remove-Model {
    Write-ColorOutput "`n=== Remove Model ===" "Cyan"
    $models = Renumber-Models -Models (Get-Models)

    if ($models.Count -eq 0) {
        Write-ColorOutput "No models found to remove." "Yellow"
        return
    }

    Write-ColorOutput "`nCurrent models:" "Yellow"
    Show-ModelList -Models $models

    $modelIdInput = (Read-Host "Enter model ID to remove (or 'cancel')").Trim()
    if ($modelIdInput -ieq "cancel") {
        Write-ColorOutput "Operation cancelled." "Yellow"
        return
    }

    if ($modelIdInput -notmatch '^\d+$') {
        Write-ColorOutput "ERROR: Invalid ID. Please enter a numeric ID." "Red"
        exit 1
    }

    $modelId = [int]$modelIdInput
    if (-not $models.ContainsKey($modelId)) {
        Write-ColorOutput "ERROR: Model ID $modelId not found." "Red"
        exit 1
    }

    $removedModel = $models[$modelId]
    $confirm = (Read-Host "Remove model '$removedModel'? (y/n)").Trim()

    if ($confirm -ine "y") {
        Write-ColorOutput "Operation cancelled." "Yellow"
        return
    }

    $models.Remove($modelId)
    $models = Renumber-Models -Models $models
    Save-Models -Models $models

    Write-ColorOutput "`nModel removed successfully!" "Green"
    Write-ColorOutput "  Removed: $removedModel" "White"
}

function Test-OmnirouteHealth {
    param([string]$Url)
    try {
        $null = Invoke-WebRequest -Uri $Url -Method Get -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# ============================================
# Mode Routing (CLI vs Interactive)
# ============================================
if ($AddModel) {
    Add-Model
    exit 0
}
if ($RemoveModel) {
    Remove-Model
    exit 0
}

# Only show the mode selection menu if no CLI execution parameters were passed
if ([string]::IsNullOrWhiteSpace($Command) -and $Model -eq 0) {
    Write-ColorOutput "Claude Code via OmniRoute Launcher`n" "Cyan"
    Write-ColorOutput "Select mode:`n  1. Run Claude (select model and launch)`n  2. Add new model to list`n  3. Remove model from list`n" "Yellow"

    $modeChoice = (Read-Host "Enter your choice (1, 2, or 3) [default: 1]").Trim()
    if ([string]::IsNullOrEmpty($modeChoice)) { $modeChoice = "1" }

    switch ($modeChoice) {
        "1" { }
        "2" { Add-Model; exit 0 }
        "3" { Remove-Model; exit 0 }
        default {
            Write-ColorOutput "ERROR: Invalid choice. Please enter 1, 2, or 3." "Red"
            exit 1
        }
    }
}

# Pre-flight check before launching Claude workflow
Test-Dependencies

# ============================================
# Phase 1: Get Claude Command
# ============================================
if ([string]::IsNullOrWhiteSpace($Command)) {
    $inputCmd = (Read-Host "Enter Claude command [default: 'claude']").Trim()
    $Command = if ([string]::IsNullOrWhiteSpace($inputCmd)) { "claude" } else { $inputCmd }
}

# ============================================
# Phase 2: Get Auth Token
# ============================================
Write-ColorOutput "`nChecking authentication token..." "Cyan"
$authToken = $env:ANTHROPIC_AUTH_TOKEN

if ([string]::IsNullOrWhiteSpace($authToken)) {
    Write-ColorOutput "ANTHROPIC_AUTH_TOKEN environment variable not set." "Yellow"
    Write-ColorOutput "Tip: Persist it in your session via `$env:ANTHROPIC_AUTH_TOKEN = 'your-key'" "DarkGray"
    Write-ColorOutput "Please enter your OmniRoute API Key (input will be hidden):" "Yellow"

    $secureToken = Read-Host -AsSecureString
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        $authToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    if ([string]::IsNullOrWhiteSpace($authToken)) {
        Write-ColorOutput "ERROR: Authentication token cannot be empty." "Red"
        exit 1
    }
}

# ============================================
# Phase 3: Select Model
# ============================================
$MODELS = Get-Models
$maxId = $MODELS.Count

if ($Model -lt 1 -or $Model -gt $maxId -or -not $MODELS.ContainsKey($Model)) {
    Write-ColorOutput "`nSelect Claude model:" "Cyan"
    Show-ModelList -Models $MODELS

    $modelInput = (Read-Host "Enter model number (1-$maxId)").Trim()
    if ($modelInput -notmatch '^\d+$' -or -not $MODELS.ContainsKey([int]$modelInput)) {
        Write-ColorOutput "ERROR: Invalid model choice. Please enter a number from 1 to $maxId." "Red"
        exit 1
    }
    $Model = [int]$modelInput
}

$selectedModel = $MODELS[$Model]
Write-ColorOutput "Selected model: $selectedModel" "Green"

# ============================================
# Phase 4: Check and Start OmniRoute
# ============================================
Write-ColorOutput "`nChecking OmniRoute status..." "Cyan"

if (Test-OmnirouteHealth -Url $script:OMNIROUTE_URL) {
    Write-ColorOutput "OmniRoute is already running and healthy." "Green"
}
else {
    Write-ColorOutput "OmniRoute is not running. Starting it..." "Yellow"

    $currentShell = (Get-Process -Id $PID).Path
    if (-not $currentShell) { $currentShell = "powershell" }

    $omnirouteProcess = Start-Process -FilePath $currentShell `
        -ArgumentList "-NoExit", "-Command", "Write-Host 'OmniRoute Server' -ForegroundColor Cyan; Write-Host 'Press Ctrl+C to stop'; Write-Host ''; omniroute --port=$($script:OMNIROUTE_PORT)" `
        -PassThru `
        -WindowStyle Normal

    Write-ColorOutput "OmniRoute started in separate window (PID: $($omnirouteProcess.Id))" "Green"
    Write-ColorOutput "Waiting for OmniRoute to become healthy..." "Cyan"

    $maxAttempts = 30
    $isHealthy = $false

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Start-Sleep -Seconds 1
        if (Test-OmnirouteHealth -Url $script:OMNIROUTE_URL) {
            Write-ColorOutput "OmniRoute is now healthy (attempt $attempt/$maxAttempts)" "Green"
            $isHealthy = $true
            break
        }
        Write-Host "Waiting... (attempt $attempt/$maxAttempts)"
    }

    if (-not $isHealthy) {
        Write-ColorOutput "ERROR: OmniRoute failed to start after $maxAttempts seconds." "Red"
        Write-ColorOutput "Check the OmniRoute window for error messages." "Yellow"
        exit 1
    }
}

# ============================================
# Phase 5: Set Environment Variables
# ============================================
Write-ColorOutput "`nSetting up environment..." "Cyan"

$env:ANTHROPIC_AUTH_TOKEN          = $authToken
$env:ANTHROPIC_BASE_URL            = "$($script:OMNIROUTE_URL)/v1"
$env:ANTHROPIC_MODEL               = $selectedModel
$env:ANTHROPIC_deepseek_MODEL      = "deepseek-v4-flash"
$env:ENABLE_CC_COMPATIBLE_PROVIDER = "true"
$env:CLAUDE_CODE_SKIP_UPDATE_CHECK = "1"
$env:CLAUDE_CODE_DISABLE_ARTIFACT  = "1"

$env:ANTHROPIC_DEFAULT_SONNET_MODEL=$selectedModel
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL=$selectedModel
$env:ANTHROPIC_DEFAULT_OPUS_MODEL=$selectedModel
$env:CLAUDE_CODE_SUBAGENT_MODEL=glm-5.2
$env:CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1

Write-ColorOutput "Environment configured:" "Green"
Write-Host "  ANTHROPIC_MODEL    = $selectedModel"
Write-Host "  ANTHROPIC_BASE_URL = $($env:ANTHROPIC_BASE_URL)"

# ============================================
# Phase 6: Launch Claude
# ============================================
Write-ColorOutput "`nStarting Claude Code via OmniRoute..." "Cyan"
Write-ColorOutput "Command: $Command" "White"
Write-ColorOutput "`n========================================" "DarkGray"
Write-Host ""

$exitCode = 0
try {
    $global:LASTEXITCODE = 0
    Invoke-Expression $Command
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        $exitCode = $LASTEXITCODE
    }
}
catch {
    Write-ColorOutput "`nERROR: Failed to execute command." "Red"
    Write-ColorOutput $_.Exception.Message "Red"
    exit 1
}

# ============================================
# Phase 7: Cleanup Instructions
# ============================================
Write-ColorOutput "`n========================================" "DarkGray"
if ($exitCode -ne 0) {
    Write-ColorOutput "ERROR: Command exited with code $exitCode." "Red"
    exit $exitCode
}

Write-ColorOutput "Session ended." "Cyan"
Write-ColorOutput "OmniRoute is still running in the separate window." "Yellow"
Write-ColorOutput "Close that window when you're done, or leave it for next time." "Yellow"
exit 0
