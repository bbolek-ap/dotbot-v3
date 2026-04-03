#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Remote installer for dotbot-v3

.DESCRIPTION
    Downloads the latest release of dotbot and installs it globally.
    Designed to be used with: irm https://raw.githubusercontent.com/andresharpe/dotbot-v3/main/install-remote.ps1 | iex

.EXAMPLE
    irm https://raw.githubusercontent.com/andresharpe/dotbot-v3/main/install-remote.ps1 | iex
#>

$ErrorActionPreference = "Stop"

$RepoOwner = "andresharpe"
$RepoName = "dotbot-v3"

Write-Host ""
Write-Host "=======================================================" -ForegroundColor Blue
Write-Host ""
Write-Host "    D O T B O T   v3" -ForegroundColor Blue
Write-Host "    Remote Installer" -ForegroundColor Yellow
Write-Host ""
Write-Host "=======================================================" -ForegroundColor Blue
Write-Host ""

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "  X PowerShell 7+ is required" -ForegroundColor Red
    Write-Host "    Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host "    Download from: https://aka.ms/powershell" -ForegroundColor Cyan
    Write-Host ""
    return
}

# Check for git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  X Git is required" -ForegroundColor Red
    Write-Host "    Download from: https://git-scm.com/downloads" -ForegroundColor Cyan
    Write-Host ""
    return
}

# Determine archive format based on platform (PS 7+ provides $IsWindows automatically)
$archiveExt = if ($IsWindows) { "zip" } else { "tar.gz" }

# Fetch latest release info from GitHub API
Write-Host "  Fetching latest release..." -ForegroundColor Cyan
try {
    $releaseUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
    $release = Invoke-RestMethod -Uri $releaseUrl -Headers @{ 'User-Agent' = 'dotbot-installer' }
    $version = $release.tag_name -replace '^v', ''
    Write-Host "  Latest version: v$version" -ForegroundColor Green
} catch {
    # Fallback: clone from main branch if no releases exist yet
    Write-Host "  No releases found, installing from main branch..." -ForegroundColor Yellow

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-install-$(Get-Random)"
    try {
        git clone --depth 1 "https://github.com/$RepoOwner/$RepoName.git" $tempDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
        & (Join-Path $tempDir "install.ps1")
    } finally {
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return
}

# Find the download URL for the appropriate archive
$archiveAsset = $release.assets | Where-Object { $_.name -like "*.$archiveExt" -and $_.name -notlike "*.sha256" }
if (-not $archiveAsset) {
    Write-Host "  X No $archiveExt archive found in release v$version" -ForegroundColor Red
    Write-Host "    Falling back to git clone..." -ForegroundColor Yellow

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-install-$(Get-Random)"
    try {
        git clone --depth 1 --branch "v$version" "https://github.com/$RepoOwner/$RepoName.git" $tempDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
        & (Join-Path $tempDir "install.ps1")
    } finally {
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return
}

# Download archive
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-install-$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$archivePath = Join-Path $tempDir $archiveAsset.name
Write-Host "  Downloading v$version..." -ForegroundColor Cyan

try {
    Invoke-WebRequest -Uri $archiveAsset.browser_download_url -OutFile $archivePath

    # Extract archive
    Write-Host "  Extracting..." -ForegroundColor Cyan
    $extractDir = Join-Path $tempDir "extracted"

    if ($archiveExt -eq "zip") {
        Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force
    } else {
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        tar -xzf $archivePath -C $extractDir
    }

    # Find the extracted directory (should be dotbot-v3-{version}/)
    $innerDir = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    if (-not $innerDir) {
        throw "Could not find extracted directory"
    }

    # Run install.ps1 from the extracted directory
    $installScript = Join-Path $innerDir.FullName "install.ps1"
    if (-not (Test-Path $installScript)) {
        throw "install.ps1 not found in extracted archive"
    }

    & $installScript

} finally {
    # Clean up temp directory
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
