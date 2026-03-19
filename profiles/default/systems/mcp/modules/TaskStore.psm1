<#
.SYNOPSIS
TaskStore - atomic task state transitions and CRUD operations

.DESCRIPTION
Centralises task filesystem I/O. All task-mark-* tools use Move-TaskState
for validated, atomic state transitions.
#>

$script:ValidStatuses = @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'split', 'skipped', 'cancelled')

function Get-TaskStoreBaseDir {
    if ($global:DotbotProjectRoot) {
        return Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    }
    throw "DotbotProjectRoot global variable not set"
}

function Find-TaskFile {
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string[]]$InStatuses,
        [Parameter(Mandatory)] [string]$BaseDir
    )

    foreach ($status in $InStatuses) {
        $dir = Join-Path $BaseDir $status
        if (-not (Test-Path $dir)) { continue }

        foreach ($file in (Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $TaskId) {
                    return @{
                        File    = $file
                        Content = $content
                        Status  = $status
                    }
                }
            } catch { }
        }
    }

    return $null
}

function Set-OrAddProperty {
    param(
        [Parameter(Mandatory)] [psobject]$Object,
        [Parameter(Mandatory)] [string]$Name,
        $Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Move-TaskState {
    <#
    .SYNOPSIS
    Atomically moves a task from one state directory to another.

    .DESCRIPTION
    Finds the task file in one of the allowed FromStates directories, applies
    standard field updates (status, updated_at) plus any caller-supplied Updates,
    writes to the ToState directory, and removes the old file.

    Returns a hashtable: task, old_status, new_status, old_path, new_path, already_in_state.

    For post-move mutations (e.g. session tracking), the caller may write
    additional fields back to new_path using the returned task object.
    #>
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [string[]]$FromStates,
        [Parameter(Mandatory)] [string]$ToState,
        [hashtable]$Updates = @{}
    )

    $baseDir = Get-TaskStoreBaseDir

    # Idempotent: already in target state
    $existing = Find-TaskFile -TaskId $TaskId -InStatuses @($ToState) -BaseDir $baseDir
    if ($existing) {
        return @{
            task             = $existing.Content
            old_status       = $ToState
            new_status       = $ToState
            old_path         = $existing.File.FullName
            new_path         = $existing.File.FullName
            already_in_state = $true
        }
    }

    # Find in allowed source states
    $found = Find-TaskFile -TaskId $TaskId -InStatuses $FromStates -BaseDir $baseDir
    if (-not $found) {
        throw "Task '$TaskId' not found in state(s): $($FromStates -join ', ')"
    }

    $task    = $found.Content
    $oldPath = $found.File.FullName

    # Standard fields
    Set-OrAddProperty -Object $task -Name 'status'     -Value $ToState
    Set-OrAddProperty -Object $task -Name 'updated_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))

    # Caller-supplied updates (merged in)
    foreach ($key in $Updates.Keys) {
        Set-OrAddProperty -Object $task -Name $key -Value $Updates[$key]
    }

    # Ensure target directory
    $targetDir = Join-Path $baseDir $ToState
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }

    $newPath = Join-Path $targetDir $found.File.Name

    # Write to target then remove source
    $task | ConvertTo-Json -Depth 20 | Set-Content -Path $newPath -Encoding UTF8
    if ([System.IO.Path]::GetFullPath($oldPath) -ne [System.IO.Path]::GetFullPath($newPath)) {
        Remove-Item -Path $oldPath -Force
    }

    return @{
        task             = $task
        old_status       = $found.Status
        new_status       = $ToState
        old_path         = $oldPath
        new_path         = $newPath
        already_in_state = $false
    }
}

function Get-TaskByIdOrSlug {
    <#
    .SYNOPSIS
    Finds a task across all status directories by ID, name, or slug.
    #>
    param(
        [Parameter(Mandatory)] [string]$Identifier
    )

    $baseDir         = Get-TaskStoreBaseDir
    $identifierLower = $Identifier.ToLower()

    foreach ($status in $script:ValidStatuses) {
        $dir = Join-Path $baseDir $status
        if (-not (Test-Path $dir)) { continue }

        foreach ($file in (Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json

                if ($content.id -eq $Identifier) {
                    return @{ task = $content; status = $status; file_path = $file.FullName }
                }

                if ($content.name -and $content.name.ToLower() -eq $identifierLower) {
                    return @{ task = $content; status = $status; file_path = $file.FullName }
                }

                if ($content.name) {
                    $slug = (($content.name -replace '[^a-zA-Z0-9\s-]', '' -replace '\s+', '-').ToLower())
                    if ($slug -eq $identifierLower) {
                        return @{ task = $content; status = $status; file_path = $file.FullName }
                    }
                }
            } catch { }
        }
    }

    return $null
}

function New-TaskRecord {
    <#
    .SYNOPSIS
    Creates a new task JSON file in the todo directory with sensible defaults.
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$Properties
    )

    $baseDir = Get-TaskStoreBaseDir
    $todoDir = Join-Path $baseDir "todo"
    $now     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    if (-not $Properties['id']) {
        $Properties['id'] = [guid]::NewGuid().ToString("N").Substring(0, 8)
    }

    $defaults = @{
        status               = 'todo'
        created_at           = $now
        updated_at           = $now
        priority             = 50
        effort               = 'M'
        dependencies         = @()
        acceptance_criteria  = @()
    }

    foreach ($key in $defaults.Keys) {
        if (-not $Properties.ContainsKey($key)) {
            $Properties[$key] = $defaults[$key]
        }
    }

    $task = [PSCustomObject]$Properties

    if (-not (Test-Path $todoDir)) {
        New-Item -ItemType Directory -Force -Path $todoDir | Out-Null
    }

    $filePath = Join-Path $todoDir "$($Properties['id']).json"
    $task | ConvertTo-Json -Depth 20 | Set-Content -Path $filePath -Encoding UTF8

    return @{
        task      = $task
        file_path = $filePath
    }
}

function Update-TaskRecord {
    <#
    .SYNOPSIS
    Merge-updates a task in whatever directory it currently lives in.
    #>
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [hashtable]$Updates
    )

    $found = Get-TaskByIdOrSlug -Identifier $TaskId
    if (-not $found) {
        throw "Task '$TaskId' not found"
    }

    $task           = $found.task
    $blockedFields  = @('id', 'created_at')

    foreach ($key in $Updates.Keys) {
        if ($key -in $blockedFields) { continue }
        Set-OrAddProperty -Object $task -Name $key -Value $Updates[$key]
    }

    Set-OrAddProperty -Object $task -Name 'updated_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    $task | ConvertTo-Json -Depth 20 | Set-Content -Path $found.file_path -Encoding UTF8

    return @{
        task      = $task
        file_path = $found.file_path
    }
}

Export-ModuleMember -Function @(
    'Move-TaskState',
    'Get-TaskByIdOrSlug',
    'New-TaskRecord',
    'Update-TaskRecord'
)
