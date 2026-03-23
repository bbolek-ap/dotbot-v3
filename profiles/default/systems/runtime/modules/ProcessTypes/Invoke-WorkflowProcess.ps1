#Requires -Version 7.0

function Invoke-WorkflowProcess {
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

    # Initialize session for execution phase tracking
    $sessionResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
    if ($sessionResult.success) {
        $SessionId = $sessionResult.session.session_id
    }
    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Workflow child started (session: $SessionId, PID: $PID)" -ProcessesDir $ProcessesDir

    # Load both prompt templates
    $analysisTemplateFile = Join-Path $BotRoot "prompts\workflows\98-analyse-task.md"
    $executionTemplateFile = Join-Path $BotRoot "prompts\workflows\99-autonomous-task.md"
    $analysisPromptTemplate = Get-Content $analysisTemplateFile -Raw
    $executionPromptTemplate = Get-Content $executionTemplateFile -Raw

    $processData.workflow = "workflow (analyse + execute)"

    # Standards and product context (for execution phase)
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

    # Recover orphaned tasks
    Reset-AnalysingTasks -TasksBaseDir $tasksBaseDir -ProcessesDir $ProcessesDir | Out-Null
    Reset-InProgressTasks -TasksBaseDir $tasksBaseDir | Out-Null
    Reset-SkippedTasks -TasksBaseDir $tasksBaseDir | Out-Null

    # Clean up orphan worktrees
    Remove-OrphanWorktrees -ProjectRoot $ProjectRoot -BotRoot $BotRoot

    # Initialize task index
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

    # Log task index state for diagnostics
    $initIndex = Get-TaskIndex
    $todoCount = if ($initIndex.Todo) { $initIndex.Todo.Count } else { 0 }
    $analysedCount = if ($initIndex.Analysed) { $initIndex.Analysed.Count } else { 0 }
    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task index loaded: $todoCount todo, $analysedCount analysed" -ProcessesDir $ProcessesDir

    # Pre-flight: warn if main repo has uncommitted non-.bot/ files.
    try {
        $mainDirtyStatus = git -C $ProjectRoot status --porcelain 2>$null
        $mainDirtyFiles  = @($mainDirtyStatus | Where-Object { $_ -notmatch '\.bot/' -and $_ -notmatch '^\?\?' })
        if ($mainDirtyFiles.Count -gt 0) {
            $fileList = ($mainDirtyFiles | ForEach-Object { $_.Substring(3).Trim() }) -join ', '
            Write-Status "Pre-flight: Main repo has $($mainDirtyFiles.Count) uncommitted non-.bot/ file(s). Commit them to avoid squash-merge complications: $fileList" -Type Warn
            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Pre-flight warning: Main repo has $($mainDirtyFiles.Count) uncommitted file(s) outside .bot/ ($fileList). Consider committing before workflow." -ProcessesDir $ProcessesDir
        }
    } catch {}

    $tasksProcessed = 0
    $maxRetriesPerTask = 2
    $consecutiveFailureThreshold = 3

    # Ensure repo has at least one commit (required for worktrees)
    $hasCommits = git -C $ProjectRoot rev-parse --verify HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Creating initial commit (required for worktrees)..." -Type Process
        git -C $ProjectRoot add .bot/ 2>$null
        git -C $ProjectRoot commit -m "chore: initialize dotbot" --allow-empty 2>$null
        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Created initial git commit (repo had no commits)" -ProcessesDir $ProcessesDir
    }

    # Update process status to running
    $processData.status = 'running'
    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

    $loopIteration = 0
    try {
        while ($true) {
            $loopIteration++
            Write-Diag -Msg "--- Loop iteration $loopIteration ---"

            # Check max tasks
            Write-Diag -Msg "MaxTasks check: tasksProcessed=$tasksProcessed, MaxTasks=$MaxTasks"
            if ($MaxTasks -gt 0 -and $tasksProcessed -ge $MaxTasks) {
                Write-Status "Reached maximum task limit ($MaxTasks)" -Type Warn
                Write-Diag -Msg "EXIT: MaxTasks reached"
                break
            }

            # Check stop signal
            if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) {
                Write-Status "Stop signal received" -Type Error
                Write-Diag -Msg "EXIT: Stop signal received"
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Process stopped by user" -ProcessesDir $ProcessesDir
                break
            }

            # ===== Pick next task =====
            Write-Status "Fetching next task..." -Type Process
            Reset-TaskIndex

            $taskResult = Get-NextWorkflowTask -VerboseOutput

            Write-Diag -Msg "TaskPickup: success=$($taskResult.success) hasTask=$($null -ne $taskResult.task) msg=$($taskResult.message)"

            if (-not $taskResult.success) {
                Write-Status "Error fetching task: $($taskResult.message)" -Type Error
                Write-Diag -Msg "EXIT: Error fetching task: $($taskResult.message)"
                break
            }

            if (-not $taskResult.task) {
                if ($Continue -and -not $NoWait) {
                    $waitReason = if ($taskResult.message) { $taskResult.message } else { "No eligible tasks." }
                    Write-Status "No tasks available - waiting... ($waitReason)" -Type Info
                    Write-Diag -Msg "Entering wait loop (Continue=$Continue, NoWait=$NoWait): $waitReason"
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Waiting for new tasks..." -ProcessesDir $ProcessesDir

                    $foundTask = $false
                    while ($true) {
                        Start-Sleep -Seconds 5
                        if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) { break }
                        $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                        Reset-TaskIndex
                        $taskResult = Get-NextWorkflowTask -VerboseOutput
                        if ($taskResult.task) { $foundTask = $true; break }

                        if (Test-DependencyDeadlock -ProcessId $ProcId -ProcessesDir $ProcessesDir) { break }
                    }
                    if (-not $foundTask) {
                        Write-Diag -Msg "EXIT: No task found after wait loop (foundTask=$foundTask)"
                        break
                    }
                } else {
                    Write-Status "No tasks available" -Type Info
                    Write-Diag -Msg "EXIT: No tasks and Continue not set"
                    break
                }
            }

            $task = $taskResult.task
            $processData.task_id = $task.id
            $processData.task_name = $task.name
            $env:DOTBOT_CURRENT_TASK_ID = $task.id
            Write-Status "Task: $($task.name) (status: $($task.status))" -Type Success
            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Processing task: $($task.name) (id: $($task.id), status: $($task.status))" -ProcessesDir $ProcessesDir
            Write-Diag -Msg "Selected task: id=$($task.id) name=$($task.name) status=$($task.status)"

            # Skip analysis for already-analysed tasks
            if ($task.status -eq 'analysed') {
                Write-Status "Task already analysed — skipping to execution phase" -Type Info
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task already analysed, proceeding to execution: $($task.name)" -ProcessesDir $ProcessesDir
            }

            try {   # Per-task try/catch

            # ===== PHASE 1: Analysis (skipped if task already analysed) =====
            if ($task.status -ne 'analysed') {
            Write-Diag -Msg "Entering analysis phase for task $($task.id)"
            $env:DOTBOT_CURRENT_PHASE = 'analysis'
            $processData.heartbeat_status = "Analysing: $($task.name)"
            Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Analysis phase started: $($task.name)" -ProcessesDir $ProcessesDir

            if ($task.status -ne 'analysing') {
                Invoke-TaskMarkAnalysing -Arguments @{ task_id = $task.id } | Out-Null
            }

            # Build analysis prompt
            $analysisPrompt = $analysisPromptTemplate
            $analysisPrompt = $analysisPrompt -replace '\{\{SESSION_ID\}\}', $SessionId
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_ID\}\}', $task.id
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_NAME\}\}', $task.name
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_CATEGORY\}\}', $task.category
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_PRIORITY\}\}', $task.priority
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_EFFORT\}\}', $task.effort
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_DESCRIPTION\}\}', $task.description
            $niValue = if ("$($task.needs_interview)" -eq 'true') { 'true' } else { 'false' }
            $analysisPrompt = $analysisPrompt -replace '\{\{NEEDS_INTERVIEW\}\}', $niValue
            $acceptanceCriteria = if ($task.acceptance_criteria) { ($task.acceptance_criteria | ForEach-Object { "- $_" }) -join "`n" } else { "No specific acceptance criteria defined." }
            $analysisPrompt = $analysisPrompt -replace '\{\{ACCEPTANCE_CRITERIA\}\}', $acceptanceCriteria
            $steps = if ($task.steps) { ($task.steps | ForEach-Object { "- $_" }) -join "`n" } else { "No specific steps defined." }
            $analysisPrompt = $analysisPrompt -replace '\{\{TASK_STEPS\}\}', $steps
            $splitThreshold = if ($Settings.analysis.split_threshold_effort) { $Settings.analysis.split_threshold_effort } else { 'XL' }
            $analysisPrompt = $analysisPrompt -replace '\{\{SPLIT_THRESHOLD_EFFORT\}\}', $splitThreshold
            $analysisPrompt = $analysisPrompt -replace '\{\{BRANCH_NAME\}\}', 'main'

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

            # Use analysis model from settings
            $analysisModel = if ($Settings.analysis?.model) { $Settings.analysis.model } else { 'Opus' }
            $analysisModelName = Resolve-ProviderModelId -ModelAlias $analysisModel

            $fullAnalysisPrompt = @"
$analysisPrompt
$resolvedQuestionsContext
## Process Context

- **Process ID:** $ProcId
- **Instance Type:** workflow (analysis phase)

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Analyse task $($task.id) completely. When analysis is finished:
- If all context is gathered: Call task_mark_analysed with the full analysis object
- If you need human input: Call task_mark_needs_input with a question or split_proposal
- If blocked by issues: Call task_mark_skipped with a reason

Do NOT implement the task. Your job is research and preparation only.
"@

            # Invoke provider for analysis
            $analysisSessionId = New-ProviderSession
            $env:CLAUDE_SESSION_ID = $analysisSessionId
            $processData.claude_session_id = $analysisSessionId
            Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

            $analysisSuccess = $false
            $analysisAttempt = 0
            $analysisOutcome = $null

            while ($analysisAttempt -le $maxRetriesPerTask) {
                $analysisAttempt++
                if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) { break }

                Write-Header "Analysis Phase"
                try {
                    $streamArgs = @{
                        Prompt = $fullAnalysisPrompt
                        Model = $analysisModelName
                        SessionId = $analysisSessionId
                        PersistSession = $false
                    }
                    if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                    if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                    Invoke-ProviderStream @streamArgs
                    $exitCode = 0
                } catch {
                    Write-Status "Analysis error: $($_.Exception.Message)" -Type Error
                    $exitCode = 1
                }

                # Update heartbeat
                $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

                # Handle rate limit
                $rateLimitMsg = Get-LastProviderRateLimitInfo
                if ($rateLimitMsg) {
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
                        $analysisAttempt--
                        continue
                    }
                }

                # Check if analysis completed
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
                                    $analysisSuccess = $true
                                    $analysisOutcome = $dir
                                    Write-Status "Analysis complete (status: $dir)" -Type Complete
                                    break
                                }
                            } catch {}
                        }
                        if ($taskFound) { break }
                    }
                }
                if ($analysisSuccess) { break }

                if ($analysisAttempt -ge $maxRetriesPerTask) {
                    Write-Status "Analysis max retries exhausted" -Type Error
                    break
                }
            }

            # Clean up analysis session
            try { Remove-ProviderSession -SessionId $analysisSessionId -ProjectRoot $ProjectRoot | Out-Null } catch {}

            Write-Diag -Msg "Analysis outcome: success=$analysisSuccess outcome=$analysisOutcome"

            if (-not $analysisSuccess) {
                Write-Diag -Msg "Analysis FAILED for task $($task.id)"
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Analysis failed: $($task.name)" -ProcessesDir $ProcessesDir
                if (-not $Continue) { break }
                $TaskId = $null
                $processData.task_id = $null
                $processData.task_name = $null
                for ($i = 0; $i -lt 3; $i++) {
                    Start-Sleep -Seconds 1
                    if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) { break }
                }
                continue
            }

            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Analysis complete: $($task.name) -> $analysisOutcome" -ProcessesDir $ProcessesDir

            if ($analysisOutcome -ne 'analysed') {
                Write-Diag -Msg "Task not ready for execution: outcome=$analysisOutcome"
                Write-Status "Task not ready for execution (status: $analysisOutcome) - moving to next task" -Type Info
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task $($task.name) needs input or was skipped - moving on" -ProcessesDir $ProcessesDir
                if (-not $Continue) { break }
                $TaskId = $null
                $processData.task_id = $null
                $processData.task_name = $null
                for ($i = 0; $i -lt 3; $i++) {
                    Start-Sleep -Seconds 1
                    if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) { break }
                }
                continue
            }
            } # end: if ($task.status -ne 'analysed') — analysis phase

            # ===== PHASE 2: Execution =====
            Write-Diag -Msg "Entering execution phase for task $($task.id)"
            $env:DOTBOT_CURRENT_PHASE = 'execution'
            $processData.heartbeat_status = "Executing: $($task.name)"
            Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Execution phase started: $($task.name)" -ProcessesDir $ProcessesDir

            try {

            # Re-read task data (analysis may have enriched it)
            Reset-TaskIndex
            $freshTask = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $true; verbose = $true }
            Write-Diag -Msg "Execution TaskGetNext: hasTask=$($null -ne $freshTask.task) matchesId=$($freshTask.task.id -eq $task.id)"
            if ($freshTask.task -and $freshTask.task.id -eq $task.id) {
                $task = $freshTask.task
            }

            # Mark in-progress
            Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
            Invoke-SessionUpdate -Arguments @{ current_task_id = $task.id } | Out-Null

            # Worktree setup — skip for research tasks and tasks with external repos
            $skipWorktree = ($task.category -eq 'research') -or $task.working_dir -or $task.external_repo
            Write-Diag -Msg "Worktree: skip=$skipWorktree category=$($task.category)"
            $worktreePath = $null
            $branchName = $null

            if ($skipWorktree) {
                Write-Status "Skipping worktree (category: $($task.category))" -Type Info
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Skipping worktree for task: $($task.name) (research/external repo task)" -ProcessesDir $ProcessesDir
            } else {
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
            }

            # Use execution model from settings
            $executionModel = if ($Settings.execution?.model) { $Settings.execution.model } else { 'Opus' }
            $executionModelName = Resolve-ProviderModelId -ModelAlias $executionModel

            # Build execution prompt
            $executionPrompt = Build-TaskPrompt `
                -PromptTemplate $executionPromptTemplate `
                -Task $task `
                -SessionId $SessionId `
                -ProductMission $productMission `
                -EntityModel $entityModel `
                -StandardsList $standardsList `
                -InstanceId $InstanceId

            $branchForPrompt = if ($branchName) { $branchName } else { "main" }
            $executionPrompt = $executionPrompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

            $fullExecutionPrompt = @"
$executionPrompt

## Process Context

- **Process ID:** $ProcId
- **Instance Type:** workflow (execution phase)

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Task $($task.id) is complete: all acceptance criteria met, verification passed, and task marked done.

Work on this task autonomously. When complete, ensure you call task_mark_done via MCP.
"@

            # Invoke provider for execution
            $executionSessionId = New-ProviderSession
            $env:CLAUDE_SESSION_ID = $executionSessionId
            $processData.claude_session_id = $executionSessionId
            Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

            $taskSuccess = $false
            $attemptNumber = 0

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

                Write-Header "Execution Phase"
                try {
                    $streamArgs = @{
                        Prompt = $fullExecutionPrompt
                        Model = $executionModelName
                        SessionId = $executionSessionId
                        PersistSession = $false
                    }
                    if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                    if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                    Invoke-ProviderStream @streamArgs
                    $exitCode = 0
                } catch {
                    Write-Status "Execution error: $($_.Exception.Message)" -Type Error
                    $exitCode = 1
                }

                # Kill any background processes
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

                # Handle rate limit
                $rateLimitMsg = Get-LastProviderRateLimitInfo
                if ($rateLimitMsg) {
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
                Write-Diag -Msg "Completion check: completed=$($completionCheck.completed)"
                if ($completionCheck.completed) {
                    Write-Status "Task completed!" -Type Complete
                    Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                    $taskSuccess = $true
                    break
                }

                # Diagnostic: why not completed?
                $inProgressDir = Join-Path $tasksBaseDir "in-progress"
                $stillInProgress = $false
                try {
                    $stillInProgress = $null -ne (
                        Get-ChildItem -Path $inProgressDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                        Where-Object {
                            try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $task.id } catch { $false }
                        } | Select-Object -First 1
                    )
                } catch {}

                if ($stillInProgress) {
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Completion check failed (attempt $attemptNumber): '$($task.name)' still in in-progress/. Check activity log: if a 'task_mark_done blocked' entry exists, verification failed; otherwise task_mark_done was likely never called." -ProcessesDir $ProcessesDir
                } else {
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Completion check failed (attempt $attemptNumber): '$($task.name)' not found in in-progress/ or done/ (unexpected state)." -ProcessesDir $ProcessesDir
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

            # Clean up execution session
            try { Remove-ProviderSession -SessionId $executionSessionId -ProjectRoot $ProjectRoot | Out-Null } catch {}

            } catch {
                # Execution phase setup/run failed
                Write-Diag -Msg "Execution EXCEPTION: $($_.Exception.Message)"
                Write-Status "Execution failed: $($_.Exception.Message)" -Type Error
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Execution failed for $($task.name): $($_.Exception.Message)" -ProcessesDir $ProcessesDir
                try {
                    $inProgressDir = Join-Path $tasksBaseDir "in-progress"
                    $todoDir = Join-Path $tasksBaseDir "todo"
                    $taskFile = Get-ChildItem -Path $inProgressDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match $task.id.Substring(0,8) } | Select-Object -First 1
                    if ($taskFile) {
                        $taskData = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                        $taskData.status = 'todo'
                        $taskData | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $todoDir $taskFile.Name) -Encoding UTF8
                        Remove-Item $taskFile.FullName -Force
                        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Recovered task $($task.name) back to todo" -ProcessesDir $ProcessesDir
                    }
                } catch { Write-Warning "Failed to recover task: $_" }
                $taskSuccess = $false
            }

            # Update process data
            $env:DOTBOT_CURRENT_TASK_ID = $null
            $env:CLAUDE_SESSION_ID = $null

            Write-Diag -Msg "Task result: success=$taskSuccess"

            if ($taskSuccess) {
                # Squash-merge task branch to main
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

                        # Escalate: move task from done/ to needs-input/
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
                Write-Diag -Msg "Tasks processed: $tasksProcessed"
                $processData.tasks_completed = $tasksProcessed
                $processData.heartbeat_status = "Completed: $($task.name)"
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task completed (analyse+execute): $($task.name)" -ProcessesDir $ProcessesDir
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

                    Write-Diag -Msg "Consecutive failures: $newFailures (threshold=$consecutiveFailureThreshold)"
                    if ($newFailures -ge $consecutiveFailureThreshold) {
                        Write-Status "$consecutiveFailureThreshold consecutive failures - stopping" -Type Error
                        Write-Diag -Msg "EXIT: Consecutive failure threshold reached"
                        break
                    }
                } catch {}
            }

            } catch {
                # Per-task error recovery
                Write-Diag -Msg "Per-task EXCEPTION: $($_.Exception.Message)"
                Write-Status "Task failed unexpectedly: $($_.Exception.Message)" -Type Error
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task $($task.name) failed: $($_.Exception.Message)" -ProcessesDir $ProcessesDir

                try {
                    foreach ($searchDir in @('analysing', 'in-progress')) {
                        $dir = Join-Path $tasksBaseDir $searchDir
                        $found = Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match $task.id.Substring(0,8) } | Select-Object -First 1
                        if ($found) {
                            $taskData = Get-Content $found.FullName -Raw | ConvertFrom-Json
                            $taskData.status = 'todo'
                            $todoDir = Join-Path $tasksBaseDir "todo"
                            $taskData | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $todoDir $found.Name) -Encoding UTF8
                            Remove-Item $found.FullName -Force
                            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Recovered task $($task.name) back to todo" -ProcessesDir $ProcessesDir
                            break
                        }
                    }
                } catch { Write-Warning "Failed to recover task: $_" }
            }

            # Continue to next task?
            Write-Diag -Msg "Continue check: Continue=$Continue"
            if (-not $Continue) {
                Write-Diag -Msg "EXIT: Continue not set"
                break
            }

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
                Write-Diag -Msg "EXIT: Stop signal after task completion"
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                break
            }
        }
    } catch {
        # Process-level error handler
        Write-Diag -Msg "PROCESS-LEVEL EXCEPTION: $($_.Exception.Message)"
        $processData.status = 'failed'
        $processData.error = $_.Exception.Message
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Process failed: $($_.Exception.Message)" -ProcessesDir $ProcessesDir
        try { Write-Status "Process failed: $($_.Exception.Message)" -Type Error } catch { Write-Host "Process failed: $($_.Exception.Message)" }
    } finally {
        # Final cleanup
        if ($processData.status -eq 'running') {
            $processData.status = 'completed'
            $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Process $ProcId finished ($($processData.status), tasks_completed: $tasksProcessed)" -ProcessesDir $ProcessesDir
        Write-Diag -Msg "=== Process ending: status=$($processData.status) tasksProcessed=$tasksProcessed ==="

        try { Invoke-SessionUpdate -Arguments @{ status = "stopped" } | Out-Null } catch {}
    }
}
