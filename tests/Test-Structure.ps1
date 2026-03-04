#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Structure tests for dotbot-v3 new user experience.
.DESCRIPTION
    Tests dependencies, global install, project init, and platform functions.
    No AI/Claude dependency required.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot
$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Structure Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ═══════════════════════════════════════════════════════════════════
# DEPENDENCY CHECKS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  DEPENDENCIES" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# PowerShell 7+
Assert-True -Name "PowerShell 7+" `
    -Condition ($PSVersionTable.PSVersion.Major -ge 7) `
    -Message "Current version: $($PSVersionTable.PSVersion)"

# Git available
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
Assert-True -Name "Git is available" -Condition ($null -ne $gitCmd) -Message "git not found on PATH"

# Git version >= 2.15 (worktree support)
if ($gitCmd) {
    $gitVersionOutput = & git --version 2>&1
    $gitVersionMatch = [regex]::Match($gitVersionOutput, '(\d+)\.(\d+)')
    if ($gitVersionMatch.Success) {
        $gitMajor = [int]$gitVersionMatch.Groups[1].Value
        $gitMinor = [int]$gitVersionMatch.Groups[2].Value
        $gitOk = ($gitMajor -gt 2) -or ($gitMajor -eq 2 -and $gitMinor -ge 15)
        Assert-True -Name "Git >= 2.15 (worktree support)" `
            -Condition $gitOk `
            -Message "Git $gitMajor.$gitMinor found, need >= 2.15"
    } else {
        Write-TestResult -Name "Git >= 2.15 (worktree support)" -Status Skip -Message "Could not parse git version"
    }
}

# powershell-yaml module
$yamlModule = Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue
Assert-True -Name "powershell-yaml module installed" `
    -Condition ($null -ne $yamlModule) `
    -Message "Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"

# npx (Node.js) - needed for Context7 and Playwright MCP
$npxCmd = Get-Command npx -ErrorAction SilentlyContinue
Assert-True -Name "npx available (for MCP servers)" `
    -Condition ($null -ne $npxCmd) `
    -Message "npx not found. Install Node.js from https://nodejs.org"

# Optional: Claude CLI
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-TestResult -Name "Claude CLI (optional)" -Status Pass
} else {
    Write-TestResult -Name "Claude CLI (optional)" -Status Skip -Message "Not installed — Layer 4 tests will be skipped"
}

# Optional: gitleaks
$gitleaksCmd = Get-Command gitleaks -ErrorAction SilentlyContinue
if ($gitleaksCmd) {
    Write-TestResult -Name "gitleaks (optional)" -Status Pass
} else {
    Write-TestResult -Name "gitleaks (optional)" -Status Skip -Message "Not installed — pre-commit hook won't be created"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# GLOBAL INSTALL
# ═══════════════════════════════════════════════════════════════════

Write-Host "  GLOBAL INSTALL" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Backup existing dotbot install if present
$hadExistingInstall = Test-Path $dotbotDir
$backupDir = $null
if ($hadExistingInstall) {
    $backupDir = "${dotbotDir}-test-backup"
    if (Test-Path $backupDir) { Remove-Item $backupDir -Recurse -Force }
    Rename-Item -Path $dotbotDir -NewName (Split-Path $backupDir -Leaf)
}

try {
    # Run global install from repo
    $installScript = Join-Path $repoRoot "scripts\install-global.ps1"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $installScript 2>&1 | Out-Null

    Assert-PathExists -Name "~/dotbot directory created" -Path $dotbotDir
    Assert-PathExists -Name "~/dotbot/profiles/default exists" -Path (Join-Path $dotbotDir "profiles\default")
    Assert-PathExists -Name "~/dotbot/scripts exists" -Path (Join-Path $dotbotDir "scripts")

    $binDir = Join-Path $dotbotDir "bin"
    Assert-PathExists -Name "~/dotbot/bin exists" -Path $binDir

    $cliScript = Join-Path $binDir "dotbot.ps1"
    Assert-PathExists -Name "dotbot.ps1 CLI wrapper exists" -Path $cliScript

    # CLI wrapper contains expected commands
    if (Test-Path $cliScript) {
        Assert-FileContains -Name "CLI has 'init' command" -Path $cliScript -Pattern "init"
        Assert-FileContains -Name "CLI has 'profiles' command" -Path $cliScript -Pattern "profiles"
        Assert-FileContains -Name "CLI has 'status' command" -Path $cliScript -Pattern "status"
        Assert-FileContains -Name "CLI has 'help' command" -Path $cliScript -Pattern "help"
    }

    # dotbot status runs without error
    if (Test-Path $cliScript) {
        try {
            $statusOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $cliScript status 2>&1
            Assert-True -Name "dotbot status runs without error" -Condition ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) -Message "Exit code: $LASTEXITCODE"
        } catch {
            Write-TestResult -Name "dotbot status runs without error" -Status Fail -Message $_.Exception.Message
        }
    }

} finally {
    # Restore original install
    if (Test-Path $dotbotDir) { Remove-Item $dotbotDir -Recurse -Force }
    if ($backupDir -and (Test-Path $backupDir)) {
        Rename-Item -Path $backupDir -NewName (Split-Path $dotbotDir -Leaf)
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PROJECT INIT
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROJECT INIT" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# dotbot must be installed for init to work — ensure it's present
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "profiles\default")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Project init tests" -Status Skip -Message "dotbot not installed globally — run install.ps1 first"
} else {
    $testProject = New-TestProject
    try {
        # Run init
        Push-Location $testProject
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
        Pop-Location

        $botDir = Join-Path $testProject ".bot"
        Assert-PathExists -Name ".bot directory created" -Path $botDir

        # Task status directories (all 9)
        $taskDirs = @('todo', 'analysing', 'analysed', 'needs-input', 'in-progress', 'done', 'split', 'skipped', 'cancelled')
        foreach ($dir in $taskDirs) {
            Assert-PathExists -Name "Task dir: $dir" -Path (Join-Path $botDir "workspace\tasks\$dir")
        }

        # System directories
        Assert-PathExists -Name "systems/mcp exists" -Path (Join-Path $botDir "systems\mcp")
        Assert-PathExists -Name "systems/ui exists" -Path (Join-Path $botDir "systems\ui")
        Assert-PathExists -Name "systems/runtime exists" -Path (Join-Path $botDir "systems\runtime")

        # Prompts directories
        Assert-PathExists -Name "prompts/agents exists" -Path (Join-Path $botDir "prompts\agents")
        Assert-PathExists -Name "prompts/skills exists" -Path (Join-Path $botDir "prompts\skills")
        Assert-PathExists -Name "prompts/workflows exists" -Path (Join-Path $botDir "prompts\workflows")

        # Workspace directories
        Assert-PathExists -Name "workspace/sessions exists" -Path (Join-Path $botDir "workspace\sessions")
        Assert-PathExists -Name "workspace/plans exists" -Path (Join-Path $botDir "workspace\plans")
        Assert-PathExists -Name "workspace/product exists" -Path (Join-Path $botDir "workspace\product")
        Assert-PathExists -Name "workspace/feedback exists" -Path (Join-Path $botDir "workspace\feedback")

        # Other directories
        Assert-PathExists -Name "hooks directory exists" -Path (Join-Path $botDir "hooks")
        Assert-PathExists -Name "defaults directory exists" -Path (Join-Path $botDir "defaults")

        # Key files
        Assert-PathExists -Name "go.ps1 exists" -Path (Join-Path $botDir "go.ps1")
        Assert-ValidPowerShell -Name "go.ps1 is valid PowerShell" -Path (Join-Path $botDir "go.ps1")
        Assert-PathExists -Name ".bot/README.md exists" -Path (Join-Path $botDir "README.md")

        # MCP server script
        Assert-PathExists -Name "dotbot-mcp.ps1 exists" -Path (Join-Path $botDir "systems\mcp\dotbot-mcp.ps1")

        # .mcp.json
        $mcpJson = Join-Path $testProject ".mcp.json"
        Assert-PathExists -Name ".mcp.json created" -Path $mcpJson
        Assert-ValidJson -Name ".mcp.json is valid JSON" -Path $mcpJson
        if (Test-Path $mcpJson) {
            $mcpConfig = Get-Content $mcpJson -Raw | ConvertFrom-Json
            Assert-True -Name ".mcp.json has dotbot server" `
                -Condition ($null -ne $mcpConfig.mcpServers.dotbot) `
                -Message "dotbot server entry missing"
            Assert-True -Name ".mcp.json has context7 server" `
                -Condition ($null -ne $mcpConfig.mcpServers.context7) `
                -Message "context7 server entry missing"
            Assert-True -Name ".mcp.json has playwright server" `
                -Condition ($null -ne $mcpConfig.mcpServers.playwright) `
                -Message "playwright server entry missing"
        }

        # .claude directory (created by init.ps1)
        $claudeDir = Join-Path $testProject ".claude"
        Assert-PathExists -Name ".claude directory created" -Path $claudeDir

    } finally {
        Remove-TestProject -Path $testProject
    }

    # --- Init with -Force (preserves workspace data) ---
    Write-Host ""
    Write-Host "  INIT -FORCE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $testProject2 = New-TestProject
    try {
        # First init
        Push-Location $testProject2
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
        Pop-Location

        $botDir2 = Join-Path $testProject2 ".bot"

        # Create a dummy file in workspace to verify preservation
        $dummyFile = Join-Path $botDir2 "workspace\tasks\todo\test-task.json"
        @{ id = "test-123"; name = "Dummy task" } | ConvertTo-Json | Set-Content -Path $dummyFile

        # Create a dummy settings file in .control to verify preservation
        $controlDir = Join-Path $botDir2 ".control"
        if (-not (Test-Path $controlDir)) { New-Item -Path $controlDir -ItemType Directory -Force | Out-Null }
        $dummySettings = Join-Path $controlDir "settings.json"
        @{ anthropic_api_key = "sk-test-dummy" } | ConvertTo-Json | Set-Content -Path $dummySettings

        # Re-init with -Force
        Push-Location $testProject2
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Force 2>&1 | Out-Null
        Pop-Location

        Assert-PathExists -Name "-Force: .bot still exists" -Path $botDir2
        Assert-PathExists -Name "-Force: workspace task preserved" -Path $dummyFile
        Assert-PathExists -Name "-Force: .control/settings.json preserved" -Path $dummySettings
        Assert-PathExists -Name "-Force: system files refreshed" -Path (Join-Path $botDir2 "systems\mcp\dotbot-mcp.ps1")

    } finally {
        Remove-TestProject -Path $testProject2
    }

    # --- Init with -Profile dotnet ---
    Write-Host ""
    Write-Host "  INIT -PROFILE (single stack)" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $dotnetProfile = Join-Path $dotbotDir "profiles\dotnet"
    if (Test-Path $dotnetProfile) {
        $testProject3 = New-TestProject
        try {
            Push-Location $testProject3
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Profile dotnet 2>&1 | Out-Null
            Pop-Location

            $botDir3 = Join-Path $testProject3 ".bot"
            Assert-PathExists -Name "-Profile: .bot created with dotnet profile" -Path $botDir3

            # Check that dotnet-specific files exist (look for any file from the dotnet profile)
            # Exclude profile-init.ps1 and profile.yaml which are intentionally not copied
            $dotnetFiles = Get-ChildItem -Path $dotnetProfile -Recurse -File | Where-Object { $_.Name -ne "profile-init.ps1" -and $_.Name -ne "profile.yaml" }
            if ($dotnetFiles.Count -gt 0) {
                $firstFile = $dotnetFiles[0]
                $relativePath = $firstFile.FullName.Substring($dotnetProfile.Length + 1)
                $expectedPath = Join-Path $botDir3 $relativePath
                Assert-PathExists -Name "-Profile: dotnet overlay file present ($relativePath)" -Path $expectedPath
            }

        } finally {
            Remove-TestProject -Path $testProject3
        }
    } else {
        Write-TestResult -Name "-Profile dotnet tests" -Status Skip -Message "dotnet profile not found at $dotnetProfile"
    }

    # --- Init with -Profile multi-repo,dotnet-blazor (taxonomy + extends) ---
    Write-Host ""
    Write-Host "  INIT -PROFILE (workflow + stack with extends)" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $multiRepoProfile = Join-Path $dotbotDir "profiles\multi-repo"
    $dotnetBlazorProfile = Join-Path $dotbotDir "profiles\dotnet-blazor"
    if ((Test-Path $multiRepoProfile) -and (Test-Path $dotnetBlazorProfile)) {
        $testProjectCombo = New-TestProject
        try {
            Push-Location $testProjectCombo
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Profile "multi-repo,dotnet-blazor" 2>&1 | Out-Null
            Pop-Location

            $botDirCombo = Join-Path $testProjectCombo ".bot"
            Assert-PathExists -Name "Combo: .bot created" -Path $botDirCombo

            # Multi-repo overlay applied (workflow override)
            Assert-PathExists -Name "Combo: multi-repo 98-analyse-task.md present" `
                -Path (Join-Path $botDirCombo "prompts\workflows\98-analyse-task.md")

            # dotnet auto-included via extends (dotnet-blazor extends dotnet)
            $dotnetSkillCheck = Join-Path $botDirCombo "prompts\skills\entity-design\SKILL.md"
            Assert-PathExists -Name "Combo: dotnet auto-included (entity-design skill)" -Path $dotnetSkillCheck

            # dotnet-blazor overlay applied
            $blazorSkillCheck = Join-Path $botDirCombo "prompts\skills\blazor-component-design\SKILL.md"
            Assert-PathExists -Name "Combo: dotnet-blazor skill present" -Path $blazorSkillCheck

            # Settings: profile should be 'multi-repo' and stacks should include dotnet + dotnet-blazor
            $settingsCombo = Join-Path $botDirCombo "defaults\settings.default.json"
            if (Test-Path $settingsCombo) {
                $sCombo = Get-Content $settingsCombo -Raw | ConvertFrom-Json
                Assert-Equal -Name "Combo: profile is 'multi-repo'" `
                    -Expected "multi-repo" -Actual $sCombo.profile
                Assert-True -Name "Combo: stacks includes 'dotnet'" `
                    -Condition ("dotnet" -in @($sCombo.stacks)) `
                    -Message "Expected 'dotnet' in stacks array, got: $($sCombo.stacks -join ', ')"
                Assert-True -Name "Combo: stacks includes 'dotnet-blazor'" `
                    -Condition ("dotnet-blazor" -in @($sCombo.stacks)) `
                    -Message "Expected 'dotnet-blazor' in stacks array, got: $($sCombo.stacks -join ', ')"
            }

            # profile.yaml should NOT be copied to .bot/
            Assert-PathNotExists -Name "Combo: profile.yaml not copied" `
                -Path (Join-Path $botDirCombo "profile.yaml")

        } finally {
            Remove-TestProject -Path $testProjectCombo
        }
    } else {
        Write-TestResult -Name "Combo profile tests" -Status Skip -Message "Required profiles not found"
    }

    # --- Init with -Profile multi-repo ---
    Write-Host ""
    Write-Host "  INIT -PROFILE multi-repo" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $multiRepoProfile = Join-Path $dotbotDir "profiles\multi-repo"
    if (Test-Path $multiRepoProfile) {
        $testProject4 = New-TestProject
        try {
            Push-Location $testProject4
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Profile multi-repo 2>&1 | Out-Null
            Pop-Location

            $botDir4 = Join-Path $testProject4 ".bot"
            Assert-PathExists -Name "-Profile multi-repo: .bot created" -Path $botDir4

            # Key overlay files
            Assert-PathExists -Name "-Profile multi-repo: 98-analyse-task.md (override)" `
                -Path (Join-Path $botDir4 "prompts\workflows\98-analyse-task.md")
            Assert-PathExists -Name "-Profile multi-repo: 00-kickstart-interview.md (override)" `
                -Path (Join-Path $botDir4 "prompts\workflows\00-kickstart-interview.md")
            Assert-PathExists -Name "-Profile multi-repo: 05-post-research-review.md (new)" `
                -Path (Join-Path $botDir4 "prompts\workflows\05-post-research-review.md")
            Assert-PathExists -Name "-Profile multi-repo: atlassian.md (new research dir)" `
                -Path (Join-Path $botDir4 "prompts\research\atlassian.md")
            Assert-PathExists -Name "-Profile multi-repo: repo-clone/script.ps1 (new tool)" `
                -Path (Join-Path $botDir4 "systems\mcp\tools\repo-clone\script.ps1")
            Assert-PathExists -Name "-Profile multi-repo: settings.default.json (replacement)" `
                -Path (Join-Path $botDir4 "defaults\settings.default.json")

            # profile-init.ps1 should NOT be copied to .bot/
            Assert-PathNotExists -Name "-Profile multi-repo: profile-init.ps1 not copied" `
                -Path (Join-Path $botDir4 "profile-init.ps1")

            # Verify hook config merge: 03-research-completeness.ps1 present
            $verifyConfig4 = Join-Path $botDir4 "hooks\verify\config.json"
            Assert-ValidJson -Name "-Profile multi-repo: verify config.json is valid JSON" -Path $verifyConfig4
            if (Test-Path $verifyConfig4) {
                $config4 = Get-Content $verifyConfig4 -Raw | ConvertFrom-Json
                $scriptNames4 = $config4.scripts | ForEach-Object { $_.name }
                Assert-True -Name "-Profile multi-repo: verify config has 03-research-completeness.ps1" `
                    -Condition ("03-research-completeness.ps1" -in $scriptNames4) `
                    -Message "03-research-completeness.ps1 not found in merged config"
            }

            # Settings validation
            $settingsPath4 = Join-Path $botDir4 "defaults\settings.default.json"
            Assert-ValidJson -Name "-Profile multi-repo: settings is valid JSON" -Path $settingsPath4
            if (Test-Path $settingsPath4) {
                $settings4 = Get-Content $settingsPath4 -Raw | ConvertFrom-Json

                Assert-True -Name "-Profile multi-repo: task_categories has 5 values" `
                    -Condition ($settings4.task_categories.Count -eq 5) `
                    -Message "Expected 5 categories, got $($settings4.task_categories.Count)"

                Assert-Equal -Name "-Profile multi-repo: branch_prefix is 'initiative'" `
                    -Expected "initiative" -Actual $settings4.azure_devops.branch_prefix

                Assert-Equal -Name "-Profile multi-repo: max_pages_to_read is 10" `
                    -Expected 10 -Actual $settings4.atlassian.max_pages_to_read

                # Verify kickstart phases include jira-context as first phase
                $phaseIds = $settings4.kickstart.phases | ForEach-Object { $_.id }
                Assert-Equal -Name "-Profile multi-repo: first phase is 'jira-context'" `
                    -Expected "jira-context" -Actual $phaseIds[0]

                # Verify post-research-review phase exists as LLM type (not interview)
                $reviewPhase = $settings4.kickstart.phases | Where-Object { $_.id -eq 'post-research-review' }
                Assert-True -Name "-Profile multi-repo: post-research-review phase exists" `
                    -Condition ($null -ne $reviewPhase) `
                    -Message "post-research-review phase not found in kickstart.phases"
                if ($reviewPhase) {
                    Assert-Equal -Name "-Profile multi-repo: post-research-review type is 'llm'" `
                        -Expected "llm" -Actual $reviewPhase.type
                }
            }

            # Sample task JSONs are valid
            $samplesDir4 = Join-Path $botDir4 "workspace\tasks\samples"
            if (Test-Path $samplesDir4) {
                $sampleFiles4 = Get-ChildItem -Path $samplesDir4 -Filter "*.json" -ErrorAction SilentlyContinue
                foreach ($sample in $sampleFiles4) {
                    Assert-ValidJson -Name "-Profile multi-repo: sample $($sample.Name) is valid JSON" -Path $sample.FullName
                }
            }

            # All .ps1 files in the profile source are valid PowerShell
            $allPs1Files = Get-ChildItem -Path $multiRepoProfile -Filter "*.ps1" -Recurse
            foreach ($ps1 in $allPs1Files) {
                $relPath = $ps1.FullName.Substring($multiRepoProfile.Length + 1)
                Assert-ValidPowerShell -Name "-Profile multi-repo: $relPath valid syntax" -Path $ps1.FullName
            }

        } finally {
            Remove-TestProject -Path $testProject4
        }
    } else {
        Write-TestResult -Name "-Profile multi-repo tests" -Status Skip -Message "multi-repo profile not found at $multiRepoProfile"
    }

    # --- Verification Hook: 03-research-completeness.ps1 ---
    Write-Host ""
    Write-Host "  VERIFICATION HOOK" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $hookScript = Join-Path $dotbotDir "profiles\multi-repo\hooks\verify\03-research-completeness.ps1"
    if (Test-Path $hookScript) {
        $testProject5 = New-TestProject
        try {
            # Init with multi-repo profile
            Push-Location $testProject5
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Profile multi-repo 2>&1 | Out-Null
            Pop-Location

            $botDir5 = Join-Path $testProject5 ".bot"
            $briefingDir5 = Join-Path $botDir5 "workspace\product\briefing"
            $productDir5 = Join-Path $botDir5 "workspace\product"
            $hookCopy5 = Join-Path $botDir5 "hooks\verify\03-research-completeness.ps1"

            if (Test-Path $hookCopy5) {
                # Scenario 1: No artifacts → exit 1 (missing initiative.md)
                $result1 = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "
                    `$global:DotbotProjectRoot = '$($testProject5 -replace "'","''")'
                    & '$($hookCopy5 -replace "'","''")'
                " 2>&1
                $exitCode1 = $LASTEXITCODE
                Assert-Equal -Name "Hook: no artifacts -> exit 1" -Expected 1 -Actual $exitCode1

                # Scenario 2: Only jira-context.md → exit 0 with warnings
                New-Item -Path $briefingDir5 -ItemType Directory -Force | Out-Null
                "# Jira Context" | Set-Content (Join-Path $briefingDir5 "jira-context.md")

                $result2 = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "
                    `$global:DotbotProjectRoot = '$($testProject5 -replace "'","''")'
                    & '$($hookCopy5 -replace "'","''")'
                " 2>&1
                $exitCode2 = $LASTEXITCODE
                Assert-Equal -Name "Hook: only jira-context.md -> exit 0" -Expected 0 -Actual $exitCode2

                # Scenario 3: All artifacts present → exit 0, success message
                "# Interview" | Set-Content (Join-Path $productDir5 "interview-summary.md")
                "# Mission" | Set-Content (Join-Path $productDir5 "mission.md")
                "# Internet" | Set-Content (Join-Path $productDir5 "research-internet.md")
                "# Documents" | Set-Content (Join-Path $productDir5 "research-documents.md")
                "# Repos" | Set-Content (Join-Path $productDir5 "research-repos.md")
                New-Item -Path (Join-Path $briefingDir5 "repos") -ItemType Directory -Force | Out-Null
                "# Deep dive" | Set-Content (Join-Path $briefingDir5 "repos\FakeRepo.md")

                $result3 = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "
                    `$global:DotbotProjectRoot = '$($testProject5 -replace "'","''")'
                    & '$($hookCopy5 -replace "'","''")'
                " 2>&1
                $exitCode3 = $LASTEXITCODE
                Assert-Equal -Name "Hook: all artifacts -> exit 0" -Expected 0 -Actual $exitCode3

                $output3 = $result3 -join "`n"
                Assert-True -Name "Hook: all artifacts -> success message" `
                    -Condition ($output3 -match "All research artifacts present") `
                    -Message "Expected 'All research artifacts present' in output"
            } else {
                Write-TestResult -Name "Hook tests" -Status Skip -Message "Hook not copied to .bot/"
            }

        } finally {
            Remove-TestProject -Path $testProject5
        }
    } else {
        Write-TestResult -Name "Verification hook tests" -Status Skip -Message "Hook script not found at $hookScript"
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PLATFORM FUNCTIONS
# ═══════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════
# PROFILE TAXONOMY (profile.yaml manifests)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROFILE TAXONOMY" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$profilesSourceDir = Join-Path $repoRoot "profiles"
$nonDefaultProfiles = Get-ChildItem -Path $profilesSourceDir -Directory | Where-Object { $_.Name -ne "default" }

foreach ($profileDir in $nonDefaultProfiles) {
    $yamlPath = Join-Path $profileDir.FullName "profile.yaml"
    Assert-PathExists -Name "profile.yaml exists: $($profileDir.Name)" -Path $yamlPath

    if (Test-Path $yamlPath) {
        $content = Get-Content $yamlPath -Raw
        Assert-True -Name "profile.yaml has 'type': $($profileDir.Name)" `
            -Condition ($content -match 'type:\s*(workflow|stack)') `
            -Message "'type' must be 'workflow' or 'stack'"
        Assert-True -Name "profile.yaml has 'name': $($profileDir.Name)" `
            -Condition ($content -match 'name:\s*\S+') `
            -Message "Missing 'name' field"
        Assert-True -Name "profile.yaml has 'description': $($profileDir.Name)" `
            -Condition ($content -match 'description:\s*\S+') `
            -Message "Missing 'description' field"

        # If extends is declared, the parent profile must exist
        if ($content -match 'extends:\s*(\S+)') {
            $parentName = $Matches[1]
            $parentDir = Join-Path $profilesSourceDir $parentName
            Assert-PathExists -Name "extends target exists: $($profileDir.Name) -> $parentName" -Path $parentDir
        }
    }
}

Write-Host ""

Write-Host "  PLATFORM FUNCTIONS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$platformModule = Join-Path $repoRoot "scripts\Platform-Functions.psm1"
Import-Module $platformModule -Force

# Get-PlatformName returns correct OS
$platformName = Get-PlatformName
$expectedPlatform = if ($IsWindows) { "Windows" } elseif ($IsMacOS) { "macOS" } elseif ($IsLinux) { "Linux" } else { "Unknown" }
Assert-Equal -Name "Get-PlatformName returns '$expectedPlatform'" -Expected $expectedPlatform -Actual $platformName

# Add-ToPath with -DryRun doesn't crash
try {
    Add-ToPath -Directory "/tmp/dotbot-test-path" -DryRun 2>&1 | Out-Null
    Assert-True -Name "Add-ToPath -DryRun doesn't crash" -Condition $true
} catch {
    Write-TestResult -Name "Add-ToPath -DryRun doesn't crash" -Status Fail -Message $_.Exception.Message
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# GLOBAL INITIALIZATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  GLOBAL INITIALIZATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Find all scripts that dot-source MCP tool scripts (scan repo source, not installed copy)
$profilesDir = Join-Path $repoRoot "profiles"
$allScripts = Get-ChildItem -Path $profilesDir -Filter "*.ps1" -Recurse
$toolSourcePattern = '\.\s+.*tools[\\/][^\\/]+[\\/]script\.ps1'
$globalSetPattern = '\$global:DotbotProjectRoot\s*='

foreach ($script in $allScripts) {
    # Skip the tool scripts themselves
    if ($script.FullName -match 'tools[\\/][^\\/]+[\\/]script\.ps1') { continue }

    $content = Get-Content $script.FullName -Raw
    if ($content -match $toolSourcePattern) {
        $setsGlobal = $content -match $globalSetPattern
        $relativePath = $script.FullName.Substring($profilesDir.Length + 1)
        Assert-True -Name "$relativePath sets DotbotProjectRoot" `
            -Condition $setsGlobal `
            -Message "File dot-sources tool scripts but never sets `$global:DotbotProjectRoot"
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PROVIDER CONFIG FILES
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROVIDER CONFIGS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$providersDir = Join-Path $repoRoot "profiles\default\defaults\providers"

foreach ($providerName in @("claude", "codex", "gemini")) {
    $providerFile = Join-Path $providersDir "$providerName.json"
    Assert-True -Name "Provider config exists: $providerName.json" `
        -Condition (Test-Path $providerFile) `
        -Message "Expected $providerFile"

    if (Test-Path $providerFile) {
        $parsed = $null
        try { $parsed = Get-Content $providerFile -Raw | ConvertFrom-Json } catch {}
        Assert-True -Name "Provider config parses: $providerName.json" `
            -Condition ($null -ne $parsed) `
            -Message "JSON parse failed"

        if ($parsed) {
            Assert-True -Name "Provider $providerName has 'name' field" `
                -Condition ($parsed.name -eq $providerName) `
                -Message "Expected name='$providerName', got '$($parsed.name)'"

            Assert-True -Name "Provider $providerName has 'models'" `
                -Condition ($null -ne $parsed.models) `
                -Message "Missing models object"

            Assert-True -Name "Provider $providerName has 'executable'" `
                -Condition ($null -ne $parsed.executable -and $parsed.executable.Length -gt 0) `
                -Message "Missing executable"

            Assert-True -Name "Provider $providerName has 'stream_parser'" `
                -Condition ($null -ne $parsed.stream_parser) `
                -Message "Missing stream_parser"
        }
    }
}

# Settings has provider field
$settingsFile = Join-Path $repoRoot "profiles\default\defaults\settings.default.json"
if (Test-Path $settingsFile) {
    $settingsData = Get-Content $settingsFile -Raw | ConvertFrom-Json
    Assert-True -Name "settings.default.json has 'provider' field" `
        -Condition ($null -ne $settingsData.provider) `
        -Message "Missing 'provider' top-level field"
}

# ProviderCLI module exists
$providerCliModule = Join-Path $repoRoot "profiles\default\systems\runtime\ProviderCLI\ProviderCLI.psm1"
Assert-True -Name "ProviderCLI.psm1 exists" `
    -Condition (Test-Path $providerCliModule) `
    -Message "Expected $providerCliModule"

# Stream parsers exist
foreach ($parserName in @("Claude", "Codex", "Gemini")) {
    $parserFile = Join-Path $repoRoot "profiles\default\systems\runtime\ProviderCLI\parsers\Parse-${parserName}Stream.ps1"
    Assert-True -Name "Stream parser exists: Parse-${parserName}Stream.ps1" `
        -Condition (Test-Path $parserFile) `
        -Message "Expected $parserFile"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 1: Structure"

if (-not $allPassed) {
    exit 1
}
