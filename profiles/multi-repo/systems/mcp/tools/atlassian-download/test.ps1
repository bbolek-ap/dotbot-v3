# Test atlassian-download tool
# NOTE: Actual downloading requires network + Atlassian credentials.
# This test validates argument parsing and graceful error handling only.

. "$PSScriptRoot\script.ps1"

Write-Host "Testing atlassian-download..." -ForegroundColor Cyan

# Test 1: Missing 'jira_key' parameter
Write-Host "`n1. Missing 'jira_key' parameter"
$threwMissing = $false
try {
    Invoke-AtlassianDownload -Arguments @{}
} catch {
    if ($_.Exception.Message -like "*jira_key*required*") {
        $threwMissing = $true
    }
}
if ($threwMissing) {
    Write-Host "   PASS: Throws for missing jira_key" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Should throw for missing jira_key" -ForegroundColor Red
}

# Test 2: No credentials -> graceful error
Write-Host "`n2. No credentials -> graceful error"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-atl-dl-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
$global:DotbotProjectRoot = $testRoot

# Save and clear env vars
$savedEmail = $env:ATLASSIAN_EMAIL
$savedToken = $env:ATLASSIAN_API_TOKEN
$savedCloud = $env:ATLASSIAN_CLOUD_ID
$env:ATLASSIAN_EMAIL = $null
$env:ATLASSIAN_API_TOKEN = $null
$env:ATLASSIAN_CLOUD_ID = $null

$threwNoCreds = $false
try {
    Invoke-AtlassianDownload -Arguments @{ jira_key = "TEST-123" }
} catch {
    $threwNoCreds = $true
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Gray
}

# Restore env vars
$env:ATLASSIAN_EMAIL = $savedEmail
$env:ATLASSIAN_API_TOKEN = $savedToken
$env:ATLASSIAN_CLOUD_ID = $savedCloud

if ($threwNoCreds) {
    Write-Host "   PASS: Throws when no credentials" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Should throw when no credentials available" -ForegroundColor Red
}

# Test 3: Custom target_dir parameter accepted
Write-Host "`n3. Custom target_dir is accepted"
$env:ATLASSIAN_EMAIL = "test@example.com"
$env:ATLASSIAN_API_TOKEN = "fake-token"
$env:ATLASSIAN_CLOUD_ID = "fake-cloud-id"

$threwApi = $false
try {
    # This will fail at the API call, but should not fail on arg parsing
    Invoke-AtlassianDownload -Arguments @{ jira_key = "TEST-123"; target_dir = "custom/docs" }
} catch {
    $threwApi = $true
}

# Verify the custom directory was created
$customDir = Join-Path $testRoot "custom\docs"
$dirCreated = Test-Path $customDir

$env:ATLASSIAN_EMAIL = $savedEmail
$env:ATLASSIAN_API_TOKEN = $savedToken
$env:ATLASSIAN_CLOUD_ID = $savedCloud

if ($dirCreated) {
    Write-Host "   PASS: Custom target_dir created" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Custom target_dir was not created" -ForegroundColor Red
}

# Cleanup
if (Test-Path $testRoot) {
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nTests complete." -ForegroundColor Cyan
