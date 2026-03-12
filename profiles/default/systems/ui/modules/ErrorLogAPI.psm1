<#
.SYNOPSIS
Error log API module for the web dashboard

.DESCRIPTION
Provides functions to read, query, and clear the structured error log
at .bot/.control/error.log. Used by server.ps1 API endpoints.
#>

$script:Config = @{
    ControlDir = $null
}

function Initialize-ErrorLogAPI {
    param(
        [Parameter(Mandatory)] [string]$ControlDir,
        [Parameter(Mandatory)] [string]$BotRoot
    )
    $script:Config.ControlDir = $ControlDir

    # Import ErrorLogger module for Read/Clear/Summary functions
    $errorLoggerPath = Join-Path $BotRoot "systems\runtime\modules\ErrorLogger.psm1"
    if (Test-Path $errorLoggerPath) {
        Import-Module $errorLoggerPath -Force
    }
}

function Get-ErrorLogEntries {
    <#
    .SYNOPSIS
    Returns error log entries for the API, with pagination and filtering.
    #>
    param(
        [int]$Limit = 50,
        [int]$Offset = 0,
        [string]$Source,
        [string]$Level,
        [string]$Since
    )

    $params = @{ Limit = $Limit; Offset = $Offset }
    if ($Source) { $params.Source = $Source }
    if ($Level) { $params.Level = $Level }
    if ($Since) { $params.Since = $Since }

    $result = Read-ErrorLog @params
    $summary = Get-ErrorLogSummary

    return @{
        success = $true
        entries = $result.entries
        total   = $result.total
        summary = $summary
    }
}

function Invoke-ClearErrorLog {
    <#
    .SYNOPSIS
    Clears the error log.
    #>
    $result = Clear-ErrorLog
    return @{
        success = $result.success
        message = $result.message
    }
}

function Get-ErrorSummary {
    <#
    .SYNOPSIS
    Returns just the error summary (for polling/badges).
    #>
    return @{
        success = $true
        summary = (Get-ErrorLogSummary)
    }
}

Export-ModuleMember -Function @(
    'Initialize-ErrorLogAPI',
    'Get-ErrorLogEntries',
    'Invoke-ClearErrorLog',
    'Get-ErrorSummary'
)
