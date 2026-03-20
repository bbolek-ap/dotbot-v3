#Requires -Version 7.0

function Invoke-AnalyseProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProcId,
        [Parameter(Mandatory)][hashtable]$ProcessData,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProcessesDir,
        [string]$ControlDir,
        [Parameter(Mandatory)][string]$ClaudeModelName,
        [Parameter(Mandatory)][string]$ClaudeSessionId,
        [string]$Prompt,
        [string]$Description,
        [switch]$ShowDebug,
        [switch]$ShowVerbose
    )

    $processData = $ProcessData

    if (-not $Description) { $Description = "Analyse existing project" }

    $processData.status = 'running'
    $processData.workflow = "analyse-pipeline"
    $processData.description = $Description
    $processData.heartbeat_status = $Description
    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "$Description started" -ProcessesDir $ProcessesDir

    $productDir = Join-Path $BotRoot "workspace\product"

    try {
        # ===== Phase 1 (only phase): Scan repo and create product documents =====
        $processData.heartbeat_status = "Scanning repository and creating product documents"
        Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
        Write-ProcessActivity -Id $ProcId -ActivityType "init" -Message "Scanning repository and creating product documents..." -ProcessesDir $ProcessesDir
        Write-Header "Analyse: Product Documents"

        $workflowContent = ""
        $workflowPath = Join-Path $BotRoot "prompts\workflows\01-plan-product.md"
        if (Test-Path $workflowPath) {
            $workflowContent = Get-Content $workflowPath -Raw
        }

        # Build optional user guidance
        $userGuidance = ""
        if ($Prompt) {
            $userGuidance = @"

## User Guidance

The user has provided the following guidance for the analysis:
$Prompt
"@
        }

        $analysePrompt = @"
You are a product analysis assistant for the dotbot autonomous development system.

Your task is to thoroughly analyse an EXISTING codebase and create foundational product documents that describe what this project is and how it works.

Follow this workflow for guidance on document structure:
$workflowContent

## Repo Scan Instructions

This is an existing project with real code. You MUST explore it thoroughly before writing documents:

1. **Directory structure**: List the full directory tree to understand project layout
2. **README and docs**: Read README.md, any docs/ folder, CONTRIBUTING.md, etc.
3. **Config files**: Read package.json, Cargo.toml, go.mod, *.csproj, pyproject.toml, or whatever build/dependency files exist
4. **Entry points**: Identify and read main entry points (main.*, index.*, app.*, Program.*, etc.)
5. **Source code**: Browse through src/, lib/, or equivalent directories to understand the architecture
6. **Tests**: Check test files to understand expected behavior
7. **Data/schemas**: Look for database migrations, schema files, API definitions

Base your product documents entirely on what you discover in the codebase. Do NOT guess or use generic templates.
$userGuidance

Instructions:
1. Scan the repository thoroughly using the steps above
2. Create these product documents directly by writing files to .bot/workspace/product/:
   - mission.md - What the product is, core principles, goals (derived from actual code). MUST start with a section titled "Executive Summary" as the first heading.
   - tech-stack.md - Technologies, versions, infrastructure decisions (from actual dependencies)
   - entity-model.md - Data model, entities, relationships (from actual code/schemas). Include a Mermaid.js erDiagram block.
3. Do NOT create tasks, ask questions, or use task management tools. Just create the documents directly.
4. Write comprehensive, well-structured markdown documents based on what you discover.

IMPORTANT: The mission.md file MUST begin with an "Executive Summary" section (## Executive Summary) as the very first content after the title. This is required for the UI to detect that product planning is complete.
"@

        $streamArgs = @{
            Prompt = $analysePrompt
            Model = $ClaudeModelName
            SessionId = $ClaudeSessionId
            PersistSession = $false
        }
        if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

        Invoke-ProviderStream @streamArgs

        # Verify product docs were created
        $hasDocs = (Test-Path (Join-Path $productDir "mission.md")) -and
                   (Test-Path (Join-Path $productDir "tech-stack.md")) -and
                   (Test-Path (Join-Path $productDir "entity-model.md"))

        if (-not $hasDocs) {
            throw "Analyse failed: product documents were not created"
        }

        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Analyse complete - product documents created" -ProcessesDir $ProcessesDir

        $processData.status = 'completed'
        $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.heartbeat_status = "Completed: $Description"
    } catch {
        $processData.status = 'failed'
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.error = $_.Exception.Message
        $processData.heartbeat_status = "Failed: $($_.Exception.Message)"
        Write-Status "Process failed: $($_.Exception.Message)" -Type Error
    }

    Write-ProcessFile -Id $ProcId -Data $processData -ProcessesDir $ProcessesDir
    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Process $ProcId finished ($($processData.status))" -ProcessesDir $ProcessesDir
}
