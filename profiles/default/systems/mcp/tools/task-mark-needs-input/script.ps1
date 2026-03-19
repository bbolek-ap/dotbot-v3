Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force

function Invoke-TaskMarkNeedsInput {
    param(
        [hashtable]$Arguments
    )

    $taskId        = $Arguments['task_id']
    $question      = $Arguments['question']
    $splitProposal = $Arguments['split_proposal']

    if (-not $taskId) { throw "Task ID is required" }
    if (-not $question -and -not $splitProposal) { throw "Either a question or split_proposal is required" }
    if ($question -and $splitProposal)            { throw "Cannot provide both question and split_proposal - use one at a time" }

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Build the updates that will be applied by Move-TaskState
    $updates = @{
        pending_question = $null
        split_proposal   = $null
    }

    $pendingQuestion = $null
    $proposalRecord  = $null

    if ($question) {
        # We need a question_id, but we don't have the task content yet; use a temp placeholder.
        # The actual question ID will be computed after we read the file via Move-TaskState.
        # We'll do a post-move patch below.
        $updates['pending_question'] = @{
            id             = 'q_placeholder'
            question       = $question.question
            context        = $question.context
            options        = $question.options
            recommendation = if ($question.recommendation) { $question.recommendation } else { "A" }
            asked_at       = $now
        }
    } elseif ($splitProposal) {
        $updates['split_proposal'] = @{
            reason      = $splitProposal.reason
            sub_tasks   = $splitProposal.sub_tasks
            proposed_at = $now
        }
        $proposalRecord = $updates['split_proposal']
    }

    $result = Move-TaskState `
        -TaskId     $taskId `
        -FromStates @('analysing') `
        -ToState    'needs-input' `
        -Updates    $updates

    # Fix question ID now that we have access to the task (questions_resolved count)
    if ($question) {
        $task = $result.task
        if (-not $task.PSObject.Properties['questions_resolved']) {
            $task | Add-Member -NotePropertyName 'questions_resolved' -NotePropertyValue @() -Force
        }
        $questionId = "q$($task.questions_resolved.Count + 1)"
        $task.pending_question.id = $questionId
        $pendingQuestion = $task.pending_question
    }

    # Close current Claude session + save patched task
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Close-SessionOnTask -TaskContent $result.task -SessionId $claudeSessionId -Phase 'analysis'
    }
    $result.task | ConvertTo-Json -Depth 20 | Set-Content -Path $result.new_path -Encoding UTF8

    # External notification (opt-in)
    try {
        $notifModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\NotificationClient.psm1"
        if (Test-Path $notifModule) {
            Import-Module $notifModule -Force
            $settings = Get-NotificationSettings
            if ($settings.enabled -and $question) {
                $sendResult = Send-TaskNotification -TaskContent $result.task -PendingQuestion $result.task.pending_question
                if ($sendResult.success) {
                    $result.task | Add-Member -NotePropertyName 'notification' -NotePropertyValue @{
                        question_id = $sendResult.question_id
                        instance_id = $sendResult.instance_id
                        channel     = $sendResult.channel
                        project_id  = $sendResult.project_id
                        sent_at     = $now
                    } -Force
                    $result.task | ConvertTo-Json -Depth 20 | Set-Content -Path $result.new_path -Encoding UTF8
                }
            }
        }
    } catch { }

    $output = @{
        success    = $true
        message    = if ($question) { "Task paused for human input - question pending" } else { "Task paused for human input - split proposal pending" }
        task_id    = $taskId
        task_name  = $result.task.name
        old_status = $result.old_status
        new_status = 'needs-input'
        file_path  = $result.new_path
    }

    if ($question)       { $output['pending_question'] = $pendingQuestion }
    elseif ($splitProposal) { $output['split_proposal'] = $proposalRecord }

    return $output
}
