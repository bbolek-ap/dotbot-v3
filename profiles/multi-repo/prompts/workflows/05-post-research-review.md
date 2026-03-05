---
name: Post-Research Review
description: Consolidate research outputs into a summary with key findings, gaps, risks, and recommendations
version: 1.0
---

# Post-Research Review

After all research tasks have completed, this workflow consolidates findings into a structured summary. Unlike a repeat interview, this phase reads actual research outputs and synthesises them.

## Prerequisites

- `briefing/jira-context.md` must exist
- `mission.md` must exist
- At least some research outputs should exist (research-internet.md, research-documents.md, research-repos.md)

## Your Task

### Step 1: Read All Research Artifacts

Read the following files (skip any that don't exist):

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/mission.md" })
Read({ file_path: ".bot/workspace/product/roadmap-overview.md" })
Read({ file_path: ".bot/workspace/product/research-internet.md" })
Read({ file_path: ".bot/workspace/product/research-documents.md" })
Read({ file_path: ".bot/workspace/product/research-repos.md" })
```

Also check for deep-dive reports:
```
Glob({ pattern: "*.md", path: ".bot/workspace/product/briefing/repos" })
```

Read any `*.md` files found in that directory.

### Step 2: Write Research Summary

Write `.bot/workspace/product/research-summary.md` with the following structure:

```markdown
# Research Summary

## Executive Overview

{2-3 paragraph synthesis of all research findings — what was the initiative about, what did research discover, and what's the overall recommendation}

## Key Findings

### From Public/Internet Research
- {Bullet points of key findings from research-internet.md}

### From Documentation Research
- {Bullet points of key findings from research-documents.md}

### From Repository Research
- {Bullet points of key findings from research-repos.md}

### From Deep Dives
- {Bullet points of key findings from each deep dive report}

## Gaps & Open Questions

| # | Gap | Severity | Source | Recommendation |
|---|-----|----------|--------|----------------|
(Gaps identified across all research — things that remain unknown or unclear)

## Risks & Concerns

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|------------|--------|------------|
(Technical risks, dependency risks, complexity risks identified in research)

## Recommendations

### Implementation Approach
{Recommended approach based on research findings}

### Priority Order
{Suggested priority order for implementation based on dependencies and risk}

### Prerequisites
{Things that must be in place before implementation can begin}

## Research Coverage

| Artifact | Status | Key Insights |
|----------|--------|-------------|
| research-internet.md | {exists/missing} | {1-line summary} |
| research-documents.md | {exists/missing} | {1-line summary} |
| research-repos.md | {exists/missing} | {1-line summary} |
| Deep dives | {count found} | {1-line summary} |
```

### Step 3: Check for Blocking Ambiguities

If there are critical gaps that would prevent implementation planning (e.g., unclear scope, missing architectural decisions, unresolved technical approach), write `.bot/workspace/product/clarification-questions.json`:

```json
{
  "questions": [
    {
      "id": "q1",
      "question": "Specific question about a blocking gap",
      "context": "What research found and why this needs clarification",
      "options": [
        { "key": "A", "label": "Option label", "rationale": "Why this option" },
        { "key": "B", "label": "Option label", "rationale": "Why this option" }
      ],
      "recommendation": "A"
    }
  ]
}
```

Only write clarification questions for **blocking** gaps — things that genuinely prevent moving forward. Non-blocking uncertainties should be noted in the Gaps table but don't need user input.

If there are no blocking gaps, do NOT write clarification-questions.json.

## Critical Rules

- Read actual research outputs — do NOT re-fetch data from Jira or Confluence
- Do NOT duplicate the kickstart interview — this phase summarises what was already researched
- Always write `research-summary.md`
- Only write `clarification-questions.json` if there are genuinely blocking ambiguities
- Do NOT create any other files (no mission.md updates, no new research files)
- Do NOT use task management tools
