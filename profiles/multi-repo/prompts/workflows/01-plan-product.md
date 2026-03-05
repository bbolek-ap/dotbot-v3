---
name: Plan Product (Multi-Repo)
description: Override — brownfield product docs from initiative context instead of greenfield planning
version: 1.0
---

# Product Planning Workflow (Multi-Repo Override)

This workflow creates **brownfield-appropriate product documents** from the initiative context gathered during kickstart. Unlike the default greenfield planning (mission + tech-stack + entity-model), this creates documents suited for cross-repo initiative planning.

## Goal

Create two product documents:
1. **mission.md** — Specification derived from Jira description + business objective + Confluence docs
2. **roadmap-overview.md** — The research plan: what research tasks to create, their timeline, and dependencies

**Does NOT create:**
- `tech-stack.md` — Deferred to Phase 3 (refine-artifacts). Tech stacks can only be determined after deep dives reveal the actual technologies per repo.
- `entity-model.md` — Not applicable for brownfield. There is no single entity model across repos.

## Process

### Step 1: Read Initiative Context

Read the briefing files created by Phase 0 (kickstart):

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/interview-summary.md" })
```

Extract:
- Business objective → core mission
- Components & labels → scope boundaries
- Child and linked issues → existing work breakdown
- Confluence documentation → additional specifications
- Reference implementation → comparison baseline
- Programme context → strategic alignment

### Step 2: Read Uploaded Files

Check `.bot/workspace/product/briefing/` for any additional files uploaded by the user. These may include specs, requirements, regulatory documents, or design references.

### Step 3: Create `mission.md`

Write `.bot/workspace/product/mission.md` with:

**IMPORTANT:** The file MUST begin with `## Executive Summary` as the first section after the title. The UI depends on this heading to detect that product planning is complete.

```markdown
# Mission: {INITIATIVE_NAME}

## Executive Summary

2-3 sentence overview of what this initiative aims to achieve, the business driver, and the expected outcome. Derived from the Jira description and Confluence documentation.

## Business Objective

Expanded description of the business need, regulatory requirements, or strategic goal driving this initiative. Include timeline pressures, compliance deadlines, or market drivers.

## Scope

### In Scope
- Systems and repos expected to be affected
- Types of changes anticipated (code, configuration, database, infrastructure)
- Integration points

### Out of Scope
- What this initiative explicitly does NOT cover
- Adjacent work that should be separate initiatives

### Assumptions
- Key assumptions about the environment, dependencies, and constraints

## Success Criteria

- Measurable outcomes that define "done" for this initiative
- Compliance or certification requirements
- Performance targets

## Constraints

- Timeline constraints (regulatory deadlines, programme milestones)
- Technical constraints (platform versions, compatibility requirements)
- Organisational constraints (team availability, budget, approvals)

## Reference Implementation

- Which existing implementation serves as the template
- Key similarities and differences
- Lessons from the reference that apply here

## Stakeholders

| Role | Name | Responsibility |
|------|------|----------------|
(from jira-context.md team section)

## Related Documentation

- Links to Jira tickets, Confluence pages, and other references
(from jira-context.md)
```

### Step 4: Create `roadmap-overview.md`

Write `.bot/workspace/product/roadmap-overview.md` with the research plan:

```markdown
# Roadmap Overview: {INITIATIVE_NAME}

## Research Plan

This document outlines the research phases that will inform the implementation plan.

### Phase 1: Foundational Research

Three parallel/sequential research tasks:

| # | Task | Methodology | Dependencies | Output |
|---|------|-------------|--------------|--------|
| 1 | Atlassian Research | `atlassian.md` | None | `research-documents.md` |
| 2 | Public/Regulatory Research | `public.md` | None | `research-internet.md` |
| 3 | Repository Impact Scan | `repos.md` | Tasks 1, 2 | `research-repos.md` |

### Phase 2: Deep Dives

Per-repo deep dives for MEDIUM+ impact repos (created after Phase 1 completes):

- Each repo gets a `repo-deep-dive.md` methodology task
- Output: `briefing/repos/{RepoName}.md` per repo
- Repos are cloned to `repos/{RepoName}/` on initiative branches

### Phase 2b-2c: Implementation Research & Planning

- Synthesize deep dives into `04_IMPLEMENTATION_RESEARCH.md`
- Create per-repo code-level plans: `{RepoName}_Plan.md`

### Phase 3: Artifact Refinement

- Cross-reference all findings
- Generate `03_CROSS_CUTTING_CONCERNS.md`, `05_DEPENDENCY_MAP.md`, `06_OPEN_QUESTIONS.md`
- Update `mission.md` with refined understanding
- Create `tech-stack.md` reverse-engineered from repo deep dives

### Phase 4: Publish to Atlassian

- Create/update Jira epic structure
- Post research to Confluence
- Link tickets to pages

### Phase 5-6: Implementation & Remediation

- Per-repo implementation from plans
- Build/test verification and fixes
- Outcomes and remediation documents per repo

### Phase 7: Handoff

- Per-repo handoff documents with individual tasks
- Push initiative branches
- Create draft PRs

## Timeline Considerations

- Research phases (1-3) can often proceed in days, not weeks
- Implementation timeline depends on deep dive findings
- Remediation time is unpredictable — budget for iteration

## Key Dependencies

- Atlassian MCP server availability (Phase 0, Phase 4)
- Azure DevOps access and PAT configuration (Phase 2+)
- External provider/vendor timelines (may block implementation)
- Stakeholder availability for open questions (Phase 3)
```

## Clarifying Questions

This workflow does NOT ask clarifying questions in interactive mode. The initiative context from Atlassian provides sufficient direction. If critical information is missing, it will be marked as `<!-- UNRESOLVED -->` in the jira-context.md and addressed during research.

## Output Location

All files go in `.bot/workspace/product/`:
- `.bot/workspace/product/mission.md`
- `.bot/workspace/product/roadmap-overview.md`

## Success Criteria

- Two markdown files created
- `mission.md` starts with `## Executive Summary` section
- Content is derived from initiative context (not generic templates)
- Roadmap reflects the multi-repo research lifecycle
- No `tech-stack.md` or `entity-model.md` created
