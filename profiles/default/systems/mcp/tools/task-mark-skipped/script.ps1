Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force

function Invoke-TaskMarkSkipped {
    param(
        [hashtable]$Arguments
    )

    $taskId     = $Arguments['task_id']
    $skipReason = $Arguments['skip_reason']

    if (-not $taskId)     { throw "Task ID is required" }
    if (-not $skipReason) { throw "Skip reason is required" }

    $validReasons = @('non-recoverable', 'max-retries')
    if ($skipReason -notin $validReasons) {
        throw "Invalid skip reason. Must be one of: $($validReasons -join ', ')"
    }

    # Build new skip history entry; we'll merge after getting current task
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Read existing skip_history before the move so we can append to it
    $existing = Get-TaskByIdOrSlug -Identifier $taskId
    if (-not $existing) {
        throw "Task with ID '$taskId' not found"
    }

    $skipHistory = @()
    if ($existing.task.PSObject.Properties['skip_history'] -and $existing.task.skip_history) {
        if ($existing.task.skip_history -is [System.Collections.IEnumerable] -and $existing.task.skip_history -isnot [string]) {
            $skipHistory = @($existing.task.skip_history)
        } else {
            $skipHistory = @($existing.task.skip_history)
        }
    }
    $skipHistory += @{ skipped_at = $now; reason = $skipReason }

    $result = Move-TaskState `
        -TaskId     $taskId `
        -FromStates @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'split', 'cancelled') `
        -ToState    'skipped' `
        -Updates    @{
            skip_history = $skipHistory
        }

    return @{
        success      = $true
        message      = "Task marked as skipped"
        task_id      = $taskId
        task_name    = $result.task.name
        old_status   = $result.old_status
        new_status   = 'skipped'
        skip_reason  = $skipReason
        skip_count   = $skipHistory.Count
        skip_history = $skipHistory
        file_path    = $result.new_path
    }
}
