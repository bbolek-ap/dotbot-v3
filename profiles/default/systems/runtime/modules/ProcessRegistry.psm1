#Requires -Version 7.0

<#
.SYNOPSIS
Process registry functions: CRUD, locking, activity logging, diagnostics, and preflight checks.
#>

function New-ProcessId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    "proc-$([guid]::NewGuid().ToString().Substring(0,6))"
}

function Write-ProcessFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Data,
        [Parameter(Mandatory)][string]$ProcessesDir
    )
    $filePath = Join-Path $ProcessesDir "$Id.json"
    $tempFile = "$filePath.tmp"

    $maxRetries = 3
    for ($r = 0; $r -lt $maxRetries; $r++) {
        try {
            $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding utf8NoBOM -NoNewline
            Move-Item -Path $tempFile -Destination $filePath -Force -ErrorAction Stop
            return
        } catch {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            if ($r -lt ($maxRetries - 1)) {
                Start-Sleep -Milliseconds (50 * ($r + 1))
            } else {
                Write-Diag -Msg "Write-ProcessFile FAILED for $Id after $maxRetries retries: $_" -DiagLogPath $script:DiagLogPath
                throw "Write-ProcessFile failed for '$Id' after $maxRetries retries: $_"
            }
        }
    }
}

function Write-ProcessActivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ActivityType,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$ProcessesDir
    )
    $logPath = Join-Path $ProcessesDir "$Id.activity.jsonl"
    $event = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        type = $ActivityType
        message = $Message
        task_id = $env:DOTBOT_CURRENT_TASK_ID
        phase = $env:DOTBOT_CURRENT_PHASE
    } | ConvertTo-Json -Compress

    $maxRetries = 3
    for ($r = 0; $r -lt $maxRetries; $r++) {
        try {
            $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
            $sw.WriteLine($event)
            $sw.Close()
            $fs.Close()
            break
        } catch {
            if ($r -lt ($maxRetries - 1)) { Start-Sleep -Milliseconds (50 * ($r + 1)) }
        }
    }

    # Also write to global activity.jsonl for oscilloscope backward compat
    try { Write-ActivityLog -Type $ActivityType -Message $Message } catch {
        Write-Diag -Msg "Write-ActivityLog FAILED: $_ | Type=$ActivityType Msg=$Message" -DiagLogPath $script:DiagLogPath
    }
}

function Write-Diag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Msg,
        [string]$DiagLogPath
    )
    $path = if ($DiagLogPath) { $DiagLogPath } else { $script:DiagLogPath }
    if (-not $path) { return }
    try {
        "$(Get-Date -Format 'o') [$PID] $Msg" | Add-Content -Path $path -Encoding utf8NoBOM
    } catch {}
}

function Test-ProcessStopSignal {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ProcessesDir
    )
    $stopFile = Join-Path $ProcessesDir "$Id.stop"
    Test-Path $stopFile
}

function Test-ProcessLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$LockType,
        [Parameter(Mandatory)][string]$ControlDir
    )
    $lockPath = Join-Path $ControlDir "launch-$LockType.lock"
    if (-not (Test-Path $lockPath)) { return $false }
    $lockContent = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
    if (-not $lockContent) { return $false }
    try {
        Get-Process -Id ([int]$lockContent.Trim()) -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Set-ProcessLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$LockType,
        [Parameter(Mandatory)][string]$ControlDir
    )
    $lockPath = Join-Path $ControlDir "launch-$LockType.lock"
    try {
        $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($PID.ToString())
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Close()
        }
        return $true
    } catch [System.IO.IOException] {
        return $false
    }
}

function Remove-ProcessLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LockType,
        [Parameter(Mandatory)][string]$ControlDir
    )
    $lockPath = Join-Path $ControlDir "launch-$LockType.lock"
    if (Test-Path $lockPath) {
        $lockPid = Get-Content $lockPath -Raw -ErrorAction SilentlyContinue
        if ($lockPid) { $lockPid = $lockPid.Trim() }
        if ($lockPid -eq $PID.ToString()) {
            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warning "Lock file PID ($lockPid) does not match current process ($PID). Skipping removal."
        }
    }
}

function Test-Preflight {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)]$ProviderConfig
    )
    $checks = @()
    $allPassed = $true

    # git on PATH
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $checks += "git: OK"
    } else {
        $checks += "git: MISSING - git not found on PATH"
        $allPassed = $false
    }

    # Provider CLI on PATH
    $providerExe = $ProviderConfig.executable
    $providerDisplay = $ProviderConfig.display_name
    $providerCmd = Get-Command $providerExe -ErrorAction SilentlyContinue
    if ($providerCmd) {
        $checks += "${providerExe}: OK"
    } else {
        $checks += "${providerExe}: MISSING - $providerDisplay CLI not found on PATH"
        $allPassed = $false
    }

    # .bot directory exists
    if (Test-Path $BotRoot) {
        $checks += ".bot: OK"
    } else {
        $checks += ".bot: MISSING - $BotRoot not found (run 'dotbot init' first)"
        $allPassed = $false
    }

    # powershell-yaml module
    $yamlMod = Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue
    if ($yamlMod) {
        $checks += "powershell-yaml: OK"
    } else {
        $checks += "powershell-yaml: MISSING - Install with: Install-Module powershell-yaml -Scope CurrentUser"
        $allPassed = $false
    }

    return @{ passed = $allPassed; checks = $checks }
}

function Initialize-DiagLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DiagLogPath
    )
    $script:DiagLogPath = $DiagLogPath
}

Export-ModuleMember -Function @(
    'New-ProcessId'
    'Write-ProcessFile'
    'Write-ProcessActivity'
    'Write-Diag'
    'Test-ProcessStopSignal'
    'Test-ProcessLock'
    'Set-ProcessLock'
    'Remove-ProcessLock'
    'Test-Preflight'
    'Initialize-DiagLog'
)
