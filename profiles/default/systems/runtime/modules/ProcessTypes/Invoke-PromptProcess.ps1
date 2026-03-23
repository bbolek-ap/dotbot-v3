#Requires -Version 7.0

function Invoke-PromptProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcId,
        [Parameter(Mandatory)][hashtable]$ProcessData,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProcessesDir,
        [string]$ControlDir,
        [Parameter(Mandatory)][string]$ClaudeModelName,
        [Parameter(Mandatory)][string]$ClaudeSessionId,
        [Parameter(Mandatory)][ValidateSet('planning', 'commit', 'task-creation')][string]$Type,
        [string]$Prompt,
        [string]$Description,
        [switch]$ShowDebug,
        [switch]$ShowVerbose
    )

    $processData = $ProcessData

    # Determine workflow template
    $workflowFile = switch ($Type) {
        'planning'      { Join-Path $BotRoot "prompts\workflows\03-plan-roadmap.md" }
        'commit'        { Join-Path $BotRoot "prompts\workflows\90-commit-and-push.md" }
        'task-creation' { Join-Path $BotRoot "prompts\workflows\91-new-tasks.md" }
    }

    $processData.workflow = switch ($Type) {
        'planning'      { "03-plan-roadmap.md" }
        'commit'        { "90-commit-and-push.md" }
        'task-creation' { "91-new-tasks.md" }
    }

    # Build prompt
    $systemPrompt = ""
    if (Test-Path $workflowFile) {
        $systemPrompt = Get-Content $workflowFile -Raw
    }

    if ($Prompt) {
        $fullPrompt = @"
$systemPrompt

## Additional Context

$Prompt
"@
    } else {
        $fullPrompt = $systemPrompt
    }

    if (-not $Description) {
        $Description = switch ($Type) {
            'planning'      { "Plan roadmap" }
            'commit'        { "Commit and push changes" }
            'task-creation' { "Create new tasks" }
        }
    }

    $processData.status = 'running'
    $processData.description = $Description
    $processData.heartbeat_status = $Description
    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "$Description started" -ProcessesDir $ProcessesDir

    try {
        $streamArgs = @{
            Prompt = $fullPrompt
            Model = $ClaudeModelName
            SessionId = $ClaudeSessionId
            PersistSession = $false
        }
        if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

        Invoke-ProviderStream @streamArgs

        $processData.status = 'completed'
        $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.heartbeat_status = "Completed: $Description"
    } catch {
        $processData.status = 'failed'
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.error = $_.Exception.Message
        $processData.heartbeat_status = "Failed: $($_.Exception.Message)"
        Write-Status "Process failed: $($_.Exception.Message)" -Type Error
    } finally {
        $projectRoot = Split-Path $BotRoot -Parent
        try { Remove-ProviderSession -SessionId $ClaudeSessionId -ProjectRoot $projectRoot | Out-Null } catch {}
    }

    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Process $ProcId finished ($($processData.status))" -ProcessesDir $ProcessesDir
}
