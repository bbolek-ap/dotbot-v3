<#
.SYNOPSIS
Unified structured logging module for dotbot

.DESCRIPTION
Single logging module for all dotbot structured logging.

Outputs JSONL to .bot/.control/logs/dotbot-{date}.jsonl with time-based rotation.
Info+ events also flow to activity.jsonl for backward compatibility.

Each line: {ts, level, msg, process_id, task_id, phase, pid, error, stack, ...context}

Levels (ascending severity): Debug, Info, Warn, Error, Fatal
#>

# --- Level ordinals ---
$script:LevelOrdinals = @{
    Debug = 0
    Info  = 1
    Warn  = 2
    Error = 3
    Fatal = 4
}

# --- Configuration ---
$script:LogConfig = @{
    LogDir         = $null
    MinLevel       = 'Info'
    ConsoleLevel   = 'Info'
    FileLevel      = 'Debug'
    RetentionDays  = 7
    MaxFileSizeMB  = 50
    MaxRetries     = 3
    RetryBaseMs    = 50
    ControlDir     = $null
    Initialized    = $false
}

# --- Public: Initialize logging ---
function Initialize-DotBotLog {
    <#
    .SYNOPSIS
    Initializes the structured logging system.

    .PARAMETER LogDir
    Directory for log files. Defaults to .bot/.control/logs/.

    .PARAMETER MinLevel
    Minimum level to write. Defaults to 'Info'.
    #>
    [CmdletBinding()]
    param(
        [string]$LogDir,
        [ValidateSet('Debug', 'Info', 'Warn', 'Error', 'Fatal')]
        [string]$MinLevel = 'Info'
    )

    if ($LogDir) {
        $script:LogConfig.LogDir = $LogDir
    }
    $script:LogConfig.MinLevel = $MinLevel

    # Try to load logging settings from settings files
    $controlDir = Get-BotControlDir
    if ($controlDir) {
        $script:LogConfig.ControlDir = $controlDir
        $botRoot = Split-Path -Parent (Split-Path -Parent $controlDir)
        $settingsPath = Join-Path $controlDir "settings.json"
        $defaultSettingsPath = Join-Path $botRoot "defaults\settings.default.json"

        foreach ($path in @($defaultSettingsPath, $settingsPath)) {
            if (Test-Path $path) {
                try {
                    $settings = Get-Content $path -Raw | ConvertFrom-Json
                    if ($settings.logging) {
                        if ($settings.logging.console_level) { $script:LogConfig.ConsoleLevel = $settings.logging.console_level }
                        if ($settings.logging.file_level) { $script:LogConfig.FileLevel = $settings.logging.file_level }
                        if ($settings.logging.retention_days) { $script:LogConfig.RetentionDays = $settings.logging.retention_days }
                        if ($settings.logging.max_file_size_mb) { $script:LogConfig.MaxFileSizeMB = $settings.logging.max_file_size_mb }
                    }
                } catch {}
            }
        }
    }

    # Ensure log directory exists
    $dir = Get-BotLogDir
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $script:LogConfig.Initialized = $true
}

# --- Internal: Resolve .control directory ---
function Get-BotControlDir {
    if ($script:LogConfig.ControlDir) { return $script:LogConfig.ControlDir }

    if ($env:DOTBOT_BOT_ROOT) {
        $dir = Join-Path $env:DOTBOT_BOT_ROOT ".control"
    } elseif ($global:DotbotProjectRoot) {
        $dir = Join-Path $global:DotbotProjectRoot ".bot\.control"
    } else {
        # Walk up: modules/ -> ui/ -> systems/ -> .bot/
        $botRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        $dir = Join-Path $botRoot ".control"
    }

    $script:LogConfig.ControlDir = $dir
    return $dir
}

# --- Internal: Resolve log directory ---
function Get-BotLogDir {
    if ($script:LogConfig.LogDir) { return $script:LogConfig.LogDir }

    $controlDir = Get-BotControlDir
    if (-not $controlDir) { return $null }

    $dir = Join-Path $controlDir "logs"
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $script:LogConfig.LogDir = $dir
    return $dir
}

# --- Internal: Atomic line append with retries ---
function Write-LogLine {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Line
    )

    for ($r = 0; $r -lt $script:LogConfig.MaxRetries; $r++) {
        try {
            $fs = [System.IO.FileStream]::new(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
            $sw.WriteLine($Line)
            $sw.Close()
            $fs.Close()
            return
        } catch {
            if ($r -lt ($script:LogConfig.MaxRetries - 1)) {
                Start-Sleep -Milliseconds ($script:LogConfig.RetryBaseMs * ($r + 1))
            }
        }
    }
}

#region ========== Core: Write-DotBotLog ==========

function Write-DotBotLog {
    <#
    .SYNOPSIS
    Writes a structured log entry to the unified dotbot log.

    .PARAMETER Level
    Severity: Debug, Info, Warn, Error, Fatal.

    .PARAMETER Message
    Human-readable log message.

    .PARAMETER Context
    Optional hashtable of additional context fields merged into the log entry.

    .PARAMETER Exception
    Optional ErrorRecord — error message and stack trace are extracted automatically.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warn', 'Error', 'Fatal')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Context,

        [System.Management.Automation.ErrorRecord]$Exception
    )

    try {
        # Check minimum file level
        $fileLevel = $script:LogConfig.FileLevel
        if (-not $fileLevel) { $fileLevel = 'Debug' }
        if ($script:LevelOrdinals[$Level] -lt $script:LevelOrdinals[$fileLevel]) {
            return
        }

        # Build structured entry per V4 spec
        $entry = [ordered]@{
            ts         = (Get-Date).ToUniversalTime().ToString('o')
            level      = $Level.ToLower()
            msg        = $Message
            process_id = $env:DOTBOT_PROCESS_ID
            task_id    = $env:DOTBOT_CURRENT_TASK_ID
            phase      = $env:DOTBOT_CURRENT_PHASE
            pid        = $PID
        }

        if ($Exception) {
            $entry.error = $Exception.Exception.Message
            if ($Exception.ScriptStackTrace) {
                $entry.stack = $Exception.ScriptStackTrace
            }
        }

        # Merge context fields
        if ($Context) {
            foreach ($k in $Context.Keys) {
                if (-not $entry.Contains($k)) {
                    $entry[$k] = $Context[$k]
                }
            }
        }

        $jsonLine = $entry | ConvertTo-Json -Compress -Depth 5

        # Write to unified log: dotbot-{date}.jsonl
        $logDir = Get-BotLogDir
        if ($logDir) {
            $logFile = Join-Path $logDir "dotbot-$(Get-Date -Format 'yyyy-MM-dd').jsonl"
            Write-LogLine -Path $logFile -Line $jsonLine
        }

        # Activity log backward compat: Info+ events also go to activity.jsonl
        if ($script:LevelOrdinals[$Level] -ge $script:LevelOrdinals['Info']) {
            $controlDir = Get-BotControlDir
            if ($controlDir) {
                $activityEntry = @{
                    timestamp = $entry.ts
                    type      = if ($Context -and $Context.type) { $Context.type } else { $Level.ToLower() }
                    message   = $Message
                    task_id   = $entry.task_id
                    phase     = $entry.phase
                } | ConvertTo-Json -Compress

                $activityPath = Join-Path $controlDir "activity.jsonl"
                Write-LogLine -Path $activityPath -Line $activityEntry

                # Per-process activity log
                if ($env:DOTBOT_PROCESS_ID) {
                    $processLogPath = Join-Path $controlDir "processes\$($env:DOTBOT_PROCESS_ID).activity.jsonl"
                    Write-LogLine -Path $processLogPath -Line $activityEntry
                }
            }
        }
    } catch {
        # Logging must NEVER propagate exceptions
        try { [Console]::Error.WriteLine("DotBotLog: Failed to write log: $($_.Exception.Message)") } catch {}
    }
}

#endregion

#region ========== Read / Clear / Summary ==========

function Read-DotBotLog {
    <#
    .SYNOPSIS
    Reads error-level log entries from the unified log, with filtering and pagination.
    Returns entries in UI-compatible format (timestamp, level, source, message, etc.).
    #>
    [CmdletBinding()]
    param(
        [int]$Limit = 100,
        [int]$Offset = 0,
        [string]$Source,
        [string]$Level,
        [string]$Since
    )

    $logDir = Get-BotLogDir
    if (-not $logDir -or -not (Test-Path $logDir)) {
        return @{ entries = @(); total = 0 }
    }

    # Check for cleared marker
    $clearedAfter = $null
    $clearedPath = Join-Path $logDir ".cleared"
    if (Test-Path $clearedPath) {
        try { $clearedAfter = (Get-Content $clearedPath -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
    }

    # Read from all log files, newest first
    $files = @(Get-ChildItem -Path $logDir -Filter "dotbot-*.jsonl" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    $entries = [System.Collections.ArrayList]::new()

    foreach ($file in $files) {
        try {
            $lines = @(Get-Content -Path $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        } catch { continue }

        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if (-not $line -or $line.Length -lt 2) { continue }
            try {
                $obj = $line | ConvertFrom-Json

                # Skip entries before cleared marker
                if ($clearedAfter -and $obj.ts -le $clearedAfter) { continue }

                # Normalize to UI-compatible format
                $uiEntry = [ordered]@{
                    timestamp    = $obj.ts
                    level        = $obj.level
                    source       = if ($obj.source) { $obj.source } else { 'unknown' }
                    message      = $obj.msg
                    task_id      = $obj.task_id
                    process_type = $obj.process_type
                    process_id   = $obj.process_id
                    error_code   = $obj.error_code
                }

                # Stack trace: prefer explicit stack_override, then error record stack
                if ($obj.stack_override) {
                    $uiEntry.stack_trace = $obj.stack_override
                } elseif ($obj.stack) {
                    $uiEntry.stack_trace = $obj.stack
                }

                $entries.Add([PSCustomObject]$uiEntry) | Out-Null
            } catch { continue }
        }
    }

    # Apply filters
    if ($Source) {
        $entries = [System.Collections.ArrayList]@($entries | Where-Object { $_.source -eq $Source })
    }
    if ($Level) {
        $entries = [System.Collections.ArrayList]@($entries | Where-Object { $_.level -eq $Level })
    }
    if ($Since) {
        try {
            $sinceDate = [DateTimeOffset]::Parse($Since)
            $entries = [System.Collections.ArrayList]@($entries | Where-Object {
                try { [DateTimeOffset]::Parse($_.timestamp) -ge $sinceDate } catch { $false }
            })
        } catch {}
    }

    $total = $entries.Count

    # Paginate
    if ($Offset -gt 0 -and $Offset -lt $entries.Count) {
        $entries = [System.Collections.ArrayList]@($entries[$Offset..($entries.Count - 1)])
    } elseif ($Offset -ge $entries.Count) {
        $entries = [System.Collections.ArrayList]::new()
    }

    if ($Limit -gt 0 -and $entries.Count -gt $Limit) {
        $entries = [System.Collections.ArrayList]@($entries[0..($Limit - 1)])
    }

    return @{
        entries = @($entries)
        total   = $total
    }
}

function Clear-DotBotLog {
    <#
    .SYNOPSIS
    Marks the error log as cleared. Entries before this timestamp are hidden from reads.
    #>
    $logDir = Get-BotLogDir
    if (-not $logDir) {
        return @{ success = $true; message = "Error log cleared" }
    }

    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    # Write a cleared marker with current UTC timestamp
    $clearedPath = Join-Path $logDir ".cleared"
    (Get-Date).ToUniversalTime().ToString('o') | Set-Content -Path $clearedPath -Encoding UTF8 -NoNewline -ErrorAction SilentlyContinue

    return @{ success = $true; message = "Log cleared" }
}

function Get-DotBotLogSummary {
    <#
    .SYNOPSIS
    Returns summary counts of log entries grouped by source and level.
    #>
    $logDir = Get-BotLogDir
    if (-not $logDir -or -not (Test-Path $logDir)) {
        return @{ total = 0; by_level = @{}; by_source = @{}; latest_timestamp = $null }
    }

    # Check for cleared marker
    $clearedAfter = $null
    $clearedPath = Join-Path $logDir ".cleared"
    if (Test-Path $clearedPath) {
        try { $clearedAfter = (Get-Content $clearedPath -Raw -ErrorAction SilentlyContinue).Trim() } catch {}
    }

    $byLevel = @{}
    $bySource = @{}
    $total = 0
    $latestTimestamp = $null

    $files = @(Get-ChildItem -Path $logDir -Filter "dotbot-*.jsonl" -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        try {
            $lines = @(Get-Content -Path $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        } catch { continue }

        foreach ($line in $lines) {
            if (-not $line -or $line.Length -lt 2) { continue }
            try {
                $obj = $line | ConvertFrom-Json

                # Skip entries before cleared marker
                if ($clearedAfter -and $obj.ts -le $clearedAfter) { continue }

                $total++

                $lvl = $obj.level
                $src = if ($obj.source) { $obj.source } else { 'unknown' }

                if ($byLevel.ContainsKey($lvl)) { $byLevel[$lvl]++ } else { $byLevel[$lvl] = 1 }
                if ($bySource.ContainsKey($src)) { $bySource[$src]++ } else { $bySource[$src] = 1 }

                $latestTimestamp = $obj.ts
            } catch { continue }
        }
    }

    return @{
        total            = $total
        by_level         = $byLevel
        by_source        = $bySource
        latest_timestamp = $latestTimestamp
    }
}

#endregion

#region ========== Rotation ==========

function Invoke-DotBotLogRotation {
    <#
    .SYNOPSIS
    Removes log files older than the configured retention period (default 7 days).
    #>
    $logDir = Get-BotLogDir
    if (-not $logDir -or -not (Test-Path $logDir)) { return }

    $cutoff = (Get-Date).AddDays(-$script:LogConfig.RetentionDays)
    Get-ChildItem -Path $logDir -Filter "dotbot-*.jsonl" -ErrorAction SilentlyContinue | Where-Object {
        $_.LastWriteTime -lt $cutoff
    } | Remove-Item -Force -ErrorAction SilentlyContinue
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-DotBotLog',
    'Write-DotBotLog',
    'Read-DotBotLog',
    'Clear-DotBotLog',
    'Get-DotBotLogSummary',
    'Invoke-DotBotLogRotation'
)
