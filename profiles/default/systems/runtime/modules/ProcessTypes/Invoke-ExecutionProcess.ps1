#Requires -Version 7.0

function Invoke-ExecutionProcess {
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

    # Initialize session
    $sessionResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
    if ($sessionResult.success) {
        $SessionId = $sessionResult.session.session_id
    }

    # Load prompt template
    $templateFile = Join-Path $BotRoot "prompts\workflows\99-autonomous-task.md"
    $promptTemplate = Get-Content $templateFile -Raw

    $processData.workflow = "99-autonomous-task.md"

    # Standards and product context
    $standardsList = ""
    $productMission = ""
    $entityModel = ""
    $standardsDir = Join-Path $BotRoot "prompts\standards\global"
    if (Test-Path $standardsDir) {
        $standardsFiles = Get-ChildItem -Path $standardsDir -Filter "*.md" -File |
            ForEach-Object { ".bot/prompts/standards/global/$($_.Name)" }
        $standardsList = if ($standardsFiles) { "- " + ($standardsFiles -join "`n- ") } else { "No standards files found." }
    }
    $productDir = Join-Path $BotRoot "workspace\product"
    $productMission = if (Test-Path (Join-Path $productDir "mission.md")) { "Read the product mission and context from: .bot/workspace/product/mission.md" } else { "No product mission file found." }
    $entityModel = if (Test-Path (Join-Path $productDir "entity-model.md")) { "Read the entity model design from: .bot/workspace/product/entity-model.md" } else { "No entity model file found." }

    # Task reset
    . "$PSScriptRoot\..\..\modules\task-reset.ps1"
    $tasksBaseDir = Join-Path $BotRoot "workspace\tasks"

    Reset-AnalysingTasks -TasksBaseDir $tasksBaseDir -ProcessesDir $ProcessesDir | Out-Null
    Reset-InProgressTasks -TasksBaseDir $tasksBaseDir | Out-Null
    Reset-SkippedTasks -TasksBaseDir $tasksBaseDir | Out-Null

    # Clean up orphan worktrees
    Remove-OrphanWorktrees -ProjectRoot $ProjectRoot -BotRoot $BotRoot

    $tasksProcessed = 0
    $maxRetriesPerTask = 2
    $consecutiveFailureThreshold = 3

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
            $taskResult = Invoke-TaskGetNext -Arguments @{ verbose = $true }

            # Use specific task if provided
            if ($TaskId -and $tasksProcessed -eq 0) {
                # First iteration with specific TaskId
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

                    $foundTask = $false
                    while ($true) {
                        Start-Sleep -Seconds 5
                        if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) { break }
                        $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                        $taskResult = Invoke-TaskGetNext -Arguments @{ verbose = $true }
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

            # Mark execution task immediately
            Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
            Invoke-SessionUpdate -Arguments @{ current_task_id = $task.id } | Out-Null

            # --- Worktree setup ---
            $worktreePath = $null
            $branchName = $null
            $wtInfo = Get-TaskWorktreeInfo -TaskId $task.id -BotRoot $BotRoot
            if ($wtInfo -and (Test-Path $wtInfo.worktree_path)) {
                $worktreePath = $wtInfo.worktree_path
                $branchName = $wtInfo.branch_name
                Write-Status "Using worktree: $worktreePath" -Type Info
            } else {
                try { Assert-OnBaseBranch -ProjectRoot $ProjectRoot | Out-Null } catch {
                    Write-Status "Branch guard warning: $($_.Exception.Message)" -Type Warn
                }
                $wtResult = New-TaskWorktree -TaskId $task.id -TaskName $task.name `
                    -ProjectRoot $ProjectRoot -BotRoot $BotRoot
                if ($wtResult.success) {
                    $worktreePath = $wtResult.worktree_path
                    $branchName = $wtResult.branch_name
                    Write-Status "Worktree: $worktreePath" -Type Info
                } else {
                    Write-Status "Worktree failed: $($wtResult.message)" -Type Warn
                }
            }

            # Generate new provider session ID per task
            $claudeSessionId = New-ProviderSession
            $env:CLAUDE_SESSION_ID = $claudeSessionId
            $processData.claude_session_id = $claudeSessionId
            Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

            # Build prompt
            $prompt = Build-TaskPrompt `
                -PromptTemplate $promptTemplate `
                -Task $task `
                -SessionId $SessionId `
                -ProductMission $productMission `
                -EntityModel $entityModel `
                -StandardsList $standardsList `
                -InstanceId $InstanceId

            $branchForPrompt = if ($branchName) { $branchName } else { "main" }
            $prompt = $prompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

            $fullPrompt = @"
$prompt

## Process Context

- **Process ID:** $ProcId
- **Instance Type:** execution

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Task $($task.id) is complete: all acceptance criteria met, verification passed, and task marked done.

Work on this task autonomously. When complete, ensure you call task_mark_done via MCP.
"@

            # Invoke Claude with retries
            $attemptNumber = 0
            $taskSuccess = $false

            if ($worktreePath) { Push-Location $worktreePath }
            try {
            while ($attemptNumber -le $maxRetriesPerTask) {
                $attemptNumber++

                if ($attemptNumber -gt 1) {
                    Write-Status "Retry attempt $attemptNumber of $maxRetriesPerTask" -Type Warn
                }

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

                # Kill any background processes Claude may have spawned in the worktree
                if ($worktreePath) {
                    $cleanedUp = Stop-WorktreeProcesses -WorktreePath $worktreePath
                    if ($cleanedUp -gt 0) {
                        Write-Diag -Msg "Cleaned up $cleanedUp orphan process(es) after execution attempt"
                        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Cleaned up $cleanedUp background process(es) from worktree" -ProcessesDir $ProcessesDir
                    }
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

                # Check completion
                $completionCheck = Test-TaskCompletion -TaskId $task.id
                if ($completionCheck.completed) {
                    Write-Status "Task completed!" -Type Complete
                    Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                    $taskSuccess = $true
                    break
                }

                # Task not completed - handle failure
                $failureReason = Get-FailureReason -ExitCode $exitCode -Stdout "" -Stderr "" -TimedOut $false
                if (-not $failureReason.recoverable) {
                    Write-Status "Non-recoverable failure - skipping" -Type Error
                    try {
                        Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "non-recoverable" } | Out-Null
                    } catch {}
                    break
                }

                if ($attemptNumber -ge $maxRetriesPerTask) {
                    Write-Status "Max retries exhausted" -Type Error
                    try {
                        Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "max-retries" } | Out-Null
                    } catch {}
                    break
                }
            }
            } finally {
                if ($worktreePath) {
                    Stop-WorktreeProcesses -WorktreePath $worktreePath | Out-Null
                    Pop-Location
                }
            }

            # Update process data
            $env:DOTBOT_CURRENT_TASK_ID = $null
            $env:CLAUDE_SESSION_ID = $null

            if ($taskSuccess) {
                # Post-completion: squash-merge task branch to main
                if ($worktreePath) {
                    Write-Status "Merging task branch to main..." -Type Process
                    $mergeResult = Complete-TaskWorktree -TaskId $task.id -ProjectRoot $ProjectRoot -BotRoot $BotRoot
                    if ($mergeResult.success) {
                        Write-Status "Merged: $($mergeResult.message)" -Type Complete
                        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Squash-merged to main: $($task.name)" -ProcessesDir $ProcessesDir
                        if ($mergeResult.push_result.attempted) {
                            if ($mergeResult.push_result.success) {
                                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Pushed to remote: $($task.name)" -ProcessesDir $ProcessesDir
                            } else {
                                Write-Status "Push failed: $($mergeResult.push_result.error)" -Type Warn
                                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Push failed after merge: $($mergeResult.push_result.error)" -ProcessesDir $ProcessesDir
                            }
                        }
                    } else {
                        Write-Status "Merge failed: $($mergeResult.message)" -Type Error
                        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Merge failed for $($task.name): $($mergeResult.message)" -ProcessesDir $ProcessesDir

                        # Escalate: move task from done/ to needs-input/ with conflict info
                        $doneDir = Join-Path $tasksBaseDir "done"
                        $needsInputDir = Join-Path $tasksBaseDir "needs-input"
                        $taskFile = Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Where-Object {
                            try {
                                $c = Get-Content $_.FullName -Raw | ConvertFrom-Json
                                $c.id -eq $task.id
                            } catch { $false }
                        } | Select-Object -First 1

                        if ($taskFile) {
                            $taskContent = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                            $taskContent.status = 'needs-input'
                            $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("o")

                            if (-not $taskContent.PSObject.Properties['pending_question']) {
                                $taskContent | Add-Member -NotePropertyName 'pending_question' -NotePropertyValue $null -Force
                            }
                            $taskContent.pending_question = @{
                                id             = "merge-conflict"
                                question       = "Merge conflict during squash-merge to main"
                                context        = "Conflict details: $($mergeResult.conflict_files -join '; '). Worktree preserved at: $worktreePath"
                                options        = @(
                                    @{ key = "A"; label = "Resolve manually and retry (recommended)"; rationale = "Inspect the worktree, resolve conflicts, then retry merge" }
                                    @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
                                    @{ key = "C"; label = "Retry with fresh rebase"; rationale = "Reset and attempt rebase again" }
                                )
                                recommendation = "A"
                                asked_at       = (Get-Date).ToUniversalTime().ToString("o")
                            }

                            if (-not (Test-Path $needsInputDir)) {
                                New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
                            }
                            $newPath = Join-Path $needsInputDir $taskFile.Name
                            $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newPath -Encoding UTF8
                            Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue

                            Write-Status "Task moved to needs-input for manual conflict resolution" -Type Warn
                        }
                    }
                }

                $tasksProcessed++
                $processData.tasks_completed = $tasksProcessed
                $processData.heartbeat_status = "Completed: $($task.name)"
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task completed: $($task.name)" -ProcessesDir $ProcessesDir

                # Clean up Claude session
                try { Remove-ProviderSession -SessionId $claudeSessionId -ProjectRoot $ProjectRoot | Out-Null } catch {}
            } else {
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task failed: $($task.name)" -ProcessesDir $ProcessesDir

                # Clean up worktree for failed/skipped tasks
                if ($worktreePath) {
                    Write-Status "Cleaning up worktree for failed task..." -Type Info
                    try {
                        Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false | Out-Null
                        git -C $ProjectRoot worktree remove $worktreePath --force 2>$null
                        git -C $ProjectRoot branch -D $branchName 2>$null
                    } finally {
                        Initialize-WorktreeMap -BotRoot $BotRoot
                        Invoke-WorktreeMapLocked -Action {
                            $cleanupMap = Read-WorktreeMap
                            $cleanupMap.Remove($task.id)
                            Write-WorktreeMap -Map $cleanupMap
                        }
                        try { Assert-OnBaseBranch -ProjectRoot $ProjectRoot | Out-Null } catch {}
                    }
                }

                # Update session failure counters
                try {
                    $state = Invoke-SessionGetState -Arguments @{}
                    $newFailures = $state.state.consecutive_failures + 1
                    Invoke-SessionUpdate -Arguments @{
                        consecutive_failures = $newFailures
                        tasks_skipped = $state.state.tasks_skipped + 1
                    } | Out-Null

                    if ($newFailures -ge $consecutiveFailureThreshold) {
                        Write-Status "$consecutiveFailureThreshold consecutive failures - stopping" -Type Error
                        break
                    }
                } catch {}
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

        try { Invoke-SessionUpdate -Arguments @{ status = "stopped" } | Out-Null } catch {}
    }
}
