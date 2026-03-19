Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force

function Invoke-TaskMarkInProgress {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    if (-not $taskId) {
        throw "Task ID is required"
    }

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Check "already completed" case before attempting the move
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $doneDir = Join-Path $tasksBaseDir "done"
    if (Test-Path $doneDir) {
        foreach ($file in (Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $taskId) {
                    return @{
                        success           = $true
                        message           = "Task '$($content.name)' is already completed"
                        task_id           = $taskId
                        status            = "done"
                        already_completed = $true
                    }
                }
            } catch { }
        }
    }

    $result = Move-TaskState `
        -TaskId     $taskId `
        -FromStates @('analysed', 'todo') `
        -ToState    'in-progress' `
        -Updates    @{
            started_at = $now
        }

    if ($result.already_in_state) {
        return @{
            success   = $true
            message   = "Task '$($result.task.name)' is already marked as in-progress"
            task_id   = $taskId
            status    = "in-progress"
        }
    }

    # Track Claude session for execution phase (post-move in-place update)
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Add-SessionToTask -TaskContent $result.task -SessionId $claudeSessionId -Phase 'execution'
        $result.task | ConvertTo-Json -Depth 10 | Set-Content -Path $result.new_path -Encoding UTF8
    }

    # Update session file if exists
    $sessionFile = Get-ChildItem (Join-Path $global:DotbotProjectRoot '.bot/sessions/session-*.json') -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime.Date -eq (Get-Date).Date } |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1

    if ($sessionFile) {
        try {
            $session = Get-Content $sessionFile.FullName | ConvertFrom-Json
            if (-not $session.tasks_attempted) {
                $session | Add-Member -NotePropertyName 'tasks_attempted' -NotePropertyValue @() -Force
            }
            $session.tasks_attempted += $taskId
            $session | ConvertTo-Json -Depth 10 | Set-Content $sessionFile.FullName
        } catch { }
    }

    return @{
        success      = $true
        message      = "Task '$($result.task.name)' marked as in-progress"
        task_id      = $taskId
        task_name    = $result.task.name
        old_status   = $result.old_status
        new_status   = "in-progress"
        file_path    = $result.new_path
        has_analysis = ($result.old_status -eq "analysed")
    }
}
