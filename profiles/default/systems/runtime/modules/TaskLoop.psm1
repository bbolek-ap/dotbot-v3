#Requires -Version 7.0

<#
.SYNOPSIS
Shared task iteration helpers: next-task retrieval, dependency deadlock detection,
YAML front matter, and interview loop.
#>

function Add-YamlFrontMatter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][hashtable]$Metadata
    )
    $yaml = "---`n"
    foreach ($key in ($Metadata.Keys | Sort-Object)) {
        $yaml += "${key}: `"$($Metadata[$key])`"`n"
    }
    $yaml += "---`n`n"
    $existing = Get-Content $FilePath -Raw
    # If file already has YAML front matter, replace it; otherwise prepend
    if ($existing -match '(?s)^---\r?\n.*?\r?\n---\r?\n') {
        $body = $existing -replace '(?s)^---\r?\n.*?\r?\n---\r?\n+', ''
        ($yaml + $body) | Set-Content -Path $FilePath -Encoding utf8NoBOM -NoNewline
    } else {
        ($yaml + $existing) | Set-Content -Path $FilePath -Encoding utf8NoBOM -NoNewline
    }
}

function Get-NextTodoTask {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$VerboseOutput)

    # First priority: check for analysing tasks that came back from needs-input
    $index = Get-TaskIndex
    $resumedTasks = @($index.Analysing.Values) | Sort-Object priority
    foreach ($candidate in $resumedTasks) {
        if ($candidate.file_path -and (Test-Path $candidate.file_path)) {
            try {
                $content = Get-Content -Path $candidate.file_path -Raw | ConvertFrom-Json
                if ($content.questions_resolved -and $content.questions_resolved.Count -gt 0 -and -not $content.pending_question) {
                    Write-Status "Found resumed task (question answered): $($candidate.name)" -Type Info
                    $taskObj = @{
                        id = $content.id
                        name = $content.name
                        status = 'analysing'
                        priority = [int]$content.priority
                        effort = $content.effort
                        category = $content.category
                    }
                    if ($VerboseOutput.IsPresent) {
                        $taskObj.description = $content.description
                        $taskObj.dependencies = $content.dependencies
                        $taskObj.acceptance_criteria = $content.acceptance_criteria
                        $taskObj.steps = $content.steps
                        $taskObj.applicable_agents = $content.applicable_agents
                        $taskObj.applicable_standards = $content.applicable_standards
                        $taskObj.file_path = $candidate.file_path
                        $taskObj.questions_resolved = $content.questions_resolved
                        $taskObj.claude_session_id = $content.claude_session_id
                        $taskObj.needs_interview = $content.needs_interview
                        $taskObj.working_dir = $content.working_dir
                        $taskObj.external_repo = $content.external_repo
                        $taskObj.research_prompt = $content.research_prompt
                    }
                    return @{
                        success = $true
                        task = $taskObj
                        message = "Resumed task (question answered): $($content.name)"
                    }
                }
            } catch {
                Write-Warning "Failed to read analysing task: $($candidate.file_path) - $_"
            }
        }
    }

    # Second priority: get next todo task
    $result = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $false; verbose = $VerboseOutput.IsPresent }
    if ($result.task -and $result.task.status -eq 'todo') {
        return $result
    }

    return @{
        success = $true
        task = $null
        message = "No tasks available for analysis."
    }
}

function Get-NextWorkflowTask {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$VerboseOutput)

    # First priority: check for analysing tasks that came back from needs-input
    $index = Get-TaskIndex
    $resumedTasks = @($index.Analysing.Values) | Sort-Object priority
    foreach ($candidate in $resumedTasks) {
        if ($candidate.file_path -and (Test-Path $candidate.file_path)) {
            try {
                $content = Get-Content -Path $candidate.file_path -Raw | ConvertFrom-Json
                if ($content.questions_resolved -and $content.questions_resolved.Count -gt 0 -and -not $content.pending_question) {
                    Write-Status "Found resumed task (question answered): $($candidate.name)" -Type Info
                    $taskObj = @{
                        id = $content.id
                        name = $content.name
                        status = 'analysing'
                        priority = [int]$content.priority
                        effort = $content.effort
                        category = $content.category
                    }
                    if ($VerboseOutput.IsPresent) {
                        $taskObj.description = $content.description
                        $taskObj.dependencies = $content.dependencies
                        $taskObj.acceptance_criteria = $content.acceptance_criteria
                        $taskObj.steps = $content.steps
                        $taskObj.applicable_agents = $content.applicable_agents
                        $taskObj.applicable_standards = $content.applicable_standards
                        $taskObj.file_path = $candidate.file_path
                        $taskObj.questions_resolved = $content.questions_resolved
                        $taskObj.claude_session_id = $content.claude_session_id
                        $taskObj.needs_interview = $content.needs_interview
                        $taskObj.working_dir = $content.working_dir
                        $taskObj.external_repo = $content.external_repo
                        $taskObj.research_prompt = $content.research_prompt
                    }
                    return @{
                        success = $true
                        task = $taskObj
                        message = "Resumed task (question answered): $($content.name)"
                    }
                }
            } catch {
                Write-Warning "Failed to read analysing task: $($candidate.file_path) - $_"
            }
        }
    }

    # Second priority: prefer analysed tasks (ready for execution), then todo
    $result = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $true; verbose = $VerboseOutput.IsPresent }
    return $result
}

function Test-DependencyDeadlock {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ProcessId,
        [Parameter(Mandatory)][string]$ProcessesDir
    )
    $deadlock = Get-DeadlockedTasks
    if ($deadlock.BlockedCount -gt 0) {
        $blockers    = $deadlock.BlockerNames -join ', '
        $deadlockMsg = "Dependency deadlock: $($deadlock.BlockedCount) todo task(s) are blocked by skipped prerequisite(s) [$blockers]. Workflow cannot continue automatically — reset or re-implement the skipped tasks to unblock the queue."
        Write-Status $deadlockMsg -Type Error
        Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message $deadlockMsg -ProcessesDir $ProcessesDir
        return $true
    }
    return $false
}

function Invoke-InterviewLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcessId,
        [Parameter(Mandatory)][hashtable]$ProcessData,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProductDir,
        [Parameter(Mandatory)][string]$UserPrompt,
        [Parameter(Mandatory)][string]$ProcessesDir,
        [switch]$ShowDebugJson,
        [switch]$ShowVerboseOutput
    )

    $processData = $ProcessData

    # Load interview prompt template
    $interviewWorkflowPath = Join-Path $BotRoot "prompts\workflows\00-kickstart-interview.md"
    $interviewWorkflow = ""
    if (Test-Path $interviewWorkflowPath) {
        $interviewWorkflow = Get-Content $interviewWorkflowPath -Raw
    }

    # Check for briefing files
    $briefingDir = Join-Path $ProductDir "briefing"
    $interviewFileRefs = ""
    if (Test-Path $briefingDir) {
        $briefingFiles = Get-ChildItem -Path $briefingDir -File
        if ($briefingFiles.Count -gt 0) {
            $interviewFileRefs = "`n`nBriefing files have been saved to the briefing/ directory. Read and use these for context:`n"
            foreach ($bf in $briefingFiles) {
                $interviewFileRefs += "- $($bf.FullName)`n"
            }
        }
    }

    $interviewRound = 0
    $allQandA = @()
    $questionsPath = Join-Path $ProductDir "clarification-questions.json"
    $summaryPath = Join-Path $ProductDir "interview-summary.md"

    # Use Opus for interview quality
    $interviewModel = Resolve-ProviderModelId -ModelAlias 'Opus'

    do {
        $interviewRound++

        # Build previous Q&A context
        $previousContext = ""
        if ($allQandA.Count -gt 0) {
            $previousContext = "`n`n## Previous Interview Rounds`n"
            foreach ($round in $allQandA) {
                $previousContext += "`n### Round $($round.round)`n"
                foreach ($qa in $round.pairs) {
                    $previousContext += "**Q:** $($qa.question)`n**A:** $($qa.answer)`n`n"
                }
            }
        }

        # Clean up any previous round's files
        if (Test-Path $questionsPath) { Remove-Item $questionsPath -Force }
        if (Test-Path $summaryPath) { Remove-Item $summaryPath -Force }

        $interviewPrompt = @"
$interviewWorkflow

## User's Project Description

$UserPrompt
$interviewFileRefs
$previousContext

## Instructions

Review all context above. Decide whether to write clarification-questions.json (more questions needed) or interview-summary.md (all clear). Write exactly one file to .bot/workspace/product/.
"@

        Write-Status "Interview round $interviewRound..." -Type Process
        Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview round $interviewRound" -ProcessesDir $ProcessesDir

        $interviewSessionId = New-ProviderSession
        $streamArgs = @{
            Prompt = $interviewPrompt
            Model = $interviewModel
            SessionId = $interviewSessionId
            PersistSession = $false
        }
        if ($ShowDebugJson) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerboseOutput) { $streamArgs['ShowVerbose'] = $true }

        Invoke-ProviderStream @streamArgs

        # Check what Opus wrote
        if (Test-Path $summaryPath) {
            Write-Status "Interview complete — summary written" -Type Complete
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview complete after $interviewRound round(s)" -ProcessesDir $ProcessesDir

            # Add YAML front matter to interview summary
            $meta = @{
                generated_at = (Get-Date).ToUniversalTime().ToString("o")
                model = $interviewModel
                process_id = $ProcessId
                phase = "interview"
                generator = "dotbot-kickstart"
            }
            Add-YamlFrontMatter -FilePath $summaryPath -Metadata $meta

            break
        }

        if (Test-Path $questionsPath) {
            try {
                $questionsRaw = Get-Content $questionsPath -Raw
                $questionsData = $questionsRaw | ConvertFrom-Json
                $questions = $questionsData.questions
            } catch {
                Write-Status "Failed to parse questions JSON: $($_.Exception.Message)" -Type Warn
                break
            }

            Write-Status "Round ${interviewRound}: $($questions.Count) question(s) — waiting for user" -Type Info

            # Set process to needs-input
            $processData.status = 'needs-input'
            $processData.pending_questions = $questionsData
            $processData.interview_round = $interviewRound
            $processData.heartbeat_status = "Waiting for interview answers (round $interviewRound)"
            Write-ProcessFile -Id $ProcessId -Data $processData -ProcessesDir $ProcessesDir
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Waiting for user answers (round $interviewRound, $($questions.Count) questions)" -ProcessesDir $ProcessesDir

            # Poll for answers file
            $answersPath = Join-Path $ProductDir "clarification-answers.json"
            if (Test-Path $answersPath) { Remove-Item $answersPath -Force }

            while (-not (Test-Path $answersPath)) {
                if (Test-ProcessStopSignal -Id $ProcessId -ProcessesDir $ProcessesDir) {
                    Write-Status "Stop signal received during interview" -Type Error
                    $processData.status = 'stopped'
                    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                    $processData.pending_questions = $null
                    Write-ProcessFile -Id $ProcessId -Data $processData -ProcessesDir $ProcessesDir
                    throw "Process stopped by user during interview"
                }
                Start-Sleep -Seconds 2
            }

            # Read answers
            try {
                $answersRaw = Get-Content $answersPath -Raw
                $answersData = $answersRaw | ConvertFrom-Json
            } catch {
                Write-Status "Failed to parse answers JSON: $($_.Exception.Message)" -Type Warn
                break
            }

            # Check if user skipped
            if ($answersData.skipped -eq $true) {
                Write-Status "User skipped interview" -Type Info
                Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "User skipped interview at round $interviewRound" -ProcessesDir $ProcessesDir
                # Clean up
                Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
                Remove-Item $answersPath -Force -ErrorAction SilentlyContinue
                break
            }

            # Accumulate Q&A for next round
            $allQandA += @{
                round = $interviewRound
                pairs = @($answersData.answers)
            }

            Write-Status "Answers received for round $interviewRound" -Type Success
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Received answers for round $interviewRound" -ProcessesDir $ProcessesDir

            # Clean up for next iteration
            Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
            Remove-Item $answersPath -Force -ErrorAction SilentlyContinue

            # Reset process status
            $processData.status = 'running'
            $processData.pending_questions = $null
            $processData.interview_round = $null
            $processData.heartbeat_status = "Processing interview answers"
            Write-ProcessFile -Id $ProcessId -Data $processData -ProcessesDir $ProcessesDir
        } else {
            # Neither file written — something went wrong, proceed without
            Write-Status "Interview round produced no output — proceeding" -Type Warn
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview round $interviewRound produced no output — skipping" -ProcessesDir $ProcessesDir
            break
        }
    } while ($true)

    # Ensure status is running after interview
    $processData.status = 'running'
    $processData.pending_questions = $null
    $processData.interview_round = $null
    Write-ProcessFile -Id $ProcessId -Data $processData -ProcessesDir $ProcessesDir
}

Export-ModuleMember -Function @(
    'Add-YamlFrontMatter'
    'Get-NextTodoTask'
    'Get-NextWorkflowTask'
    'Test-DependencyDeadlock'
    'Invoke-InterviewLoop'
)
