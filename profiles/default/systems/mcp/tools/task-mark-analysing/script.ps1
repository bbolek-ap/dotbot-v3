Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force

function Invoke-TaskMarkAnalysing {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    if (-not $taskId) {
        throw "Task ID is required"
    }

    [Console]::Error.WriteLine("[task-mark-analysing] taskId=$taskId")

    $result = Move-TaskState `
        -TaskId     $taskId `
        -FromStates @('todo') `
        -ToState    'analysing' `
        -Updates    @{
            analysis_started_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }

    if ($result.already_in_state) {
        return @{
            success             = $true
            message             = "Task already in analysing status"
            task_id             = $taskId
            task_name           = $result.task.name
            old_status          = 'analysing'
            new_status          = 'analysing'
            analysis_started_at = $result.task.analysis_started_at
            file_path           = $result.new_path
        }
    }

    # Track Claude session for conversation continuity (post-move in-place update)
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Add-SessionToTask -TaskContent $result.task -SessionId $claudeSessionId -Phase 'analysis'
        $result.task | ConvertTo-Json -Depth 10 | Set-Content -Path $result.new_path -Encoding UTF8
    }

    return @{
        success             = $true
        message             = "Task marked as analysing"
        task_id             = $taskId
        task_name           = $result.task.name
        old_status          = $result.old_status
        new_status          = 'analysing'
        analysis_started_at = $result.task.analysis_started_at
        file_path           = $result.new_path
    }
}
