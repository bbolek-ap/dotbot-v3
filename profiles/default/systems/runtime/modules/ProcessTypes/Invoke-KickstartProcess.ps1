#Requires -Version 7.0

function Invoke-KickstartProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcId,
        [Parameter(Mandatory)][hashtable]$ProcessData,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ProcessesDir,
        [Parameter(Mandatory)][string]$ControlDir,
        [Parameter(Mandatory)][string]$ClaudeModelName,
        [Parameter(Mandatory)]$Settings,
        [string]$Prompt,
        [string]$Description,
        [switch]$NeedsInterview,
        [switch]$AutoWorkflow,
        [string]$FromPhase,
        [array]$SkipPhaseIds = @(),
        [switch]$ShowDebug,
        [switch]$ShowVerbose
    )

    $processData = $ProcessData

    if (-not $Description) { $Description = "Kickstart project setup" }

    $processData.status = 'running'
    $processData.workflow = "kickstart-pipeline"
    $processData.description = $Description
    $processData.heartbeat_status = $Description
    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "$Description started" -ProcessesDir $ProcessesDir

    $productDir = Join-Path $BotRoot "workspace\product"

    # Ensure repo has at least one commit
    $hasCommits = git -C $ProjectRoot rev-parse --verify HEAD 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Status "Creating initial commit..." -Type Process
        git -C $ProjectRoot add .bot/ 2>$null
        git -C $ProjectRoot commit -m "chore: initialize dotbot" --allow-empty 2>$null
        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Created initial git commit (repo had no commits)" -ProcessesDir $ProcessesDir
    }

    try {
        # ===== Kickstart phase pipeline (config-driven) =====
        $kickstartPhases = $Settings.kickstart.phases
        if (-not $kickstartPhases -or $kickstartPhases.Count -eq 0) {
            # Fallback: default inline phases
            $kickstartPhases = @(
                @{
                    id = "product-docs"
                    name = "Product Documents"
                    workflow = "01-plan-product.md"
                    required_outputs = @("mission.md", "tech-stack.md", "entity-model.md")
                    front_matter_docs = @("mission.md", "tech-stack.md", "entity-model.md")
                    post_script = $null
                    commit_paths = @("workspace/product/")
                    commit_message = "chore(kickstart): phase 1 — product documents"
                },
                @{
                    id = "task-groups"
                    name = "Task Groups"
                    workflow = "03a-plan-task-groups.md"
                    required_outputs = @("task-groups.json")
                    front_matter_docs = $null
                    post_script = "post-phase-task-groups.ps1"
                    commit_paths = @("workspace/product/")
                    commit_message = "chore(kickstart): phase 2a — task groups and roadmap"
                },
                @{
                    id = "expand-tasks"
                    name = "Task Group Expansion"
                    script = "expand-task-groups.ps1"
                    commit_paths = @("workspace/tasks/")
                    commit_message = "chore(kickstart): phase 2b — expanded task roadmap"
                }
            )
        }

        # ===== Build phase tracking array from config =====
        $hasInterviewPhase = $kickstartPhases | Where-Object { $_.type -eq 'interview' }
        if ($NeedsInterview -and -not $hasInterviewPhase) {
            $processData.phases = @(@{
                id = "interview"; name = "Interview"; type = "interview"
                status = "pending"; started_at = $null; completed_at = $null; error = $null
            })
        } else {
            $processData.phases = @()
        }
        $processData.phases += @($kickstartPhases | ForEach-Object {
            @{
                id = $_.id; name = $_.name
                type = if ($_.type) { $_.type } else { "llm" }
                status = "pending"; started_at = $null; completed_at = $null; error = $null
            }
        })
        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

        # ===== Validate FromPhase =====
        $fromPhaseActive = $false
        if ($FromPhase) {
            $validPhaseIds = @($processData.phases | ForEach-Object { $_.id })
            if ($FromPhase -notin $validPhaseIds) {
                Write-Status "Unknown phase '$FromPhase' — running all phases" -Type Warn
                $FromPhase = $null
            } else {
                $fromPhaseActive = $true
            }
        }

        # ===== Phase 0: Interview (backward compat for profiles without interview-type phase) =====
        if ($NeedsInterview -and -not $hasInterviewPhase) {
            $interviewPhaseIdx = @($processData.phases | ForEach-Object { $_.id }).IndexOf('interview')

            if ($fromPhaseActive -and $FromPhase -ne 'interview') {
                $processData.phases[$interviewPhaseIdx].status = 'skipped'
                $processData.phases[$interviewPhaseIdx].completed_at = 'prior-run'
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
            } else {
                if ($fromPhaseActive) { $fromPhaseActive = $false }
                $processData.phases[$interviewPhaseIdx].status = 'running'
                $processData.phases[$interviewPhaseIdx].started_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

                $processData.heartbeat_status = "Phase 0: Interviewing for requirements"
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                Write-ProcessActivity -Id $ProcId -ActivityType "init" -Message "Phase 0 — interviewing for requirements..." -ProcessesDir $ProcessesDir
                Write-Header "Phase 0: Interview"

                Invoke-InterviewLoop -ProcessId $ProcId -ProcessData $processData `
                    -BotRoot $BotRoot -ProductDir $productDir -UserPrompt $Prompt `
                    -ProcessesDir $ProcessesDir `
                    -ShowDebugJson:$ShowDebug -ShowVerboseOutput:$ShowVerbose

                $processData.phases[$interviewPhaseIdx].status = 'completed'
                $processData.phases[$interviewPhaseIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
            }
        }

        # Build briefing context once
        $briefingDir = Join-Path $productDir "briefing"
        $fileRefs = ""
        if (Test-Path $briefingDir) {
            $briefingFiles = Get-ChildItem -Path $briefingDir -File
            if ($briefingFiles.Count -gt 0) {
                $fileRefs = "`n`nBriefing files have been saved to the briefing/ directory. Read and use these for context:`n"
                foreach ($bf in $briefingFiles) {
                    $fileRefs += "- $($bf.FullName)`n"
                }
            }
        }

        # Build interview context once
        $interviewContext = ""
        $interviewSummaryPath = Join-Path $productDir "interview-summary.md"
        if (Test-Path $interviewSummaryPath) {
            $interviewContext = @"

## Interview Summary

An interview-summary.md file exists in .bot/workspace/product/ containing the user's clarified requirements with both verbatim answers and expanded interpretation. **Read this file** and use it to guide your decisions — it reflects the user's confirmed preferences for platform, architecture, technology, domain model, and other key directions.
"@
        }

        $phaseNum = 1
        $trackIdx = -1
        foreach ($phase in $kickstartPhases) {
            $phaseName = $phase.name
            $trackIdx = @($processData.phases | ForEach-Object { $_.id }).IndexOf($phase.id)

            # --- FromPhase skip logic ---
            if ($fromPhaseActive -and $phase.id -ne $FromPhase) {
                if ($trackIdx -ge 0) {
                    $processData.phases[$trackIdx].status = 'skipped'
                    $processData.phases[$trackIdx].completed_at = 'prior-run'
                    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                }
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Skipping phase $phaseNum ($phaseName): before resume point" -ProcessesDir $ProcessesDir
                Write-Status "Skipping phase $phaseNum ($phaseName) — before resume point" -Type Info
                $phaseNum++; continue
            }
            if ($fromPhaseActive) { $fromPhaseActive = $false }

            # --- Condition check ---
            if ($phase.condition) {
                if ($phase.condition -match '^file_exists:(.+)$') {
                    $checkPath = Join-Path $BotRoot $matches[1]
                    if (-not (Test-Path $checkPath)) {
                        if ($trackIdx -ge 0) {
                            $processData.phases[$trackIdx].status = 'skipped'
                            $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                            Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                        }
                        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Skipping phase $phaseNum ($phaseName): condition not met ($($phase.condition))" -ProcessesDir $ProcessesDir
                        Write-Status "Skipping phase $phaseNum ($phaseName) — condition not met" -Type Info
                        $phaseNum++; continue
                    }
                }
            }

            # --- User-requested skip ---
            if ($phase.id -in $SkipPhaseIds) {
                if ($trackIdx -ge 0) {
                    $processData.phases[$trackIdx].status = 'skipped'
                    $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                }
                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Skipping phase $phaseNum ($phaseName): user opted out" -ProcessesDir $ProcessesDir
                Write-Status "Skipping phase $phaseNum ($phaseName) — user opted out" -Type Info
                $phaseNum++; continue
            }

            # Determine phase type
            $phaseType = if ($phase.type) { $phase.type } else { "llm" }

            # Mark phase as running
            if ($trackIdx -ge 0) {
                $processData.phases[$trackIdx].status = 'running'
                $processData.phases[$trackIdx].started_at = (Get-Date).ToUniversalTime().ToString("o")
            }
            $processData.heartbeat_status = "Phase ${phaseNum}: $phaseName"
            Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
            Write-ProcessActivity -Id $ProcId -ActivityType "init" -Message "Phase $phaseNum — $($phaseName.ToLower())..." -ProcessesDir $ProcessesDir
            Write-Header "Phase ${phaseNum}: $phaseName"

            if ($phaseType -eq "workflow") {
                # --- Workflow phase: spawn child process ---
                if (-not $AutoWorkflow) {
                    if ($trackIdx -ge 0) {
                        $processData.phases[$trackIdx].status = 'skipped'
                        $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                    }
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Skipping workflow phase $phaseNum ($phaseName): auto-execute not enabled" -ProcessesDir $ProcessesDir
                    Write-Status "Skipping workflow phase (auto-execute not enabled)" -Type Info
                    $phaseNum++; continue
                }

                $lpPath = Join-Path $BotRoot "systems\runtime\launch-process.ps1"
                $wfDesc = if ($phaseName) { $phaseName } else { "Execute tasks" }
                $wfArgs = @("-NoProfile", "-File", $lpPath, "-Type", "workflow", "-Continue", "-NoWait", "-Description", "`"$wfDesc`"")
                $startParams = @{ ArgumentList = $wfArgs; WorkingDirectory = $ProjectRoot; PassThru = $true }
                if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
                $wfProc = Start-Process pwsh @startParams

                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Launched workflow process (PID: $($wfProc.Id))" -ProcessesDir $ProcessesDir
                Write-Status "Launched workflow process (PID: $($wfProc.Id))" -Type Process

                # Wait for child process to exit
                while (-not $wfProc.HasExited) {
                    Start-Sleep -Seconds 5
                    $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                    $processData.heartbeat_status = "Waiting: $wfDesc"
                    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                    if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) {
                        try { $wfProc.Kill() } catch {}
                        break
                    }
                }

                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Workflow phase complete (exit code: $($wfProc.ExitCode))" -ProcessesDir $ProcessesDir
                Write-Status "Workflow phase complete" -Type Complete

                # Log child's diagnostic file
                $childDiag = Get-ChildItem $ControlDir -Filter "diag-*.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($childDiag) {
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Child diag log: $($childDiag.FullName)" -ProcessesDir $ProcessesDir
                }

                # Check for remaining unprocessed tasks
                $pendingTasks = @(Get-ChildItem (Join-Path $BotRoot "workspace\tasks\todo") -Filter "*.json" -File -ErrorAction SilentlyContinue)
                $inProgressTasks = @(Get-ChildItem (Join-Path $BotRoot "workspace\tasks\in-progress") -Filter "*.json" -File -ErrorAction SilentlyContinue)
                $analysingTasks = @(Get-ChildItem (Join-Path $BotRoot "workspace\tasks\analysing") -Filter "*.json" -File -ErrorAction SilentlyContinue)
                $analysedTasks = @(Get-ChildItem (Join-Path $BotRoot "workspace\tasks\analysed") -Filter "*.json" -File -ErrorAction SilentlyContinue)

                $remainingCount = $pendingTasks.Count + $inProgressTasks.Count + $analysingTasks.Count + $analysedTasks.Count

                # Retry workflow if tasks remain
                $wfRetries = 0
                $maxWfRetries = 2
                while ($remainingCount -gt 0 -and $wfRetries -lt $maxWfRetries) {
                    $wfRetries++
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Retrying workflow phase (attempt $wfRetries/$maxWfRetries, $remainingCount tasks remaining)" -ProcessesDir $ProcessesDir
                    Write-Status "Retrying workflow phase ($remainingCount tasks remaining, attempt $wfRetries/$maxWfRetries)..." -Type Process

                    $startParams = @{ ArgumentList = $wfArgs; WorkingDirectory = $ProjectRoot; PassThru = $true }
                    if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
                    $wfProc = Start-Process pwsh @startParams

                    while (-not $wfProc.HasExited) {
                        Start-Sleep -Seconds 5
                        $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                        $processData.heartbeat_status = "Retry $wfRetries`: $wfDesc"
                        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                        if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) {
                            try { $wfProc.Kill() } catch {}
                            break
                        }
                    }

                    # Re-check remaining tasks
                    $pendingTasks = @(Get-ChildItem (Join-Path $BotRoot "workspace\tasks\todo") -Filter "*.json" -File -ErrorAction SilentlyContinue)
                    $inProgressTasks = @(Get-ChildItem (Join-Path $BotRoot "workspace\tasks\in-progress") -Filter "*.json" -File -ErrorAction SilentlyContinue)
                    $analysingTasks = @(Get-ChildItem (Join-Path $BotRoot "workspace\tasks\analysing") -Filter "*.json" -File -ErrorAction SilentlyContinue)
                    $analysedTasks = @(Get-ChildItem (Join-Path $BotRoot "workspace\tasks\analysed") -Filter "*.json" -File -ErrorAction SilentlyContinue)
                    $remainingCount = $pendingTasks.Count + $inProgressTasks.Count + $analysingTasks.Count + $analysedTasks.Count
                }

                if ($remainingCount -gt 0) {
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "WARNING: $remainingCount task(s) still pending after $($wfRetries + 1) workflow attempt(s)" -ProcessesDir $ProcessesDir
                    Write-Status "Warning: $remainingCount tasks still pending after $($wfRetries + 1) workflow attempt(s)" -Type Warn
                }

            } elseif ($phaseType -eq "interview") {
                # --- Interview phase ---
                if (-not $NeedsInterview) {
                    if ($trackIdx -ge 0) {
                        $processData.phases[$trackIdx].status = 'skipped'
                        $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                    }
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Skipping interview phase $phaseNum ($phaseName): not requested" -ProcessesDir $ProcessesDir
                    Write-Status "Skipping interview phase (not requested)" -Type Info
                    $phaseNum++; continue
                }

                Invoke-InterviewLoop -ProcessId $ProcId -ProcessData $processData `
                    -BotRoot $BotRoot -ProductDir $productDir -UserPrompt $Prompt `
                    -ProcessesDir $ProcessesDir `
                    -ShowDebugJson:$ShowDebug -ShowVerboseOutput:$ShowVerbose

            } elseif ($phase.script) {
                # --- Script-only phase ---
                $scriptPath = Join-Path $BotRoot "systems\runtime\$($phase.script)"
                & $scriptPath -BotRoot $BotRoot -Model $ClaudeModelName -ProcessId $ProcId
            } else {
                # --- LLM phase ---

                # Pre-phase cleanup
                $phaseQuestionsPath = Join-Path $productDir "clarification-questions.json"
                $phaseAnswersPath = Join-Path $productDir "clarification-answers.json"
                if (Test-Path $phaseQuestionsPath) { Remove-Item $phaseQuestionsPath -Force -ErrorAction SilentlyContinue }
                if (Test-Path $phaseAnswersPath) { Remove-Item $phaseAnswersPath -Force -ErrorAction SilentlyContinue }

                $wfContent = ""
                $wfPath = Join-Path $BotRoot "prompts\workflows\$($phase.workflow)"
                if (Test-Path $wfPath) { $wfContent = Get-Content $wfPath -Raw }

                $phasePrompt = @"
$wfContent

User's project description:
$Prompt
$fileRefs
$interviewContext

Instructions:
1. Read any briefing files listed above and any existing project files (README.md, etc.) for additional context
2. If an interview-summary.md file exists in .bot/workspace/product/, read it carefully — it contains clarified requirements from the user
3. Follow the workflow above to create the required outputs. Write files to .bot/workspace/product/
4. Do NOT create tasks or use task management tools unless the workflow explicitly instructs you to
5. Write comprehensive, well-structured content based on the user's description and any attached files
6. Make reasonable inferences where details are missing — the user can refine later

IMPORTANT: If creating mission.md, it MUST begin with ## Executive Summary as the first content after the title. This is required for the UI to detect that product planning is complete.
"@

                $claudeSessionId = New-ProviderSession
                $streamArgs = @{
                    Prompt = $phasePrompt
                    Model = $ClaudeModelName
                    SessionId = $claudeSessionId
                    PersistSession = $false
                }
                if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                Invoke-ProviderStream @streamArgs

                # --- Post-phase question detection (Generate -> Ask -> Adjust) ---
                if (Test-Path $phaseQuestionsPath) {
                    try {
                        $phaseQData = (Get-Content $phaseQuestionsPath -Raw) | ConvertFrom-Json
                    } catch {
                        Write-Status "Failed to parse phase questions JSON: $($_.Exception.Message)" -Type Warn
                        $phaseQData = $null
                    }

                    if ($phaseQData -and $phaseQData.questions -and $phaseQData.questions.Count -gt 0) {
                        Write-Status "Phase $phaseNum ($phaseName): $($phaseQData.questions.Count) question(s) — waiting for user" -Type Info
                        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Phase $phaseNum has $($phaseQData.questions.Count) clarification question(s)" -ProcessesDir $ProcessesDir

                        # 1. ASK
                        $processData.status = 'needs-input'
                        $processData.pending_questions = $phaseQData
                        $processData.heartbeat_status = "Waiting for answers (phase ${phaseNum}: $phaseName)"
                        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir

                        if (Test-Path $phaseAnswersPath) { Remove-Item $phaseAnswersPath -Force }

                        while (-not (Test-Path $phaseAnswersPath)) {
                            if (Test-ProcessStopSignal -Id $ProcId -ProcessesDir $ProcessesDir) {
                                Write-Status "Stop signal received waiting for phase answers" -Type Error
                                $processData.status = 'stopped'
                                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                                $processData.pending_questions = $null
                                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                                throw "Process stopped by user during phase $phaseNum questions"
                            }
                            Start-Sleep -Seconds 2
                        }

                        # Read answers
                        try {
                            $phaseAnswersData = (Get-Content $phaseAnswersPath -Raw) | ConvertFrom-Json
                        } catch {
                            Write-Status "Failed to parse phase answers JSON: $($_.Exception.Message)" -Type Warn
                            $phaseAnswersData = $null
                        }

                        # Check if user skipped
                        if ($phaseAnswersData -and $phaseAnswersData.skipped -eq $true) {
                            Write-Status "User skipped phase $phaseNum questions" -Type Info
                            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "User skipped phase $phaseNum questions" -ProcessesDir $ProcessesDir
                        } elseif ($phaseAnswersData) {
                            Write-Status "Answers received for phase $phaseNum" -Type Success
                            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Received answers for phase $phaseNum" -ProcessesDir $ProcessesDir

                            # 2. RECORD
                            $summaryPath = Join-Path $productDir "interview-summary.md"
                            $timestamp = (Get-Date).ToUniversalTime().ToString("o")
                            $qaSection = "`n`n### Phase ${phaseNum}: $phaseName`n"
                            $qaSection += "| # | Question | Answer (verbatim) | Interpretation | Timestamp |`n"
                            $qaSection += "|---|----------|--------------------|----------------|-----------|`n"

                            $qIdx = 0
                            foreach ($ans in $phaseAnswersData.answers) {
                                $qIdx++
                                $qText = ($ans.question -replace '\|', '\|' -replace "`n", ' ')
                                $aText = ($ans.answer -replace '\|', '\|' -replace "`n", ' ')
                                $qaSection += "| q$qIdx | $qText | $aText | _pending_ | $timestamp |`n"
                            }

                            if (Test-Path $summaryPath) {
                                $existingContent = Get-Content $summaryPath -Raw
                                if ($existingContent -notmatch '## Clarification Log') {
                                    $qaSection = "`n## Clarification Log`n" + $qaSection
                                }
                                Add-Content -Path $summaryPath -Value $qaSection -NoNewline
                            } else {
                                $newSummary = "# Interview Summary`n`n## Clarification Log`n" + $qaSection
                                Set-Content -Path $summaryPath -Value $newSummary -NoNewline
                            }

                            # 3. ADJUST
                            $adjustPromptPath = Join-Path $BotRoot "prompts\includes\adjust-after-answers.md"
                            if (Test-Path $adjustPromptPath) {
                                $adjustContent = Get-Content $adjustPromptPath -Raw

                                $adjustPrompt = @"
$adjustContent

## Context

- **Phase that generated questions**: Phase $phaseNum — $phaseName
- **User's project description**: $Prompt
$fileRefs
$interviewContext

Instructions:
1. Read .bot/workspace/product/interview-summary.md for the full Q&A history including the new answers
2. Read ALL existing product artifacts in .bot/workspace/product/
3. Assess the impact of the new information across all artifacts
4. Enrich/correct any affected artifacts
5. Fill in the Interpretation column for the new Q&A entries in interview-summary.md
"@

                                Write-Status "Running post-answer adjustment for phase $phaseNum..." -Type Process
                                Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Adjusting artifacts based on phase $phaseNum answers" -ProcessesDir $ProcessesDir

                                $adjustSessionId = New-ProviderSession
                                $adjustArgs = @{
                                    Prompt = $adjustPrompt
                                    Model = $ClaudeModelName
                                    SessionId = $adjustSessionId
                                    PersistSession = $false
                                }
                                if ($ShowDebug) { $adjustArgs['ShowDebugJson'] = $true }
                                if ($ShowVerbose) { $adjustArgs['ShowVerbose'] = $true }

                                Invoke-ProviderStream @adjustArgs

                                Write-Status "Post-answer adjustment complete for phase $phaseNum" -Type Complete
                            } else {
                                Write-Status "Adjust prompt not found at $adjustPromptPath — skipping adjustment" -Type Warn
                            }
                        }

                        # 4. CLEANUP
                        Remove-Item $phaseQuestionsPath -Force -ErrorAction SilentlyContinue
                        Remove-Item $phaseAnswersPath -Force -ErrorAction SilentlyContinue
                        $processData.status = 'running'
                        $processData.pending_questions = $null
                        $processData.heartbeat_status = "Running phase $phaseNum"
                        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
                    }
                }
            }

            # --- Validation (skip for workflow/interview phase types) ---
            if ($phaseType -notin @("workflow", "interview")) {
                if ($phase.required_outputs) {
                    foreach ($f in $phase.required_outputs) {
                        if (-not (Test-Path (Join-Path $productDir $f))) {
                            throw "Phase $phaseNum ($phaseName) failed: $f was not created"
                        }
                    }
                } elseif ($phase.required_outputs_dir) {
                    $dirPath = Join-Path $BotRoot "workspace\$($phase.required_outputs_dir)"
                    $minCount = if ($phase.min_output_count) { [int]$phase.min_output_count } else { 1 }
                    $fileCount = if (Test-Path $dirPath) { (Get-ChildItem $dirPath -Filter "*.json" -File).Count } else { 0 }
                    if ($fileCount -lt $minCount) {
                        throw "Phase $phaseNum ($phaseName) failed: expected at least $minCount file(s) in $($phase.required_outputs_dir), found $fileCount"
                    }
                }
            }

            # --- Front matter ---
            if ($phase.front_matter_docs) {
                $phaseMeta = @{
                    generated_at = (Get-Date).ToUniversalTime().ToString("o")
                    model = $ClaudeModelName
                    process_id = $ProcId
                    phase = "phase-$phaseNum-$($phase.id)"
                    generator = "dotbot-kickstart"
                }
                foreach ($docName in $phase.front_matter_docs) {
                    $docPath = Join-Path $productDir $docName
                    if (Test-Path $docPath) {
                        Add-YamlFrontMatter -FilePath $docPath -Metadata $phaseMeta
                    }
                }
            }

            # --- Post-script ---
            if ($phase.post_script) {
                $postPath = Join-Path $BotRoot "systems\runtime\$($phase.post_script)"
                & $postPath -BotRoot $BotRoot -ProductDir $productDir -Settings $Settings -Model $ClaudeModelName -ProcessId $ProcId
            }

            # --- Git checkpoint ---
            if ($phase.commit_paths) {
                Write-Status "Committing phase $phaseNum artifacts..." -Type Info
                foreach ($cp in $phase.commit_paths) {
                    git -C $ProjectRoot add ".bot/$cp" 2>$null
                }
                $commitMsg = if ($phase.commit_message) { $phase.commit_message } else { "chore(kickstart): phase $phaseNum — $($phaseName.ToLower())" }
                git -C $ProjectRoot commit --quiet -m $commitMsg 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Phase $phaseNum checkpoint committed" -ProcessesDir $ProcessesDir
                } else {
                    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Phase $phaseNum checkpoint: nothing to commit" -ProcessesDir $ProcessesDir
                }
            }

            # Mark phase as completed
            if ($trackIdx -ge 0) {
                $processData.phases[$trackIdx].status = 'completed'
                $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
            }

            Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Phase $phaseNum complete — $($phaseName.ToLower())" -ProcessesDir $ProcessesDir
            $phaseNum++
        }

        # Done
        $processData.status = 'completed'
        $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.heartbeat_status = "Completed: $Description"
    } catch {
        # Mark the current phase as failed
        if ($trackIdx -ge 0 -and $processData.phases[$trackIdx].status -eq 'running') {
            $processData.phases[$trackIdx].status = 'failed'
            $processData.phases[$trackIdx].error = $_.Exception.Message
        }
        $processData.status = 'failed'
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.error = $_.Exception.Message
        $processData.heartbeat_status = "Failed: $($_.Exception.Message)"
        Write-Status "Process failed: $($_.Exception.Message)" -Type Error
    }

    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Process $ProcId finished ($($processData.status))" -ProcessesDir $ProcessesDir
}
