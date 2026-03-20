#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Tests for TaskStore.psm1 - state transitions and CRUD operations.
.DESCRIPTION
    Validates Move-TaskState, Get-TaskByIdOrSlug, New-TaskRecord, and
    Update-TaskRecord directly from repo source. No Claude credentials needed.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host "  TaskStore Module Tests" -ForegroundColor Blue
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

function New-TaskStoreTestProject {
    param([string]$RepoRoot)

    $projectRoot = New-TestProject -Prefix "dotbot-task-store"
    $botDir      = Join-Path $projectRoot ".bot"
    New-Item -ItemType Directory -Path $botDir -Force | Out-Null

    Copy-Item -Path (Join-Path $RepoRoot "profiles\default\*") -Destination $botDir -Recurse -Force

    foreach ($sub in @(
        "workspace\tasks\todo",
        "workspace\tasks\analysing",
        "workspace\tasks\analysed",
        "workspace\tasks\needs-input",
        "workspace\tasks\in-progress",
        "workspace\tasks\done",
        "workspace\tasks\split",
        "workspace\tasks\skipped",
        "workspace\tasks\cancelled"
    )) {
        $full = Join-Path $botDir $sub
        if (-not (Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null }
    }

    return $projectRoot
}

function New-SimpleTaskFile {
    param(
        [string]$Dir,
        [string]$Id,
        [string]$Name = "Task $Id",
        [string]$Status = "todo"
    )

    $task = [ordered]@{
        id          = $Id
        name        = $Name
        description = "Description for $Name"
        category    = "feature"
        priority    = 10
        effort      = "S"
        status      = $Status
        dependencies = @()
        acceptance_criteria = @()
        created_at  = "2026-01-01T00:00:00Z"
        updated_at  = "2026-01-01T00:00:00Z"
        completed_at = $null
    }

    $path = Join-Path $Dir "$Id.json"
    $task | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    return $path
}

$testProject = $null

try {
    $testProject = New-TaskStoreTestProject -RepoRoot $repoRoot
    $botDir       = Join-Path $testProject ".bot"
    $tasksBaseDir = Join-Path $botDir "workspace\tasks"
    $todoDir      = Join-Path $tasksBaseDir "todo"

    $global:DotbotProjectRoot = $testProject

    $taskStoreModule = Join-Path $botDir "systems\mcp\modules\TaskStore.psm1"

    Write-Host ""
    Write-Host "  MODULE CONTRACT" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    Assert-PathExists -Name "TaskStore.psm1 exists in installed .bot" -Path $taskStoreModule

    if (-not (Test-Path $taskStoreModule)) {
        Write-TestSummary -LayerName "TaskStore Tests" | Out-Null
        exit 1
    }

    Import-Module $taskStoreModule -Force

    foreach ($fn in @("Move-TaskState", "Get-TaskByIdOrSlug", "New-TaskRecord", "Update-TaskRecord")) {
        Assert-True -Name "TaskStore exports $fn" `
            -Condition ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue)) `
            -Message "Expected $fn to be exported from TaskStore"
    }

    Write-Host ""
    Write-Host "  MOVE-TASKSTATE: BASIC TRANSITION" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    New-SimpleTaskFile -Dir $todoDir -Id "ts-move-01" -Name "Move test task" | Out-Null

    $result = Move-TaskState -TaskId "ts-move-01" -FromStates @("todo") -ToState "analysing"

    Assert-True -Name "Move-TaskState returns result object" `
        -Condition ($null -ne $result) -Message "Expected non-null result"

    Assert-Equal -Name "Move-TaskState reports correct old_status" `
        -Expected "todo" -Actual $result.old_status

    Assert-Equal -Name "Move-TaskState reports correct new_status" `
        -Expected "analysing" -Actual $result.new_status

    Assert-True -Name "Move-TaskState already_in_state is false for new transition" `
        -Condition ($result.already_in_state -eq $false) -Message "Expected already_in_state=false"

    $analysingDir = Join-Path $tasksBaseDir "analysing"
    Assert-PathExists -Name "Task file moved to analysing directory" `
        -Path (Join-Path $analysingDir "ts-move-01.json")

    Assert-PathNotExists -Name "Task file removed from todo directory" `
        -Path (Join-Path $todoDir "ts-move-01.json")

    $movedTask = Get-Content (Join-Path $analysingDir "ts-move-01.json") -Raw | ConvertFrom-Json
    Assert-Equal -Name "Moved task has updated status field" `
        -Expected "analysing" -Actual $movedTask.status

    Assert-True -Name "Moved task has updated_at refreshed" `
        -Condition ($movedTask.updated_at -ne "2026-01-01T00:00:00Z") `
        -Message "Expected updated_at to be refreshed"

    Write-Host ""
    Write-Host "  MOVE-TASKSTATE: UPDATES APPLIED" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    New-SimpleTaskFile -Dir $todoDir -Id "ts-updates-01" -Name "Updates test" | Out-Null

    $now     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $result2 = Move-TaskState -TaskId "ts-updates-01" -FromStates @("todo") -ToState "analysing" `
        -Updates @{ analysis_started_at = $now; custom_field = "hello" }

    $updatedTask = Get-Content (Join-Path $analysingDir "ts-updates-01.json") -Raw | ConvertFrom-Json

    Assert-True -Name "Move-TaskState applies analysis_started_at update" `
        -Condition (Compare-IsoTimestamps -Expected $now -Actual "$($updatedTask.analysis_started_at)") `
        -Message "Expected analysis_started_at to match the timestamp passed in Updates (got '$($updatedTask.analysis_started_at)')"

    Assert-Equal -Name "Move-TaskState applies arbitrary custom field" `
        -Expected "hello" -Actual $updatedTask.custom_field

    Write-Host ""
    Write-Host "  MOVE-TASKSTATE: IDEMPOTENT" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    New-SimpleTaskFile -Dir $todoDir -Id "ts-idempotent-01" -Name "Idempotent test" | Out-Null
    Move-TaskState -TaskId "ts-idempotent-01" -FromStates @("todo") -ToState "analysing" | Out-Null

    $idempResult = Move-TaskState -TaskId "ts-idempotent-01" -FromStates @("todo") -ToState "analysing"

    Assert-True -Name "Move-TaskState already_in_state=true when already in target" `
        -Condition ($idempResult.already_in_state -eq $true) -Message "Expected already_in_state=true"

    Assert-Equal -Name "Move-TaskState idempotent result has correct new_status" `
        -Expected "analysing" -Actual $idempResult.new_status

    Write-Host ""
    Write-Host "  MOVE-TASKSTATE: VALIDATION" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    New-SimpleTaskFile -Dir $todoDir -Id "ts-validate-01" -Name "Validation test" | Out-Null

    $threw = $false
    try {
        Move-TaskState -TaskId "ts-validate-01" -FromStates @("in-progress") -ToState "done" | Out-Null
    } catch {
        $threw = $true
    }
    Assert-True -Name "Move-TaskState throws when task not found in FromStates" `
        -Condition $threw -Message "Expected exception when task not in allowed FromStates"

    $threw2 = $false
    try {
        Move-TaskState -TaskId "ts-nonexistent-999" -FromStates @("todo") -ToState "analysing" | Out-Null
    } catch {
        $threw2 = $true
    }
    Assert-True -Name "Move-TaskState throws for completely unknown task ID" `
        -Condition $threw2 -Message "Expected exception for unknown task ID"

    $threw3 = $false
    try {
        Move-TaskState -TaskId "ts-validate-01" -FromStates @("todo") -ToState "invalid-state-xyz" | Out-Null
    } catch {
        $threw3 = $true
    }
    Assert-True -Name "Move-TaskState throws for invalid ToState name" `
        -Condition $threw3 -Message "Expected exception for unknown state name"

    $threw4 = $false
    try {
        Move-TaskState -TaskId "ts-validate-01" -FromStates @("not-a-state") -ToState "todo" | Out-Null
    } catch {
        $threw4 = $true
    }
    Assert-True -Name "Move-TaskState throws for invalid FromStates name" `
        -Condition $threw4 -Message "Expected exception for unknown state name in FromStates"

    Write-Host ""
    Write-Host "  MOVE-TASKSTATE: RESERVED KEYS IN UPDATES" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    New-SimpleTaskFile -Dir $todoDir -Id "ts-reserved-01" -Name "Reserved keys test" | Out-Null

    $result3 = Move-TaskState -TaskId "ts-reserved-01" -FromStates @("todo") -ToState "analysing" `
        -Updates @{ status = "done"; id = "hijacked"; created_at = "1970-01-01T00:00:00Z"; custom = "ok" }

    $reservedTask = Get-Content $result3.new_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "Move-TaskState ignores reserved 'status' key in Updates" `
        -Expected "analysing" -Actual $reservedTask.status
    Assert-Equal -Name "Move-TaskState ignores reserved 'id' key in Updates" `
        -Expected "ts-reserved-01" -Actual $reservedTask.id
    Assert-True  -Name "Move-TaskState ignores reserved 'created_at' key in Updates" `
        -Condition ($reservedTask.created_at -ne "1970-01-01T00:00:00Z") `
        -Message "Expected created_at to remain unchanged"
    Assert-Equal -Name "Move-TaskState still applies non-reserved keys alongside reserved ones" `
        -Expected "ok" -Actual $reservedTask.custom

    Write-Host ""
    Write-Host "  MOVE-TASKSTATE: MULTI-HOP" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    New-SimpleTaskFile -Dir $todoDir -Id "ts-multihop-01" -Name "Multi-hop test" | Out-Null

    Move-TaskState -TaskId "ts-multihop-01" -FromStates @("todo")      -ToState "analysing" | Out-Null
    Move-TaskState -TaskId "ts-multihop-01" -FromStates @("analysing") -ToState "analysed"  | Out-Null
    $inpResult = Move-TaskState -TaskId "ts-multihop-01" -FromStates @("analysed", "todo") -ToState "in-progress"

    Assert-Equal -Name "Multi-hop: task reaches in-progress from analysed" `
        -Expected "in-progress" -Actual $inpResult.new_status

    $inProgressDir = Join-Path $tasksBaseDir "in-progress"
    Assert-PathExists -Name "Multi-hop: task file present in in-progress directory" `
        -Path (Join-Path $inProgressDir "ts-multihop-01.json")

    $doneResult = Move-TaskState -TaskId "ts-multihop-01" -FromStates @("todo", "in-progress") -ToState "done" `
        -Updates @{ completed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

    Assert-Equal -Name "Multi-hop: task reaches done from in-progress" `
        -Expected "done" -Actual $doneResult.new_status

    $doneDir  = Join-Path $tasksBaseDir "done"
    $doneTask = Get-Content (Join-Path $doneDir "ts-multihop-01.json") -Raw | ConvertFrom-Json
    Assert-True -Name "Multi-hop: done task has completed_at set" `
        -Condition ($null -ne $doneTask.completed_at -and $doneTask.completed_at -ne "") `
        -Message "Expected completed_at to be set"

    Write-Host ""
    Write-Host "  GET-TASKBYIDORSLUG" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    New-SimpleTaskFile -Dir $todoDir -Id "ts-lookup-01" -Name "Lookup By Slug Test" | Out-Null

    $byId = Get-TaskByIdOrSlug -Identifier "ts-lookup-01"
    Assert-True  -Name "Get-TaskByIdOrSlug finds task by exact ID"  -Condition ($null -ne $byId)
    Assert-Equal -Name "Get-TaskByIdOrSlug ID lookup returns correct task" `
        -Expected "ts-lookup-01" -Actual $byId.task.id

    $byName = Get-TaskByIdOrSlug -Identifier "Lookup By Slug Test"
    Assert-True  -Name "Get-TaskByIdOrSlug finds task by exact name" -Condition ($null -ne $byName)
    Assert-Equal -Name "Get-TaskByIdOrSlug name lookup returns correct task" `
        -Expected "ts-lookup-01" -Actual $byName.task.id

    $bySlug = Get-TaskByIdOrSlug -Identifier "lookup-by-slug-test"
    Assert-True  -Name "Get-TaskByIdOrSlug finds task by slug" -Condition ($null -ne $bySlug)
    Assert-Equal -Name "Get-TaskByIdOrSlug slug lookup returns correct task" `
        -Expected "ts-lookup-01" -Actual $bySlug.task.id

    Assert-True  -Name "Get-TaskByIdOrSlug result contains file_path" `
        -Condition ($null -ne $byId.file_path -and $byId.file_path -ne "") `
        -Message "Expected file_path to be populated in result"

    Assert-True  -Name "Get-TaskByIdOrSlug result contains status" `
        -Condition ($null -ne $byId.status -and $byId.status -ne "") `
        -Message "Expected status to be populated in result"

    $missing = Get-TaskByIdOrSlug -Identifier "definitely-not-a-task-9999"
    Assert-True -Name "Get-TaskByIdOrSlug returns null for unknown identifier" `
        -Condition ($null -eq $missing) -Message "Expected null for unknown identifier"

    [ordered]@{
        id = "ts-lookup-done"; name = "Done lookup task"; status = "done"
        category = "feature"; priority = 10; effort = "S"
        created_at = "2026-01-01T00:00:00Z"; updated_at = "2026-01-01T00:00:00Z"
    } | ConvertTo-Json | Set-Content -Path (Join-Path $doneDir "ts-lookup-done.json") -Encoding UTF8

    $foundDone = Get-TaskByIdOrSlug -Identifier "ts-lookup-done"
    Assert-True  -Name "Get-TaskByIdOrSlug finds tasks in non-todo directories" -Condition ($null -ne $foundDone)
    Assert-Equal -Name "Get-TaskByIdOrSlug reports correct status for done task" `
        -Expected "done" -Actual $foundDone.status

    Write-Host ""
    Write-Host "  NEW-TASKRECORD" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    $newResult = New-TaskRecord -Properties @{
        id          = "ts-new-01"
        name        = "New record task"
        description = "Created via New-TaskRecord"
        category    = "feature"
    }

    Assert-True  -Name "New-TaskRecord returns result with file_path" `
        -Condition ($null -ne $newResult -and $null -ne $newResult.file_path)
    Assert-PathExists -Name "New-TaskRecord creates JSON file in todo directory" -Path $newResult.file_path

    $newTask = Get-Content $newResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "New-TaskRecord sets status to todo by default" `
        -Expected "todo" -Actual $newTask.status
    Assert-True  -Name "New-TaskRecord sets created_at" `
        -Condition ($null -ne $newTask.created_at -and $newTask.created_at -ne "")
    Assert-Equal -Name "New-TaskRecord sets priority default (50)" `
        -Expected 50 -Actual $newTask.priority
    Assert-Equal -Name "New-TaskRecord sets effort default (M)" `
        -Expected "M" -Actual $newTask.effort

    $autoIdResult = New-TaskRecord -Properties @{ name = "Auto ID task"; category = "feature" }
    Assert-True -Name "New-TaskRecord auto-generates ID when not provided" `
        -Condition ($null -ne $autoIdResult.task.id -and $autoIdResult.task.id -ne "")

    $overrideResult = New-TaskRecord -Properties @{
        id       = "ts-override-01"
        name     = "Override defaults task"
        category = "feature"
        priority = 99
        effort   = "XL"
    }
    $overrideTask = Get-Content $overrideResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "New-TaskRecord caller priority overrides default (50)" `
        -Expected 99 -Actual $overrideTask.priority
    Assert-Equal -Name "New-TaskRecord caller effort overrides default (M)" `
        -Expected "XL" -Actual $overrideTask.effort

    Write-Host ""
    Write-Host "  MOVE-TASKSTATE: CANCELLED AND SPLIT STATES" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    New-SimpleTaskFile -Dir $todoDir -Id "ts-cancel-01" -Name "Cancel test" | Out-Null
    $cancelResult = Move-TaskState -TaskId "ts-cancel-01" -FromStates @("todo") -ToState "cancelled"
    Assert-Equal -Name "Move-TaskState can move task to cancelled state" `
        -Expected "cancelled" -Actual $cancelResult.new_status

    $cancelledDir = Join-Path $tasksBaseDir "cancelled"
    Assert-PathExists -Name "Cancelled task file exists in cancelled directory" `
        -Path (Join-Path $cancelledDir "ts-cancel-01.json")

    New-SimpleTaskFile -Dir $todoDir -Id "ts-split-01" -Name "Split test" | Out-Null
    $splitResult = Move-TaskState -TaskId "ts-split-01" -FromStates @("todo") -ToState "split"
    Assert-Equal -Name "Move-TaskState can move task to split state" `
        -Expected "split" -Actual $splitResult.new_status

    $splitDir = Join-Path $tasksBaseDir "split"
    Assert-PathExists -Name "Split task file exists in split directory" `
        -Path (Join-Path $splitDir "ts-split-01.json")

    Write-Host ""
    Write-Host "  UPDATE-TASKRECORD" -ForegroundColor Cyan
    Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

    New-SimpleTaskFile -Dir $todoDir -Id "ts-update-01" -Name "Update record test" | Out-Null

    $updateResult = Update-TaskRecord -TaskId "ts-update-01" -Updates @{
        description = "Updated description"
        priority    = 5
    }

    Assert-True -Name "Update-TaskRecord returns result with file_path" `
        -Condition ($null -ne $updateResult -and $null -ne $updateResult.file_path)

    $updatedFile = Get-Content $updateResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "Update-TaskRecord persists description change" `
        -Expected "Updated description" -Actual $updatedFile.description
    Assert-Equal -Name "Update-TaskRecord persists priority change" `
        -Expected 5 -Actual $updatedFile.priority
    Assert-True  -Name "Update-TaskRecord refreshes updated_at" `
        -Condition ($updatedFile.updated_at -ne "2026-01-01T00:00:00Z")

    Update-TaskRecord -TaskId "ts-update-01" -Updates @{ id = "should-not-change" } | Out-Null
    $afterBlockedUpdate = Get-Content $updateResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "Update-TaskRecord does not overwrite protected id field" `
        -Expected "ts-update-01" -Actual $afterBlockedUpdate.id

    New-SimpleTaskFile -Dir $todoDir -Id "ts-update-done-01" -Name "Update done task" | Out-Null
    Move-TaskState -TaskId "ts-update-done-01" -FromStates @("todo") -ToState "done" | Out-Null

    $updateDoneResult = Update-TaskRecord -TaskId "ts-update-done-01" -Updates @{ notes = "Post-completion note" }
    $doneUpdated = Get-Content $updateDoneResult.file_path -Raw | ConvertFrom-Json
    Assert-Equal -Name "Update-TaskRecord updates task in done directory" `
        -Expected "Post-completion note" -Actual $doneUpdated.notes

    $updateThrew = $false
    try {
        Update-TaskRecord -TaskId "ts-nonexistent-update-999" -Updates @{ description = "ghost" } | Out-Null
    } catch {
        $updateThrew = $true
    }
    Assert-True -Name "Update-TaskRecord throws for unknown task ID" `
        -Condition $updateThrew -Message "Expected exception for unknown task ID"

} finally {
    if ($testProject) {
        Remove-TestProject -Path $testProject
    }
}

$allPassed = Write-TestSummary -LayerName "TaskStore Tests"

if (-not $allPassed) {
    exit 1
}
exit 0
