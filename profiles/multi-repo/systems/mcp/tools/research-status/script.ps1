function Invoke-ResearchStatus {
    param([hashtable]$Arguments)

    $briefingDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\product\briefing"
    $productDir  = Join-Path $global:DotbotProjectRoot ".bot\workspace\product"

    # ---------------------------------------------------------------------------
    # Check core artifacts
    # ---------------------------------------------------------------------------
    $coreArtifacts = @(
        @{ Name = "initiative.md";            Phase = "Phase 0";  Required = $true  }
        @{ Name = "00_CURRENT_STATUS.md";     Phase = "Phase 1";  Required = $true  }
        @{ Name = "01_INTERNET_RESEARCH.md";  Phase = "Phase 1";  Required = $true  }
        @{ Name = "02_REPOS_AFFECTED.md";     Phase = "Phase 1";  Required = $true  }
        @{ Name = "03_CROSS_CUTTING_CONCERNS.md"; Phase = "Phase 3"; Required = $false }
        @{ Name = "04_IMPLEMENTATION_RESEARCH.md"; Phase = "Phase 2b"; Required = $false }
        @{ Name = "05_DEPENDENCY_MAP.md";     Phase = "Phase 3";  Required = $false }
        @{ Name = "06_OPEN_QUESTIONS.md";     Phase = "Phase 3";  Required = $false }
    )

    $artifacts = @()
    $existCount = 0
    $requiredMissing = @()

    foreach ($a in $coreArtifacts) {
        $path = Join-Path $briefingDir $a.Name
        $exists = Test-Path $path
        if ($exists) { $existCount++ }
        if ($a.Required -and -not $exists) { $requiredMissing += $a.Name }

        $artifacts += @{
            name     = $a.Name
            phase    = $a.Phase
            exists   = $exists
            required = $a.Required
        }
    }

    # ---------------------------------------------------------------------------
    # Check product docs
    # ---------------------------------------------------------------------------
    $productDocs = @(
        @{ Name = "mission.md";           Phase = "Phase 0.5" }
        @{ Name = "roadmap-overview.md";  Phase = "Phase 0.5" }
        @{ Name = "tech-stack.md";        Phase = "Phase 3"   }
    )

    $productArtifacts = @()
    foreach ($d in $productDocs) {
        $path = Join-Path $productDir $d.Name
        $productArtifacts += @{
            name   = $d.Name
            phase  = $d.Phase
            exists = Test-Path $path
        }
    }

    # ---------------------------------------------------------------------------
    # Check deep dive reports
    # ---------------------------------------------------------------------------
    $reposDir = Join-Path $briefingDir "repos"
    $deepDives = @()
    $indexExists = $false

    if (Test-Path $reposDir) {
        $files = Get-ChildItem -Path $reposDir -Filter "*.md" -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.Name -eq "00_INDEX.md") {
                $indexExists = $true
            } else {
                $deepDives += @{
                    repo = $f.BaseName
                    path = $f.FullName
                }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Determine overall phase
    # ---------------------------------------------------------------------------
    $phase = "not-started"
    $initiativeExists = Test-Path (Join-Path $briefingDir "initiative.md")
    $missionExists    = Test-Path (Join-Path $productDir "mission.md")
    $researchComplete = (Test-Path (Join-Path $briefingDir "00_CURRENT_STATUS.md")) -and
                        (Test-Path (Join-Path $briefingDir "01_INTERNET_RESEARCH.md")) -and
                        (Test-Path (Join-Path $briefingDir "02_REPOS_AFFECTED.md"))
    $implResearchExists = Test-Path (Join-Path $briefingDir "04_IMPLEMENTATION_RESEARCH.md")

    if ($initiativeExists) { $phase = "kickstarted" }
    if ($missionExists)    { $phase = "planned" }
    if ($researchComplete) { $phase = "research-complete" }
    if ($deepDives.Count -gt 0) { $phase = "deep-dives-in-progress" }
    if ($implResearchExists) { $phase = "implementation-research-complete" }
    if ($indexExists)      { $phase = "refined" }

    # ---------------------------------------------------------------------------
    # Return result
    # ---------------------------------------------------------------------------
    return @{
        success           = $true
        phase             = $phase
        core_artifacts    = $artifacts
        product_docs      = $productArtifacts
        deep_dives        = $deepDives
        deep_dive_count   = $deepDives.Count
        index_exists      = $indexExists
        artifacts_found   = $existCount
        artifacts_total   = $coreArtifacts.Count
        required_missing  = $requiredMissing
        message           = if ($requiredMissing.Count -eq 0) {
            "All required artifacts present. Phase: $phase. $($deepDives.Count) deep dive(s) complete."
        } else {
            "Missing required: $($requiredMissing -join ', '). Phase: $phase."
        }
    }
}
