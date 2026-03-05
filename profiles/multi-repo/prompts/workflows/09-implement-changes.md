---
name: Implement Changes
description: Execute per-repo implementation from plans, commit to initiative branches, produce outcomes
version: 1.0
---

# Implement Changes

Execute the implementation plans for each affected repository. All changes are committed to the `initiative/{JIRA_KEY}` branch created at clone time.

## Prerequisites

- Implementation plans must exist: `repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md`
- Repos must be cloned to `repos/{RepoName}/` with initiative branch checked out
- `jira-context.md` must exist
- `04_IMPLEMENTATION_RESEARCH.md` should exist for cross-repo context

## Your Task

### Step 1: Read Context

```
Read({ file_path: ".bot/workspace/product/briefing/jira-context.md" })
Read({ file_path: ".bot/workspace/product/briefing/04_IMPLEMENTATION_RESEARCH.md" })
```

Check repo status:
```
mcp__dotbot__repo_list({})
```

### Step 2: Determine Implementation Order

Read the dependency map if it exists:
```
Read({ file_path: ".bot/workspace/product/briefing/05_DEPENDENCY_MAP.md" })
```

Follow the recommended implementation sequence. If no dependency map exists, implement in tier order (Tier 1 first).

### Step 3: Create Per-Repo Implementation Tasks

For each repo with a plan, create implementation tasks via `task_create_bulk`:

```
mcp__dotbot__task_create_bulk({
  tasks: [
    {
      "name": "Implement changes in {RepoName}",
      "description": "Execute the implementation plan for {RepoName}. Follow {RepoName}_Plan.md. Commit all changes to the initiative branch.\n\nPlan: repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md\nOutput: repos/{RepoName}/.bot/workspace/product/{RepoName}_Outcomes.md",
      "category": "implementation",
      "effort": "{FROM_PLAN}",
      "priority": "{BASED_ON_IMPLEMENTATION_ORDER}",
      "dependencies": ["{UPSTREAM_REPO_TASKS}"],
      "working_dir": "repos/{RepoName}",
      "acceptance_criteria": [
        "All planned file changes implemented",
        "All planned new files created",
        "Configuration entries added",
        "Database scripts created (if applicable)",
        "Unit tests written and passing",
        "Changes committed to initiative branch",
        "Outcomes document produced"
      ],
      "steps": [
        "Read {RepoName}_Plan.md for detailed implementation instructions",
        "Implement changes in order specified by the plan",
        "Follow code patterns from reference implementation",
        "Add configuration entries",
        "Create database scripts (if applicable)",
        "Write unit tests",
        "Run build and test commands from the plan",
        "Commit all changes to initiative branch",
        "Write {RepoName}_Outcomes.md using outcomes template"
      ],
      "applicable_standards": [],
      "applicable_agents": [".bot/prompts/agents/implementer/AGENT.md"]
    }
  ]
})
```

### Step 4: Execution (Per Task)

When each implementation task executes:

**4a. Read the plan:**
```
Read({ file_path: "repos/{RepoName}/.bot/workspace/product/{RepoName}_Plan.md" })
```

**4b. Implement in order:**
Follow the plan's implementation order. For each file change:
- Read the reference implementation file (cited in the plan)
- Create or modify the target file following the pattern
- Use TODO markers for blocked items: `// TODO({keyword}): description`

**4c. Build and test:**
Run the verification commands from the plan. Document any failures.

**4d. Commit:**
```bash
cd repos/{RepoName}
git add -A
git commit -m "{change description}

[{JIRA_KEY}] {INITIATIVE_NAME}
Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

**4e. Write outcomes:**
Using the outcomes template (`prompts/implementation/outcomes.md`), write:
```
repos/{RepoName}/.bot/workspace/product/{RepoName}_Outcomes.md
```

Document:
- Files created (count + table)
- Files modified (count + table)
- Build status
- Design decisions made during implementation
- TODO markers left in code
- What's next (blocked items, follow-ups)

## Output

Per repo:
- Code changes committed to `initiative/{JIRA_KEY}` branch
- `repos/{RepoName}/.bot/workspace/product/{RepoName}_Outcomes.md`

## Critical Rules

- Follow the plan — don't improvise unless the plan is clearly wrong
- Commit to the initiative branch only — do NOT push (that's Phase 7)
- Use TODO markers for blocked items — don't skip them silently
- Write outcomes even if implementation is partial
- Document ALL files created and modified — the handoff depends on this
- Build verification is mandatory — record pass/fail regardless
- Respect cross-repo implementation order from dependency map
