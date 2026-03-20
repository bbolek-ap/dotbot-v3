#Requires -Version 7.0

function Invoke-AnalysisProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcId,
        [Parameter(Mandatory)][hashtable]$ProcessData,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ProcessesDir,
        [Parameter(Mandatory)][string]$ControlDir,
        [Parameter(Mandatory)][string]$ClaudeModelName,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$TaskId,
        [switch]$Continue,
        [switch]$NoWait,
        [int]$MaxTasks = 0,
        [switch]$ShowDebug,
        [switch]$ShowVerbose
    )

    $processData = $ProcessData

    # Load prompt template
    $templateFile = Join-Path $BotRoot "prompts\workflows\98-analyse-task.md"
    $promptTemplate = Get-Content $templateFile -Raw

    $processData.workflow = "98-analyse-task.md"

    # Task reset for analysis
    . "$PSScriptRoot\..\..\modules\task-reset.ps1"
    $tasksBaseDir = Join-Path $BotRoot "workspace\tasks"

    # Recover orphaned analysing tasks
    Reset-AnalysingTasks -TasksBaseDir $tasksBaseDir -ProcessesDir $ProcessesDir | Out-Null

    # Clean up orphan worktrees from previous runs
    Remove-OrphanWorktrees -ProjectRoot $ProjectRoot -BotRoot $BotRoot

    # Initialize task index for analysis
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

    $tasksProcessed = 0
    $maxRetriesPerTask = 2

    # Update process status to running
    $processData.status = 'running'
    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

    try {
        while ($true) {
            # Check max tasks
            if ($MaxTasks -gt 0 -and $tasksProcessed -ge $MaxTasks) {
                Write-Status "Reached maximum task limit ($MaxTasks)" -Type Warn
                break
            }

            # Check stop signal
            if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) {
                Write-Status "Stop signal received" -Type Error
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Process stopped by user" -ProcessesDir $ProcessesDir
                break
            }

            # Get next task
            Write-Status "Fetching next task..." -Type Process
            Reset-TaskIndex

            # Wait for any active execution worktrees to merge first
            $waitingLogged = $false
            while ($true) {
                Initialize-WorktreeMap -BotRoot $BotRoot
                $map = Read-WorktreeMap
                $hasActiveExecutionWt = $false

                if ($map.Count -gt 0) {
                    $index = Get-TaskIndex
                    foreach ($taskIdKey in @($map.Keys)) {
                        if ($index.InProgress.ContainsKey($taskIdKey) -or
                            $index.Done.ContainsKey($taskIdKey)) {
                            $entry = $map[$taskIdKey]
                            if ($entry.worktree_path -and (Test-Path $entry.worktree_path)) {
                                $hasActiveExecutionWt = $true
                                break
                            }
                        }
                    }
                }

                if (-not $hasActiveExecutionWt) { break }

                if (-not $waitingLogged) {
                    Write-Status "Waiting for execution merge before next analysis..." -Type Info
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" `
                        -Message "Waiting for execution to merge before starting next analysis" -ProcessesDir $ProcessesDir
                    $processData.heartbeat_status = "Waiting for execution merge"
                    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                    $waitingLogged = $true
                }

                Start-Sleep -Seconds 5
                if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) { break }
            }

            # For analysis: check resumed tasks (answered questions) first, then todo
            $taskResult = Get-NextTodoTask -Verbose

            # Immediately claim task to prevent execution from picking it up
            if ($taskResult.task) {
                Invoke-TaskMarkAnalysing -Arguments @{ task_id = $taskResult.task.id } | Out-Null
            }

            # Use specific task if provided
            if ($TaskId -and $tasksProcessed -eq 0) {
                # First iteration with specific TaskId - fetch that specific task
            }

            if (-not $taskResult.success) {
                Write-Status "Error fetching task: $($taskResult.message)" -Type Error
                break
            }

            if (-not $taskResult.task) {
                if ($Continue -and -not $NoWait) {
                    $waitReason = if ($taskResult.message) { $taskResult.message } else { "No eligible tasks." }
                    Write-Status "No tasks available - waiting... ($waitReason)" -Type Info
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Waiting for new tasks..." -ProcessesDir $ProcessesDir

                    # Wait loop for new tasks
                    $foundTask = $false
                    while ($true) {
                        Start-Sleep -Seconds 5
                        if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) { break }
                        $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                        Reset-TaskIndex
                        $taskResult = Get-NextTodoTask -Verbose
                        if ($taskResult.task) { $foundTask = $true; break }

                        if (Test-DependencyDeadlock -ProcessId $ProcId -ProcessesDir $ProcessesDir) { break }
                    }
                    if (-not $foundTask) { break }
                } else {
                    Write-Status "No tasks available" -Type Info
                    break
                }
            }

            $task = $taskResult.task
            $processData.task_id = $task.id
            $processData.task_name = $task.name
            $processData.heartbeat_status = "Working on: $($task.name)"
            Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

            $env:DOTBOT_CURRENT_TASK_ID = $task.id
            Write-Status "Task: $($task.name)" -Type Success
            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Started task: $($task.name)" -ProcessesDir $ProcessesDir

            # Generate new provider session ID per task
            $claudeSessionId = New-ProviderSession
            $env:CLAUDE_SESSION_ID = $claudeSessionId
            $processData.claude_session_id = $claudeSessionId
            Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

            # Build analysis prompt
            $prompt = $promptTemplate
            $prompt = $prompt -replace '\{\{SESSION_ID\}\}', $SessionId
            $prompt = $prompt -replace '\{\{TASK_ID\}\}', $task.id
            $prompt = $prompt -replace '\{\{TASK_NAME\}\}', $task.name
            $prompt = $prompt -replace '\{\{TASK_CATEGORY\}\}', $task.category
            $prompt = $prompt -replace '\{\{TASK_PRIORITY\}\}', $task.priority
            $prompt = $prompt -replace '\{\{TASK_EFFORT\}\}', $task.effort
            $prompt = $prompt -replace '\{\{TASK_DESCRIPTION\}\}', $task.description
            $niValue = if ("$($task.needs_interview)" -eq 'true') { 'true' } else { 'false' }
            Write-Status "needs_interview raw=$($task.needs_interview) resolved=$niValue" -Type Info
            $prompt = $prompt -replace '\{\{NEEDS_INTERVIEW\}\}', $niValue
            $acceptanceCriteria = if ($task.acceptance_criteria) { ($task.acceptance_criteria | ForEach-Object { "- $_" }) -join "`n" } else { "No specific acceptance criteria defined." }
            $prompt = $prompt -replace '\{\{ACCEPTANCE_CRITERIA\}\}', $acceptanceCriteria
            $steps = if ($task.steps) { ($task.steps | ForEach-Object { "- $_" }) -join "`n" } else { "No specific steps defined." }
            $prompt = $prompt -replace '\{\{TASK_STEPS\}\}', $steps
            $splitThreshold = if ($Settings.analysis.split_threshold_effort) { $Settings.analysis.split_threshold_effort } else { 'XL' }
            $prompt = $prompt -replace '\{\{SPLIT_THRESHOLD_EFFORT\}\}', $splitThreshold

            $branchForPrompt = "main"
            $prompt = $prompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

            # Build resolved questions context for resumed tasks
            $isResumedTask = $task.status -eq 'analysing'
            $resolvedQuestionsContext = ""
            if ($isResumedTask -and $task.questions_resolved) {
                $resolvedQuestionsContext = "`n## Previously Resolved Questions`n`n"
                $resolvedQuestionsContext += "This task was previously paused for human input. The following questions have been answered:`n`n"
                foreach ($q in $task.questions_resolved) {
                    $resolvedQuestionsContext += "**Q:** $($q.question)`n"
                    $resolvedQuestionsContext += "**A:** $($q.answer)`n`n"
                }
                $resolvedQuestionsContext += "Use these answers to guide your analysis. The task is already in ``analysing`` status - do NOT call ``task_mark_analysing`` again.`n"
            }

            $fullPrompt = @"
$prompt
$resolvedQuestionsContext
## Process Context

- **Process ID:** $ProcId
- **Instance Type:** analysis

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Analyse task $($task.id) completely. When analysis is finished:
- If all context is gathered: Call task_mark_analysed with the full analysis object
- If you need human input: Call task_mark_needs_input with a question or split_proposal
- If blocked by issues: Call task_mark_skipped with a reason

Do NOT implement the task. Your job is research and preparation only.
"@

            # Invoke Claude with retries
            $attemptNumber = 0
            $taskSuccess = $false

            while ($attemptNumber -le $maxRetriesPerTask) {
                $attemptNumber++

                if ($attemptNumber -gt 1) {
                    Write-Status "Retry attempt $attemptNumber of $maxRetriesPerTask" -Type Warn
                }

                # Check stop signal before each attempt
                if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) {
                    $processData.status = 'stopped'
                    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                    break
                }

                Write-Header "Claude Session"
                try {
                    $streamArgs = @{
                        Prompt = $fullPrompt
                        Model = $ClaudeModelName
                        SessionId = $claudeSessionId
                        PersistSession = $false
                    }
                    if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                    if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                    Invoke-ProviderStream @streamArgs
                    $exitCode = 0
                } catch {
                    Write-Status "Error: $($_.Exception.Message)" -Type Error
                    $exitCode = 1
                }

                # Update heartbeat
                $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

                # Check rate limit
                $rateLimitMsg = Get-LastProviderRateLimitInfo
                if ($rateLimitMsg) {
                    Write-Status "Rate limit detected!" -Type Warn
                    $rateLimitInfo = Get-RateLimitResetTime -Message $rateLimitMsg
                    if ($rateLimitInfo) {
                        $processData.heartbeat_status = "Rate limited - waiting..."
                        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                        Write-ProcessActivity -Id $ProcId -ActivityType "rate_limit" -Message $rateLimitMsg -ProcessesDir $ProcessesDir

                        $waitSeconds = $rateLimitInfo.wait_seconds
                        if (-not $waitSeconds -or $waitSeconds -lt 30) { $waitSeconds = 60 }
                        for ($w = 0; $w -lt $waitSeconds; $w++) {
                            Start-Sleep -Seconds 1
                            if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) { break }
                        }

                        $attemptNumber--
                        continue
                    }
                }

                # Check if task moved to analysed/needs-input/skipped
                $taskDirs = @('analysed', 'needs-input', 'skipped', 'in-progress', 'done')
                $taskFound = $false
                foreach ($dir in $taskDirs) {
                    $checkDir = Join-Path $BotRoot "workspace\tasks\$dir"
                    if (Test-Path $checkDir) {
                        $files = Get-ChildItem -Path $checkDir -Filter "*.json" -File
                        foreach ($f in $files) {
                            try {
                                $content = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
                                if ($content.id -eq $task.id) {
                                    $taskFound = $true
                                    $taskSuccess = $true
                                    Write-Status "Analysis complete (status: $dir)" -Type Complete
                                    break
                                }
                            } catch {}
                        }
                        if ($taskFound) { break }
                    }
                }
                if ($taskSuccess) { break }

                if ($attemptNumber -ge $maxRetriesPerTask) {
                    Write-Status "Max retries exhausted" -Type Error
                    break
                }
            }

            # Update process data
            $env:DOTBOT_CURRENT_TASK_ID = $null
            $env:CLAUDE_SESSION_ID = $null

            if ($taskSuccess) {
                $tasksProcessed++
                $processData.tasks_completed = $tasksProcessed
                $processData.heartbeat_status = "Completed: $($task.name)"
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task completed: $($task.name)" -ProcessesDir $ProcessesDir

                # Clean up Claude session
                try { Remove-ProviderSession -SessionId $claudeSessionId -ProjectRoot $ProjectRoot | Out-Null } catch {}
            } else {
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task failed: $($task.name)" -ProcessesDir $ProcessesDir
            }

            # Continue to next task?
            if (-not $Continue) { break }

            # Clear task ID for next iteration
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null

            # Delay between tasks
            Write-Status "Waiting 3s before next task..." -Type Info
            for ($i = 0; $i -lt 3; $i++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) { break }
            }

            if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) {
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                break
            }
        }
    } finally {
        # Final cleanup
        if ($processData.status -eq 'running') {
            $processData.status = 'completed'
            $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Process $ProcId finished ($($processData.status))" -ProcessesDir $ProcessesDir
    }
}
