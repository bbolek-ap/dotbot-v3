<#
.SYNOPSIS
Unified process launcher replacing both loop scripts and ad-hoc Start-Job calls.

.DESCRIPTION
Every Claude invocation is a tracked process. Creates a process registry entry,
builds the appropriate prompt, invokes Claude, and manages the lifecycle.

.PARAMETER Type
Process type: analysis, execution, kickstart, planning, commit, task-creation

.PARAMETER TaskId
Optional: specific task ID (for analysis/execution types)

.PARAMETER Prompt
Optional: custom prompt text (for kickstart/planning/commit/task-creation)

.PARAMETER Continue
If set, continue to next task after completion (analysis/execution only)

.PARAMETER Model
Claude model to use (default: Opus)

.PARAMETER ShowDebug
Show raw JSON events

.PARAMETER ShowVerbose
Show detailed tool results

.PARAMETER MaxTasks
Max tasks to process with -Continue (0 = unlimited)

.PARAMETER Description
Human-readable description for UI display

.PARAMETER ProcessId
Optional: resume an existing process by ID (skips creation)

.PARAMETER NoWait
If set with -Continue, exit when no tasks available instead of waiting.
Used by kickstart pipeline to prevent workflow children from blocking phase progression.
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('analysis', 'execution', 'workflow', 'kickstart', 'analyse', 'planning', 'commit', 'task-creation')]
    [string]$Type,

    [string]$TaskId,
    [string]$Prompt,
    [switch]$Continue,
    [string]$Model,
    [switch]$ShowDebug,
    [switch]$ShowVerbose,
    [int]$MaxTasks = 0,
    [string]$Description,
    [string]$ProcessId,
    [switch]$NeedsInterview,
    [switch]$AutoWorkflow,
    [switch]$NoWait,
    [string]$FromPhase,
    [string]$SkipPhases  # comma-separated phase IDs to skip
)

# Parse skip phases
$skipPhaseIds = if ($SkipPhases) { $SkipPhases -split ',' } else { @() }

# --- Configuration ---

# Determine phase for activity logging
$phaseMap = @{
    'analysis'      = 'analysis'
    'execution'     = 'execution'
    'workflow'      = 'workflow'
    'kickstart'     = 'execution'
    'analyse'       = 'execution'
    'planning'      = 'execution'
    'commit'        = 'execution'
    'task-creation' = 'execution'
}

$env:DOTBOT_CURRENT_PHASE = $phaseMap[$Type]

# Resolve paths
$botRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$controlDir = Join-Path $botRoot ".control"
$processesDir = Join-Path $controlDir "processes"
$projectRoot = Split-Path -Parent $botRoot
$global:DotbotProjectRoot = $projectRoot

# Ensure directories exist
if (-not (Test-Path $processesDir)) {
    New-Item -Path $processesDir -ItemType Directory -Force | Out-Null
}

# Import modules
Import-Module "$PSScriptRoot\ProviderCLI\ProviderCLI.psm1" -Force
Import-Module "$PSScriptRoot\ClaudeCLI\ClaudeCLI.psm1" -Force
Import-Module "$PSScriptRoot\modules\DotBotTheme.psm1" -Force
Import-Module "$PSScriptRoot\modules\InstanceId.psm1" -Force
Import-Module "$PSScriptRoot\modules\ProcessRegistry.psm1" -Force
Import-Module "$PSScriptRoot\modules\TaskLoop.psm1" -Force
$t = Get-DotBotTheme

. "$PSScriptRoot\modules\ui-rendering.ps1"
. "$PSScriptRoot\modules\prompt-builder.ps1"
. "$PSScriptRoot\modules\rate-limit-handler.ps1"

# Import process type scripts
. "$PSScriptRoot\modules\ProcessTypes\Invoke-AnalysisProcess.ps1"
. "$PSScriptRoot\modules\ProcessTypes\Invoke-ExecutionProcess.ps1"
. "$PSScriptRoot\modules\ProcessTypes\Invoke-WorkflowProcess.ps1"
. "$PSScriptRoot\modules\ProcessTypes\Invoke-KickstartProcess.ps1"
. "$PSScriptRoot\modules\ProcessTypes\Invoke-PromptProcess.ps1"
. "$PSScriptRoot\modules\ProcessTypes\Invoke-AnalyseProcess.ps1"

# Import task-based modules for analysis/execution/workflow types
if ($Type -in @('analysis', 'execution', 'workflow')) {
    Import-Module "$PSScriptRoot\..\mcp\modules\TaskIndexCache.psm1" -Force
    Import-Module "$PSScriptRoot\..\mcp\modules\SessionTracking.psm1" -Force
    . "$PSScriptRoot\modules\cleanup.ps1"
    . "$PSScriptRoot\modules\get-failure-reason.ps1"
    Import-Module "$PSScriptRoot\modules\WorktreeManager.psm1" -Force
    . "$PSScriptRoot\modules\test-task-completion.ps1"
    . "$PSScriptRoot\modules\create-problem-log.ps1"

    # MCP tool functions
    . "$PSScriptRoot\..\mcp\tools\session-initialize\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\session-get-state\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\session-get-stats\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\session-update\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\session-increment-completed\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\task-get-next\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\task-mark-in-progress\script.ps1"
    . "$PSScriptRoot\..\mcp\tools\task-mark-skipped\script.ps1"
}

if ($Type -in @('analysis', 'workflow')) {
    . "$PSScriptRoot\..\mcp\tools\task-mark-analysing\script.ps1"
}

# Load settings for model defaults
$settingsPath = Join-Path $botRoot "defaults\settings.default.json"
$settings = @{ execution = @{ model = 'Opus' }; analysis = @{ model = 'Opus' } }
if (Test-Path $settingsPath) {
    try { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch {}
}
# Workspace instance ID
$instanceId = Get-OrCreateWorkspaceInstanceId -SettingsPath $settingsPath
if (-not $instanceId) {
    $instanceId = ""
}

# Override model selections from UI settings
$uiSettingsPath = Join-Path $botRoot ".control\ui-settings.json"
if (Test-Path $uiSettingsPath) {
    try {
        $uiSettings = Get-Content $uiSettingsPath -Raw | ConvertFrom-Json
        if ($uiSettings.analysisModel) { $settings.analysis.model = $uiSettings.analysisModel }
        if ($uiSettings.executionModel) { $settings.execution.model = $uiSettings.executionModel }
    } catch {}
}

# Load provider config
$providerConfig = Get-ProviderConfig

# Resolve model (parameter > settings > provider default)
if (-not $Model) {
    $Model = switch ($Type) {
        { $_ -in @('analysis', 'kickstart') } { if ($settings.analysis?.model) { $settings.analysis.model } else { $providerConfig.default_model } }
        'workflow' { if ($settings.execution?.model) { $settings.execution.model } else { $providerConfig.default_model } }
        default    { if ($settings.execution?.model) { $settings.execution.model } else { $providerConfig.default_model } }
    }
}

try {
    $claudeModelName = Resolve-ProviderModelId -ModelAlias $Model
} catch {
    Write-Warning "Model '$Model' not valid for active provider. Falling back to '$($providerConfig.default_model)'."
    $claudeModelName = Resolve-ProviderModelId -ModelAlias $providerConfig.default_model
}
$env:CLAUDE_MODEL = $claudeModelName
$env:DOTBOT_MODEL = $claudeModelName

# --- Crash Trap ---
trap {
    if ($procId -and $processData -and $processData.status -in @('running', 'starting')) {
        $processData.status = 'stopped'
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.error = "Unexpected termination: $($_.Exception.Message)"
        try { Write-ProcessFile -Id $procId -Data $processData -ProcessesDir $processesDir } catch {}
        try { Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process terminated unexpectedly: $($_.Exception.Message)" -ProcessesDir $processesDir } catch {}
    }
    try { Remove-ProcessLock -LockType $Type -ControlDir $controlDir } catch {}
}

# --- Preflight checks ---
$preflight = Test-Preflight -BotRoot $botRoot -ProviderConfig $providerConfig
if (-not $preflight.passed) {
    Write-Warning "Preflight checks failed:"
    foreach ($check in $preflight.checks) {
        if ($check -match 'MISSING') { Write-Warning "  $check" }
    }
    exit 1
}

# --- Single-instance guard ---
if (Test-ProcessLock -LockType $Type -ControlDir $controlDir) {
    $existingPid = (Get-Content (Join-Path $controlDir "launch-$Type.lock") -Raw).Trim()
    Write-Warning "Another $Type process is already running (PID $existingPid). Exiting."
    exit 1
}
Set-ProcessLock -LockType $Type -ControlDir $controlDir

# --- Initialize Process ---
$procId = if ($ProcessId) { $ProcessId } else { New-ProcessId }
$sessionId = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
$claudeSessionId = New-ProviderSession

# Set process ID env var for dual-write activity logging in ClaudeCLI
$env:DOTBOT_PROCESS_ID = $procId

$processData = @{
    id              = $procId
    type            = $Type
    status          = 'starting'
    task_id         = $TaskId
    task_name       = $null
    continue        = [bool]$Continue
    no_wait         = [bool]$NoWait
    model           = $Model
    pid             = $PID
    session_id      = $sessionId
    claude_session_id = $claudeSessionId
    started_at      = (Get-Date).ToUniversalTime().ToString("o")
    last_heartbeat  = (Get-Date).ToUniversalTime().ToString("o")
    heartbeat_status = "Starting $Type process"
    heartbeat_next_action = $null
    last_whisper_index = 0
    completed_at    = $null
    failed_at       = $null
    tasks_completed = 0
    error           = $null
    workflow        = $null
    description     = $Description
    phases          = @()
    skip_phases     = $skipPhaseIds
}

Write-ProcessFile -Id $procId -Data $processData -ProcessesDir $processesDir

# Initialize diagnostic log
$script:diagLogPath = Join-Path $controlDir "diag-$procId.log"
Initialize-DiagLog -DiagLogPath $script:diagLogPath
Write-Diag -Msg "=== Process started: Type=$Type, ProcId=$procId, PID=$PID, Continue=$Continue, NoWait=$NoWait ==="
Write-Diag -Msg "BotRoot=$botRoot | ProcessesDir=$processesDir | ProjectRoot=$projectRoot"
$procFilePath = Join-Path $processesDir "$procId.json"
Write-Diag -Msg "Process file exists: $(Test-Path $procFilePath) at $procFilePath"

# Banner
Write-Card -Title "PROCESS: $($Type.ToUpper())" -Width 50 -BorderStyle Rounded -BorderColor Label -TitleColor Label -Lines @(
    "$($t.Label)ID:$($t.Reset)    $($t.Cyan)$procId$($t.Reset)"
    "$($t.Label)Model:$($t.Reset) $($t.Purple)$Model$($t.Reset)"
    "$($t.Label)Type:$($t.Reset)  $($t.Amber)$Type$($t.Reset)"
)

Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId started ($Type)" -ProcessesDir $processesDir
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Preflight OK: $($preflight.checks -join '; ')" -ProcessesDir $processesDir

# --- Dispatch to process type handler ---
try {
    $commonParams = @{
        ProcId       = $procId
        ProcessData  = $processData
        BotRoot      = $botRoot
        ProcessesDir = $processesDir
        ControlDir   = $controlDir
        ClaudeModelName = $claudeModelName
    }

    switch ($Type) {
        'analysis' {
            Invoke-AnalysisProcess @commonParams `
                -ProjectRoot $projectRoot `
                -SessionId $sessionId `
                -Settings $settings `
                -InstanceId $instanceId `
                -TaskId $TaskId `
                -Continue:$Continue `
                -NoWait:$NoWait `
                -MaxTasks $MaxTasks `
                -ShowDebug:$ShowDebug `
                -ShowVerbose:$ShowVerbose
        }
        'execution' {
            Invoke-ExecutionProcess @commonParams `
                -ProjectRoot $projectRoot `
                -SessionId $sessionId `
                -Settings $settings `
                -InstanceId $instanceId `
                -TaskId $TaskId `
                -Continue:$Continue `
                -NoWait:$NoWait `
                -MaxTasks $MaxTasks `
                -ShowDebug:$ShowDebug `
                -ShowVerbose:$ShowVerbose
        }
        'workflow' {
            Invoke-WorkflowProcess @commonParams `
                -ProjectRoot $projectRoot `
                -SessionId $sessionId `
                -Settings $settings `
                -InstanceId $instanceId `
                -TaskId $TaskId `
                -Continue:$Continue `
                -NoWait:$NoWait `
                -MaxTasks $MaxTasks `
                -ShowDebug:$ShowDebug `
                -ShowVerbose:$ShowVerbose
        }
        'kickstart' {
            Invoke-KickstartProcess @commonParams `
                -ProjectRoot $projectRoot `
                -Settings $settings `
                -Prompt $Prompt `
                -Description $Description `
                -NeedsInterview:$NeedsInterview `
                -AutoWorkflow:$AutoWorkflow `
                -FromPhase $FromPhase `
                -SkipPhaseIds $skipPhaseIds `
                -ShowDebug:$ShowDebug `
                -ShowVerbose:$ShowVerbose
        }
        'analyse' {
            Invoke-AnalyseProcess @commonParams `
                -ClaudeSessionId $claudeSessionId `
                -Prompt $Prompt `
                -Description $Description `
                -ShowDebug:$ShowDebug `
                -ShowVerbose:$ShowVerbose
        }
        { $_ -in @('planning', 'commit', 'task-creation') } {
            Invoke-PromptProcess @commonParams `
                -ClaudeSessionId $claudeSessionId `
                -Type $Type `
                -Prompt $Prompt `
                -Description $Description `
                -ShowDebug:$ShowDebug `
                -ShowVerbose:$ShowVerbose
        }
    }
} finally {
    # Cleanup env vars
    Remove-ProcessLock -LockType $Type -ControlDir $controlDir
    $env:DOTBOT_PROCESS_ID = $null
    $env:DOTBOT_CURRENT_TASK_ID = $null
    $env:DOTBOT_CURRENT_PHASE = $null
}

# Output process ID for caller to use
Write-Host ""
try { Write-Status "Process $procId finished with status: $($processData.status)" -Type Info } catch { Write-Host "Process $procId finished with status: $($processData.status)" }

# 5-second countdown before window closes
Write-Host ""
for ($i = 5; $i -ge 1; $i--) {
    Write-Host "`r  Window closing in ${i}s..." -NoNewline
    Start-Sleep -Seconds 1
}
Write-Host ""
