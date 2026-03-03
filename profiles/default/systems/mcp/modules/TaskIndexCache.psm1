<#
.SYNOPSIS
Task index module - reads task files fresh on each access

.DESCRIPTION
Provides functions to query tasks from the filesystem.
No caching - always reads fresh data to avoid stale state issues.
#>

$script:TaskIndex = @{
    Todo = @{}          # id -> task metadata
    Analysing = @{}     # Tasks currently being analysed
    NeedsInput = @{}    # Tasks waiting for human input
    Analysed = @{}      # Tasks ready for implementation
    InProgress = @{}
    Done = @{}
    Split = @{}         # Tasks that were split into sub-tasks
    Skipped = @{}       # Tasks that were skipped
    Cancelled = @{}     # Tasks that were cancelled
    DoneIds = @()       # Quick lookup for dependency checking (by id)
    DoneNames = @()     # Quick lookup for dependency checking (by name)
    DoneSlugs = @()     # Quick lookup for dependency checking (by slug)
    BaseDir = $null
}

function Initialize-TaskIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TasksBaseDir
    )

    # Ensure directory exists
    if (-not (Test-Path $TasksBaseDir)) {
        New-Item -Path $TasksBaseDir -ItemType Directory -Force | Out-Null
    }

    $script:TaskIndex.BaseDir = $TasksBaseDir
}

function Update-TaskIndex {
    $baseDir = $script:TaskIndex.BaseDir
    if (-not $baseDir) {
        Write-Verbose "[TaskIndex] BaseDir not set, skipping update"
        return
    }

    $script:TaskIndex.Todo = @{}
    $script:TaskIndex.Analysing = @{}
    $script:TaskIndex.NeedsInput = @{}
    $script:TaskIndex.Analysed = @{}
    $script:TaskIndex.InProgress = @{}
    $script:TaskIndex.Done = @{}
    $script:TaskIndex.Split = @{}
    $script:TaskIndex.Skipped = @{}
    $script:TaskIndex.Cancelled = @{}
    $script:TaskIndex.DoneIds = @()
    $script:TaskIndex.DoneNames = @()
    $script:TaskIndex.DoneSlugs = @()

    foreach ($status in @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'split', 'skipped', 'cancelled')) {
        $dir = Join-Path $baseDir $status
        if (-not (Test-Path $dir)) {
            continue
        }

        $files = Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue

        foreach ($file in $files) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                $entry = @{
                    id = $content.id
                    name = $content.name
                    description = $content.description
                    category = $content.category
                    priority = [int]$content.priority
                    effort = $content.effort
                    dependencies = $content.dependencies
                    acceptance_criteria = $content.acceptance_criteria
                    steps = $content.steps
                    applicable_agents = $content.applicable_agents
                    applicable_standards = $content.applicable_standards
                    file_path = $file.FullName
                    last_write = $file.LastWriteTimeUtc
                    started_at = $content.started_at
                    completed_at = $content.completed_at
                    needs_interview = $content.needs_interview
                    working_dir = $content.working_dir
                    external_repo = $content.external_repo
                    research_prompt = $content.research_prompt
                }

                switch ($status) {
                    'todo' { $script:TaskIndex.Todo[$content.id] = $entry }
                    'analysing' { $script:TaskIndex.Analysing[$content.id] = $entry }
                    'needs-input' { $script:TaskIndex.NeedsInput[$content.id] = $entry }
                    'analysed' { $script:TaskIndex.Analysed[$content.id] = $entry }
                    'in-progress' { $script:TaskIndex.InProgress[$content.id] = $entry }
                    'done' {
                        $script:TaskIndex.Done[$content.id] = $entry
                        $script:TaskIndex.DoneIds += $content.id
                        $script:TaskIndex.DoneNames += $content.name
                        # Also store slug version of name for dependency matching
                        $slug = ($content.name -replace '[^a-zA-Z0-9\s-]', '' -replace '\s+', '-').ToLower()
                        $script:TaskIndex.DoneSlugs += $slug
                    }
                    'split' {
                        $script:TaskIndex.Split[$content.id] = $entry
                        # Split tasks satisfy dependencies — work delegated to sub-tasks
                        $script:TaskIndex.DoneIds += $content.id
                        $script:TaskIndex.DoneNames += $content.name
                        $slug = ($content.name -replace '[^a-zA-Z0-9\s-]', '' -replace '\s+', '-').ToLower()
                        $script:TaskIndex.DoneSlugs += $slug
                    }
                    'skipped' { $script:TaskIndex.Skipped[$content.id] = $entry }
                    'cancelled' { $script:TaskIndex.Cancelled[$content.id] = $entry }
                }
            } catch {
                Write-Warning "[TaskIndex] Failed to read: $($file.FullName) - $_"
            }
        }
    }

    # Dedup: if a task exists in multiple state directories (stale copies),
    # keep only the most advanced state to prevent double-pickup
    $seenIds = @{}
    foreach ($bucket in @(
        $script:TaskIndex.Done,
        $script:TaskIndex.Skipped,
        $script:TaskIndex.Cancelled,
        $script:TaskIndex.Split,
        $script:TaskIndex.InProgress,
        $script:TaskIndex.Analysed,
        $script:TaskIndex.NeedsInput,
        $script:TaskIndex.Analysing,
        $script:TaskIndex.Todo
    )) {
        foreach ($taskId in @($bucket.Keys)) {
            if ($seenIds.ContainsKey($taskId)) {
                $bucket.Remove($taskId)
            } else {
                $seenIds[$taskId] = $true
            }
        }
    }
}

function Get-TaskIndex {
    # Always rebuild - no caching
    Update-TaskIndex
    return $script:TaskIndex
}

function Get-TodoTasks {
    param(
        [string]$Category,
        [string]$Effort,
        [int]$MinPriority,
        [int]$MaxPriority,
        [int]$Limit = 0
    )

    $index = Get-TaskIndex
    $tasks = @($index.Todo.Values)

    if ($Category) {
        $tasks = $tasks | Where-Object { $_.category -eq $Category }
    }

    if ($Effort) {
        $tasks = $tasks | Where-Object { $_.effort -eq $Effort }
    }

    if ($MinPriority -gt 0) {
        $tasks = $tasks | Where-Object { $_.priority -ge $MinPriority }
    }

    if ($MaxPriority -gt 0) {
        $tasks = $tasks | Where-Object { $_.priority -le $MaxPriority }
    }

    $tasks = $tasks | Sort-Object priority

    if ($Limit -gt 0) {
        $tasks = $tasks | Select-Object -First $Limit
    }

    return @($tasks)
}

function Get-InProgressTasks {
    $index = Get-TaskIndex
    return @($index.InProgress.Values)
}

function Get-AnalysingTasks {
    $index = Get-TaskIndex
    return @($index.Analysing.Values)
}

function Get-NeedsInputTasks {
    $index = Get-TaskIndex
    return @($index.NeedsInput.Values)
}

function Get-AnalysedTasks {
    param(
        [int]$Limit = 0
    )

    $index = Get-TaskIndex
    $tasks = @($index.Analysed.Values) | Sort-Object priority

    if ($Limit -gt 0) {
        $tasks = $tasks | Select-Object -First $Limit
    }

    return @($tasks)
}

function Get-SplitTasks {
    $index = Get-TaskIndex
    return @($index.Split.Values)
}

function Get-SkippedTasks {
    $index = Get-TaskIndex
    return @($index.Skipped.Values)
}

function Get-CancelledTasks {
    $index = Get-TaskIndex
    return @($index.Cancelled.Values)
}

function Get-DoneTasks {
    param(
        [int]$Limit = 0
    )

    $index = Get-TaskIndex
    $tasks = @($index.Done.Values) | Sort-Object { [DateTime]$_.completed_at } -Descending

    if ($Limit -gt 0) {
        $tasks = $tasks | Select-Object -First $Limit
    }

    return @($tasks)
}

function Get-AllTasks {
    param(
        [string]$Status,
        [string]$Category,
        [string]$Effort,
        [int]$MinPriority,
        [int]$MaxPriority,
        [int]$Limit = 0
    )

    $index = Get-TaskIndex
    $tasks = @()

    # Determine which collections to include
    if (-not $Status -or $Status -eq 'todo') {
        $tasks += @($index.Todo.Values)
    }
    if (-not $Status -or $Status -eq 'analysing') {
        $tasks += @($index.Analysing.Values)
    }
    if (-not $Status -or $Status -eq 'needs-input') {
        $tasks += @($index.NeedsInput.Values)
    }
    if (-not $Status -or $Status -eq 'analysed') {
        $tasks += @($index.Analysed.Values)
    }
    if (-not $Status -or $Status -eq 'in-progress') {
        $tasks += @($index.InProgress.Values)
    }
    if (-not $Status -or $Status -eq 'done') {
        $tasks += @($index.Done.Values)
    }
    if (-not $Status -or $Status -eq 'split') {
        $tasks += @($index.Split.Values)
    }
    if (-not $Status -or $Status -eq 'skipped') {
        $tasks += @($index.Skipped.Values)
    }
    if (-not $Status -or $Status -eq 'cancelled') {
        $tasks += @($index.Cancelled.Values)
    }

    # Apply filters
    if ($Category) {
        $tasks = $tasks | Where-Object { $_.category -eq $Category }
    }

    if ($Effort) {
        $tasks = $tasks | Where-Object { $_.effort -eq $Effort }
    }

    if ($MinPriority -gt 0) {
        $tasks = $tasks | Where-Object { $_.priority -ge $MinPriority }
    }

    if ($MaxPriority -gt 0) {
        $tasks = $tasks | Where-Object { $_.priority -le $MaxPriority }
    }

    $tasks = $tasks | Sort-Object priority

    if ($Limit -gt 0) {
        $tasks = $tasks | Select-Object -First $Limit
    }

    return @($tasks)
}

function Test-DependencyMet {
    param(
        [string]$Dependency,
        [array]$DoneNames,
        [array]$DoneSlugs,
        [array]$DoneIds
    )
    
    $depLower = $Dependency.ToLower()
    
    # Exact match on ID
    if ($Dependency -in $DoneIds) { return $true }
    
    # Exact match on name
    if ($Dependency -in $DoneNames) { return $true }
    
    # Exact match on slug
    if ($depLower -in $DoneSlugs) { return $true }
    
    # No fuzzy matching - dependencies must be exact
    # If a dependency doesn't exist, the task should not proceed
    return $false
}

function Test-AllDependenciesMet {
    param(
        [object]$Task,
        [array]$DoneNames,
        [array]$DoneSlugs,
        [array]$DoneIds
    )

    if (-not $Task.dependencies -or $Task.dependencies.Count -eq 0) {
        return $true
    }
    # Handle both string and array dependencies
    $deps = if ($Task.dependencies -is [array]) { $Task.dependencies } else { @($Task.dependencies) }
    $unmet = $deps | Where-Object {
        -not (Test-DependencyMet -Dependency $_ -DoneNames $DoneNames -DoneSlugs $DoneSlugs -DoneIds $DoneIds)
    }
    return $unmet.Count -eq 0
}

function Get-NextTask {
    $index = Get-TaskIndex
    $doneNames = $index.DoneNames
    $doneSlugs = $index.DoneSlugs
    $doneIds = $index.DoneIds

    # Filter tasks with unmet dependencies
    $eligible = @($index.Todo.Values) | Where-Object {
        Test-AllDependenciesMet -Task $_ -DoneNames $doneNames -DoneSlugs $doneSlugs -DoneIds $doneIds
    }

    # Return highest priority (lowest number)
    return $eligible | Sort-Object priority | Select-Object -First 1
}

function Get-NextAnalysedTask {
    $index = Get-TaskIndex
    $doneNames = $index.DoneNames
    $doneSlugs = $index.DoneSlugs
    $doneIds = $index.DoneIds

    # Filter analysed tasks with unmet dependencies
    $eligible = @($index.Analysed.Values) | Where-Object {
        Test-AllDependenciesMet -Task $_ -DoneNames $doneNames -DoneSlugs $doneSlugs -DoneIds $doneIds
    }

    $total = @($index.Analysed.Values).Count
    $blockedCount = $total - @($eligible).Count

    # Return highest priority (lowest number) + blocked count for reporting
    $next = $eligible | Sort-Object priority | Select-Object -First 1
    return @{
        Task = $next
        BlockedCount = $blockedCount
        TotalCount = $total
    }
}

function Test-TaskDone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId
    )

    $index = Get-TaskIndex
    return $TaskId -in $index.DoneIds
}

function Get-TaskById {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId
    )

    $index = Get-TaskIndex

    if ($index.Todo.ContainsKey($TaskId)) {
        return $index.Todo[$TaskId]
    }
    if ($index.Analysing.ContainsKey($TaskId)) {
        return $index.Analysing[$TaskId]
    }
    if ($index.NeedsInput.ContainsKey($TaskId)) {
        return $index.NeedsInput[$TaskId]
    }
    if ($index.Analysed.ContainsKey($TaskId)) {
        return $index.Analysed[$TaskId]
    }
    if ($index.InProgress.ContainsKey($TaskId)) {
        return $index.InProgress[$TaskId]
    }
    if ($index.Done.ContainsKey($TaskId)) {
        return $index.Done[$TaskId]
    }
    if ($index.Split.ContainsKey($TaskId)) {
        return $index.Split[$TaskId]
    }
    if ($index.Skipped.ContainsKey($TaskId)) {
        return $index.Skipped[$TaskId]
    }
    if ($index.Cancelled.ContainsKey($TaskId)) {
        return $index.Cancelled[$TaskId]
    }

    return $null
}

function Get-TaskStats {
    $index = Get-TaskIndex

    $stats = @{
        total = $index.Todo.Count + $index.Analysing.Count + $index.NeedsInput.Count + $index.Analysed.Count + $index.InProgress.Count + $index.Done.Count + $index.Split.Count + $index.Skipped.Count + $index.Cancelled.Count
        todo = $index.Todo.Count
        analysing = $index.Analysing.Count
        needs_input = $index.NeedsInput.Count
        analysed = $index.Analysed.Count
        in_progress = $index.InProgress.Count
        done = $index.Done.Count
        split = $index.Split.Count
        skipped = $index.Skipped.Count
        cancelled = $index.Cancelled.Count
        by_category = @{}
        by_effort = @{}
        by_priority_range = @{
            high = 0      # 1-20
            medium = 0    # 21-50
            low = 0       # 51-100
        }
    }

    $allTasks = @($index.Todo.Values) + @($index.Analysing.Values) + @($index.NeedsInput.Values) + @($index.Analysed.Values) + @($index.InProgress.Values) + @($index.Done.Values) + @($index.Skipped.Values) + @($index.Cancelled.Values)

    foreach ($task in $allTasks) {
        # Count by category
        if ($task.category) {
            if (-not $stats.by_category[$task.category]) {
                $stats.by_category[$task.category] = 0
            }
            $stats.by_category[$task.category]++
        }

        # Count by effort
        if ($task.effort) {
            if (-not $stats.by_effort[$task.effort]) {
                $stats.by_effort[$task.effort] = 0
            }
            $stats.by_effort[$task.effort]++
        }

        # Count by priority range
        if ($task.priority) {
            $priority = [int]$task.priority
            if ($priority -le 20) {
                $stats.by_priority_range.high++
            } elseif ($priority -le 50) {
                $stats.by_priority_range.medium++
            } else {
                $stats.by_priority_range.low++
            }
        }
    }

    return $stats
}

function Get-RemainingEffort {
    $index = Get-TaskIndex

    $effort_mapping = @{
        'XS' = 1
        'S' = 2.5
        'M' = 5
        'L' = 10
        'XL' = 15
    }

    $days_remaining = 0
    # Include all tasks that still need work (not done or split)
    $allRemaining = @($index.Todo.Values) + @($index.Analysing.Values) + @($index.NeedsInput.Values) + @($index.Analysed.Values) + @($index.InProgress.Values)

    foreach ($task in $allRemaining) {
        if ($task.effort -and $effort_mapping[$task.effort]) {
            $days_remaining += $effort_mapping[$task.effort]
        } else {
            $days_remaining += 5  # Default to M if not specified
        }
    }

    return [Math]::Round($days_remaining, 1)
}

# Keep for backwards compatibility but now a no-op
function Reset-TaskIndex {
    # No-op - index is always fresh
}

# Keep for backwards compatibility but now a no-op
function Stop-TaskIndexWatcher {
    # No-op - no watcher to stop
}

Export-ModuleMember -Function @(
    'Initialize-TaskIndex',
    'Update-TaskIndex',
    'Get-TaskIndex',
    'Get-TodoTasks',
    'Get-AnalysingTasks',
    'Get-NeedsInputTasks',
    'Get-AnalysedTasks',
    'Get-InProgressTasks',
    'Get-DoneTasks',
    'Get-SplitTasks',
    'Get-SkippedTasks',
    'Get-CancelledTasks',
    'Get-AllTasks',
    'Get-NextTask',
    'Get-NextAnalysedTask',
    'Test-TaskDone',
    'Test-DependencyMet',
    'Test-AllDependenciesMet',
    'Get-TaskById',
    'Get-TaskStats',
    'Get-RemainingEffort',
    'Reset-TaskIndex',
    'Stop-TaskIndexWatcher'
)
