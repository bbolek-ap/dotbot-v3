Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\PathSanitizer.psm1") -Force

function Write-TaskMarkDoneFailure {
    param(
        [string]$TaskId,
        [string]$Message,
        [array]$VerificationResults = @()
    )

    try {
        $controlDir   = Join-Path $global:DotbotProjectRoot ".bot\.control"
        $activityFile = Join-Path $controlDir "activity.jsonl"
        if (-not (Test-Path $controlDir)) { return }

        $failedScripts = @($VerificationResults | Where-Object { $_.success -eq $false -and -not $_.skipped })
        if ($failedScripts.Count -gt 0) {
            $detail = ($failedScripts | ForEach-Object {
                $failLines = if ($_.failures) { ($_.failures | ForEach-Object { $_.issue }) -join "; " } else { $_.message }
                "$($_.script): $failLines"
            }) -join " | "
            $Message = "$Message — $detail"
        }

        $entry = [ordered]@{
            type       = "text"
            timestamp  = (Get-Date).ToUniversalTime().ToString("o")
            message    = $Message
            task_id    = $TaskId
            phase      = "execution"
            process_id = $env:DOTBOT_PROCESS_ID
        }
        ($entry | ConvertTo-Json -Compress) | Add-Content -Path $activityFile -Encoding UTF8
    } catch { }
}

function Get-ExecutionActivityLog {
    param([string]$TaskId, [string]$ProjectRoot)

    $controlDir   = Join-Path $global:DotbotProjectRoot ".bot\.control"
    $activityFile = Join-Path $controlDir "activity.jsonl"
    if (-not (Test-Path $activityFile)) { return @() }

    $taskActivities = @()
    Get-Content $activityFile | ForEach-Object {
        try {
            $entry = $_ | ConvertFrom-Json
            if ($entry.task_id -eq $TaskId -and (-not $entry.phase -or $entry.phase -eq "execution")) {
                $sanitizedMessage = Remove-AbsolutePaths -Text $entry.message -ProjectRoot $ProjectRoot
                $sanitizedEntry = $entry | Select-Object -Property type, timestamp
                $sanitizedEntry | Add-Member -NotePropertyName "message" -NotePropertyValue $sanitizedMessage -Force
                $taskActivities += $sanitizedEntry
            }
        } catch { }
    }

    return $taskActivities
}

function Invoke-VerificationScripts {
    param([string]$TaskId, [string]$Category, [string]$ProjectRoot)

    $scriptsDir = Join-Path $global:DotbotProjectRoot ".bot\hooks\verify"
    $configPath = Join-Path $scriptsDir "config.json"

    if (-not (Test-Path $configPath)) {
        return @{ AllPassed = $true; Scripts = @() }
    }

    $config  = Get-Content $configPath -Raw | ConvertFrom-Json
    $results = @()

    foreach ($scriptConfig in $config.scripts) {
        $scriptPath = Join-Path $scriptsDir $scriptConfig.name

        if (-not (Test-Path $scriptPath)) {
            $results += @{ success = $false; script = $scriptConfig.name; message = "Script file not found" }
            continue
        }

        if ($scriptConfig.skip_if_category -and $scriptConfig.skip_if_category -contains $Category) {
            $results += @{ success = $true; script = $scriptConfig.name; message = "Skipped (category: $Category)"; skipped = $true }
            continue
        }

        if ($scriptConfig.run_if_category -and $scriptConfig.run_if_category -notcontains $Category) {
            $results += @{ success = $true; script = $scriptConfig.name; message = "Skipped (not applicable for category: $Category)"; skipped = $true }
            continue
        }

        try {
            if (-not $ProjectRoot)                                { throw "Project root parameter is required" }
            if (-not (Test-Path $ProjectRoot))                    { throw "Project root directory does not exist: $ProjectRoot" }
            if (-not (Test-Path (Join-Path $ProjectRoot ".git"))) { throw "Project root does not contain .git folder: $ProjectRoot" }

            Push-Location $ProjectRoot
            try {
                $output = & $scriptPath -TaskId $TaskId -Category $Category 2>&1
                $result = $output | ConvertFrom-Json -ErrorAction Stop
                $results += $result
            } finally {
                Pop-Location
            }

            if ($scriptConfig.required -and -not $result.success) { break }
        } catch {
            $results += @{
                success = $false
                script  = $scriptConfig.name
                message = "Script execution failed: $($_.Exception.Message)"
                details = @{ error = $_.Exception.Message }
            }
            if ($scriptConfig.required) { break }
        }
    }

    $failedScripts = $results | Where-Object { $_.success -eq $false -and -not $_.skipped }
    return @{ AllPassed = ($failedScripts.Count -eq 0); Scripts = $results }
}

function Invoke-TaskMarkDone {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments["task_id"]
    if (-not $taskId) { throw "Task ID is required" }

    $projectRoot = $global:DotbotProjectRoot
    if (-not $projectRoot) {
        throw "Project root not available. MCP server may not have initialized correctly."
    }

    [Console]::Error.WriteLine("[task-mark-done] taskId=$taskId")

    # Read task to get category for verification (before the move)
    $existing = Get-TaskByIdOrSlug -Identifier $taskId
    if (-not $existing) {
        Write-TaskMarkDoneFailure -TaskId $taskId -Message "task_mark_done failed: task '$taskId' not found"
        throw "Task with ID '$taskId' not found"
    }

    if ($existing.status -eq "done") {
        return @{
            success = $true
            message = "Task is already marked as done"
            task_id = $taskId
            status  = "done"
        }
    }

    # Run verification scripts before committing the state change
    $verificationResults = Invoke-VerificationScripts `
        -TaskId      $taskId `
        -Category    $existing.task.category `
        -ProjectRoot $projectRoot

    if (-not $verificationResults.AllPassed) {
        Write-TaskMarkDoneFailure `
            -TaskId              $taskId `
            -Message             "task_mark_done blocked: verification failed for '$($existing.task.name)'" `
            -VerificationResults $verificationResults.Scripts

        return @{
            success              = $false
            message              = "Task verification failed - task stays in '$($existing.status)'"
            task_id              = $taskId
            current_status       = $existing.status
            verification_passed  = $false
            verification_results = $verificationResults.Scripts
        }
    }

    # Extract commit information (non-fatal)
    $commitInfo = $null
    try {
        $modulePath = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\Extract-CommitInfo.ps1"
        if (Test-Path $modulePath) {
            . $modulePath
            $commits = Get-TaskCommitInfo -TaskId $taskId -ProjectRoot $projectRoot
            if ($commits -and $commits.Count -gt 0) {
                $commitInfo = @{ commits = $commits; most_recent = $commits[0] }
            }
        }
    } catch {
        Write-Warning "Failed to extract commit info: $($_.Exception.Message)"
    }

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $updates = @{ completed_at = $now }

    if ($commitInfo -and $commitInfo.most_recent) {
        $mr = $commitInfo.most_recent
        $updates["commit_sha"]     = $mr.commit_sha
        $updates["commit_subject"] = $mr.commit_subject
        $updates["files_created"]  = $mr.files_created
        $updates["files_deleted"]  = $mr.files_deleted
        $updates["files_modified"] = $mr.files_modified
        $updates["commits"]        = $commitInfo.commits
    }

    $executionActivities = Get-ExecutionActivityLog -TaskId $taskId -ProjectRoot $projectRoot
    if ($executionActivities.Count -gt 0) {
        $updates["execution_activity_log"] = $executionActivities
    }

    $result = Move-TaskState `
        -TaskId     $taskId `
        -FromStates @("todo", "in-progress") `
        -ToState    "done" `
        -Updates    $updates

    # Close Claude session (post-move in-place update)
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Close-SessionOnTask -TaskContent $result.task -SessionId $claudeSessionId -Phase "execution"
        $result.task | ConvertTo-Json -Depth 10 | Set-Content -Path $result.new_path -Encoding UTF8
    }

    return @{
        success              = $true
        message              = "Task marked as done"
        task_id              = $taskId
        old_status           = $result.old_status
        new_status           = "done"
        old_path             = $result.old_path
        new_path             = $result.new_path
        verification_passed  = $true
        verification_results = $verificationResults.Scripts
    }
}
