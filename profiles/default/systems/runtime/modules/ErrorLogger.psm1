<#
.SYNOPSIS
Structured error logging module for dotbot-v3

.DESCRIPTION
Provides Write-ErrorLog for writing structured JSON-lines entries to .bot/.control/error.log.
Each entry includes: timestamp, level, source, process_type, process_id, task_id, message,
stack_trace, and error_code. Implements log rotation with a configurable size cap.
#>

<#
Rotation can be tuned per-environment via:
  - DOTBOT_ERRORLOG_MAX_FILE_SIZE_BYTES  : maximum size in bytes before rotation (default 5 MiB)
  - DOTBOT_ERRORLOG_MAX_ROTATED_FILES    : number of rotated files to keep (default 2)
#>

# --- Configuration ---

# Allow environment variables to override rotation defaults while preserving existing behavior.
$maxFileSizeBytes = 5 * 1024 * 1024  # 5 MB default
if ($env:DOTBOT_ERRORLOG_MAX_FILE_SIZE_BYTES) {
    $parsedSize = 0
    if ([int]::TryParse($env:DOTBOT_ERRORLOG_MAX_FILE_SIZE_BYTES, [ref]$parsedSize) -and $parsedSize -gt 0) {
        $maxFileSizeBytes = $parsedSize
    }
}

$maxRotatedFiles = 2  # Keep error.log.1 and error.log.2 by default
if ($env:DOTBOT_ERRORLOG_MAX_ROTATED_FILES) {
    $parsedCount = 0
    if ([int]::TryParse($env:DOTBOT_ERRORLOG_MAX_ROTATED_FILES, [ref]$parsedCount) -and $parsedCount -gt 0) {
        $maxRotatedFiles = $parsedCount
    }
}

$script:ErrorLogConfig = @{
    MaxFileSizeBytes = $maxFileSizeBytes
    MaxRotatedFiles  = $maxRotatedFiles
    MaxRetries       = 3
    RetryBaseMs      = 50
}

# --- Internal: Resolve .control directory ---
function Get-ErrorLogPath {
    # When running inside .bot context, find .control relative to known roots
    if ($env:DOTBOT_BOT_ROOT) {
        $controlDir = Join-Path $env:DOTBOT_BOT_ROOT ".control"
    } elseif ($global:DotbotProjectRoot) {
        $controlDir = Join-Path $global:DotbotProjectRoot ".bot\.control"
    } else {
        # Walk up from script location: modules/ -> runtime/ -> systems/ -> .bot/
        $botRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        $controlDir = Join-Path $botRoot ".control"
    }

    if (-not (Test-Path $controlDir)) {
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
    }

    return Join-Path $controlDir "error.log"
}

# --- Log Rotation ---
function Invoke-ErrorLogRotation {
    param(
        [Parameter(Mandatory)]
        [string]$LogPath
    )

    if (-not (Test-Path $LogPath)) { return }

    $fileInfo = Get-Item $LogPath -ErrorAction SilentlyContinue
    if (-not $fileInfo -or $fileInfo.Length -lt $script:ErrorLogConfig.MaxFileSizeBytes) { return }

    # Rotate: error.log.2 is deleted, error.log.1 -> error.log.2, error.log -> error.log.1
    for ($i = $script:ErrorLogConfig.MaxRotatedFiles; $i -ge 1; $i--) {
        $src = if ($i -eq 1) { $LogPath } else { "$LogPath.$($i - 1)" }
        $dst = "$LogPath.$i"

        if ($i -eq $script:ErrorLogConfig.MaxRotatedFiles -and (Test-Path $dst)) {
            Remove-Item $dst -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path $src) {
            Move-Item $src $dst -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Public: Write a structured error log entry ---
function Write-ErrorLog {
    <#
    .SYNOPSIS
    Writes a structured error entry to the central error log.

    .PARAMETER Message
    Human-readable error description.

    .PARAMETER Source
    Origin of the error: 'claude-cli', 'mcp-tool', 'runtime', 'ui-server', 'verification', etc.

    .PARAMETER Level
    Severity level: 'error' (default), 'warning', 'critical'.

    .PARAMETER ErrorCode
    Optional machine-readable error code (e.g., 'TIMEOUT', 'AUTH_LIMIT', 'TOOL_EXEC_FAILED').

    .PARAMETER ProcessType
    Optional process type: analysis, execution, workflow, kickstart, etc.

    .PARAMETER ProcessId
    Optional process registry ID.

    .PARAMETER TaskId
    Optional task ID associated with the error.

    .PARAMETER StackTrace
    Optional stack trace string.

    .PARAMETER Exception
    Optional ErrorRecord or Exception object — message and stack trace are extracted automatically.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet('claude-cli', 'mcp-tool', 'runtime', 'ui-server', 'verification', 'worktree', 'process')]
        [string]$Source,

        [ValidateSet('warning', 'error', 'critical')]
        [string]$Level = 'error',

        [string]$ErrorCode,
        [string]$ProcessType,
        [string]$ProcessId,
        [string]$TaskId,
        [string]$StackTrace,
        [System.Management.Automation.ErrorRecord]$Exception
    )

    try {
        $logPath = Get-ErrorLogPath

        # Build entry
        $entry = [ordered]@{
            timestamp    = (Get-Date).ToUniversalTime().ToString('o')
            level        = $Level
            source       = $Source
            message      = $Message
        }

        # Fill from environment if not provided
        if (-not $ProcessType -and $env:DOTBOT_CURRENT_PHASE) {
            $entry.process_type = $env:DOTBOT_CURRENT_PHASE
        } elseif ($ProcessType) {
            $entry.process_type = $ProcessType
        }

        if (-not $ProcessId -and $env:DOTBOT_PROCESS_ID) {
            $entry.process_id = $env:DOTBOT_PROCESS_ID
        } elseif ($ProcessId) {
            $entry.process_id = $ProcessId
        }

        if (-not $TaskId -and $env:DOTBOT_CURRENT_TASK_ID) {
            $entry.task_id = $env:DOTBOT_CURRENT_TASK_ID
        } elseif ($TaskId) {
            $entry.task_id = $TaskId
        }

        if ($ErrorCode) {
            $entry.error_code = $ErrorCode
        }

        # Extract from ErrorRecord if provided
        if ($Exception) {
            if (-not $StackTrace -and $Exception.ScriptStackTrace) {
                $entry.stack_trace = $Exception.ScriptStackTrace
            }
            if (-not $ErrorCode -and $Exception.FullyQualifiedErrorId) {
                $entry.error_code = $Exception.FullyQualifiedErrorId
            }
        } elseif ($StackTrace) {
            $entry.stack_trace = $StackTrace
        }

        $jsonLine = $entry | ConvertTo-Json -Compress -Depth 5

        # Rotate if needed
        Invoke-ErrorLogRotation -LogPath $logPath

        # Atomic append with retries (matching existing Write-ActivityLog pattern)
        for ($r = 0; $r -lt $script:ErrorLogConfig.MaxRetries; $r++) {
            try {
                $fs = [System.IO.FileStream]::new(
                    $logPath,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite
                )
                $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
                $sw.WriteLine($jsonLine)
                $sw.Close()
                $fs.Close()
                break
            } catch {
                if ($r -lt ($script:ErrorLogConfig.MaxRetries - 1)) {
                    Start-Sleep -Milliseconds ($script:ErrorLogConfig.RetryBaseMs * ($r + 1))
                }
                # Silently fail on final retry — error logging must never crash the caller
            }
        }
    } catch {
        # Error logging must NEVER propagate exceptions
        try { [Console]::Error.WriteLine("ErrorLogger: Failed to write error log: $($_.Exception.Message)") } catch {}
    }
}

# --- Public: Read error log entries ---
function Read-ErrorLog {
    <#
    .SYNOPSIS
    Reads error log entries, optionally filtered and paginated.

    .PARAMETER Limit
    Max entries to return (default 100).

    .PARAMETER Offset
    Number of entries to skip from the end (newest first).

    .PARAMETER Source
    Filter by source.

    .PARAMETER Level
    Filter by level.

    .PARAMETER Since
    Only return entries after this ISO timestamp.
    #>
    [CmdletBinding()]
    param(
        [int]$Limit = 100,
        [int]$Offset = 0,
        [string]$Source,
        [string]$Level,
        [string]$Since
    )

    $logPath = Get-ErrorLogPath
    if (-not (Test-Path $logPath)) {
        return @{
            entries = @()
            total   = 0
        }
    }

    try {
        $lines = @(Get-Content -Path $logPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    } catch {
        return @{ entries = @(); total = 0 }
    }

    # Parse all lines (newest first)
    $entries = [System.Collections.ArrayList]::new()
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = $lines[$i]
        if (-not $line -or $line.Length -lt 2) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            $entries.Add($obj) | Out-Null
        } catch {
            continue
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

# --- Public: Clear error log ---
function Clear-ErrorLog {
    <#
    .SYNOPSIS
    Clears the error log file and all rotated copies.
    #>
    $logPath = Get-ErrorLogPath

    foreach ($path in @($logPath, "$logPath.1", "$logPath.2")) {
        if (Test-Path $path) {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }

    return @{ success = $true; message = "Error log cleared" }
}

# --- Public: Get error summary (counts by source/level) ---
function Get-ErrorLogSummary {
    <#
    .SYNOPSIS
    Returns summary counts of errors grouped by source and level.
    #>
    $logPath = Get-ErrorLogPath
    if (-not (Test-Path $logPath)) {
        return @{
            total = 0
            by_level = @{}
            by_source = @{}
            latest_timestamp = $null
        }
    }

    $byLevel = @{}
    $bySource = @{}
    $total = 0
    $latestTimestamp = $null

    try {
        $lines = @(Get-Content -Path $logPath -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            if (-not $line -or $line.Length -lt 2) { continue }
            try {
                $obj = $line | ConvertFrom-Json
                $total++

                $lvl = if ($obj.level) { $obj.level } else { 'unknown' }
                $src = if ($obj.source) { $obj.source } else { 'unknown' }

                if ($byLevel.ContainsKey($lvl)) { $byLevel[$lvl]++ } else { $byLevel[$lvl] = 1 }
                if ($bySource.ContainsKey($src)) { $bySource[$src]++ } else { $bySource[$src] = 1 }

                $latestTimestamp = $obj.timestamp
            } catch { continue }
        }
    } catch {}

    return @{
        total            = $total
        by_level         = $byLevel
        by_source        = $bySource
        latest_timestamp = $latestTimestamp
    }
}

Export-ModuleMember -Function @(
    'Write-ErrorLog',
    'Read-ErrorLog',
    'Clear-ErrorLog',
    'Get-ErrorLogSummary'
)
