# PowerShell 7+ vs Bash: Objective Assessment for dotbot

## Problem Statement

A team member is advocating to convert dotbot from PowerShell 7+ to Bash. This document provides an objective, evidence-based analysis to inform the decision.

## Current State

dotbot is **161 PowerShell files totalling ~33,500 lines** with zero Bash files. The codebase makes deep use of PowerShell 7+ and .NET features that have no direct Bash equivalents:

- **Module system**: ~20+ `.psm1` modules with `Export-ModuleMember`, scoped variables, and `Import-Module` for clean encapsulation
- **.NET interop** (used pervasively, not incidentally):
  - `[System.Net.HttpListener]` — the entire web UI server
  - `[System.Net.Sockets.TcpListener]` — port availability detection
  - `[System.IO.File]::Open` with `FileMode::CreateNew` — cross-platform file locking for worktree coordination
  - `[System.Security.Cryptography.SHA1]` — deterministic GUID generation for notification dedup
  - `[System.Diagnostics.Stopwatch]` — tool execution timing
  - `[System.Collections.Generic.Dictionary]`, `[System.Collections.ArrayList]` — typed collections
  - `[System.Text.Encoding]`, `[System.IO.Path]`, `[System.IO.FileSystemWatcher]`
- **`$PSStyle.Foreground.FromRgb()`** — RGB terminal theming (the entire DotBotTheme module)
- **Native JSON**: `ConvertFrom-Json -AsHashtable`, `ConvertTo-Json -Depth 100` — used in every MCP tool, task file, settings merge, and the MCP protocol itself
- **Structured data**: hashtables, PSCustomObject, property enumeration (`PSObject.Properties`), deep merging
- **CmdletBinding/Parameter validation**: `[ValidateSet]`, `[Parameter(Mandatory)]`, splatting — used across every script
- **`Invoke-RestMethod`** — HTTP client for DotbotServer notifications
- **Custom test framework**: assertion functions, test result tracking, layered test runner
- **CI**: GitHub Actions runs `pwsh` on Windows + macOS + Linux (already cross-platform)

## Comparison

### Where Bash would be equivalent or better

- **Shell scripting basics**: file operations, git commands, process spawning — both handle these fine
- **Unix tool piping**: `grep`, `sed`, `awk`, `jq` chaining is more idiomatic in Bash
- **Startup time**: Bash scripts launch faster (~0ms vs ~200ms for pwsh cold start)
- **Ubiquity on Linux/macOS**: Bash is pre-installed; PowerShell requires installation
- **Smaller scripts**: For simple automation (< 100 lines), Bash is often more concise

### Where PowerShell is significantly stronger (and why dotbot uses it)

- **Structured data / JSON**: Native `ConvertFrom-Json`/`ConvertTo-Json` vs Bash requiring `jq` (external dependency). dotbot does JSON manipulation in virtually every file.
- **Module system**: `.psm1` modules with proper scoping, exports, and versioning. Bash has `source` with no encapsulation — all functions/variables leak into global scope.
- **HTTP server**: The UI server uses `[System.Net.HttpListener]` — a production-grade HTTP stack. Bash equivalent would require `socat`/`netcat` hacks or embedding Python/Node.
- **Cross-platform consistency**: PowerShell 7 runs identically on Windows, macOS, Linux with the same API surface. Bash scripts commonly break on macOS (`sed`, `date`, `readlink` differ from GNU) and don't run on Windows without WSL/MSYS2.
- **Error handling**: `try/catch/finally`, `$ErrorActionPreference`, typed exceptions. Bash has `set -e` and `trap` — functional but brittle for complex flows.
- **File locking**: `[System.IO.File]::Open` with `FileMode::CreateNew` gives atomic, cross-platform locking. Bash requires `flock` (Linux-only) or `mkdir`-based workarounds.
- **Type safety**: Parameter validation, `[ValidateSet]`, typed function parameters prevent entire categories of bugs. Bash has no equivalent.
- **Process management**: The runtime manages multiple concurrent Claude CLI processes with JSON-based process registries, status tracking, and cleanup. This would be substantially harder in Bash.

### Bash's external utility fragmentation problem

Bash itself has almost no built-in data processing. It delegates to a constellation of external utilities — and those utilities are **not consistent across platforms**:

#### The GNU vs BSD minefield

- **`sed -i`**: GNU sed accepts `sed -i 's/x/y/' file`. BSD sed (macOS) *requires* a backup suffix argument: `sed -i '' 's/x/y/' file`. There is no portable syntax for in-place editing without a backup file — you must either create `.bak` files or write platform-detection code. One sed tutorial puts it bluntly: "One of the biggest gotchas using sed is scripts that fail because they were written for one and not the other."
- **`sed` escape sequences**: BSD sed doesn't recognise `\t` or `\n` in replacement strings. GNU sed does. Scripts using `sed 's/x/\n/'` silently produce wrong output on macOS instead of erroring.
- **`readlink -f`**: Doesn't exist on macOS BSD. Common workaround: install `coreutils` via Homebrew and use `greadlink`. Many Bash scripts assume GNU `readlink` and break silently on macOS.
- **`date`**: GNU `date -d "2 days ago"` doesn't work on BSD. BSD uses `date -v-2d`. There is no common syntax.
- **`grep -P`** (Perl-compatible regex): Not available in BSD grep. Must use `grep -E` with reduced functionality, or install GNU grep.
- **`find -regex`**: Different regex flavors between GNU and BSD find.

This means any non-trivial Bash script targeting Linux + macOS needs either: (a) GNU coreutils installed on macOS via `brew install coreutils` (defeating the "zero dependencies" argument), or (b) platform-detection shims for every affected utility.

#### The external dependency chain

Bash has no native JSON support. For a project like dotbot that manipulates JSON in virtually every file, you need `jq` — which is itself an external dependency with its own DSL. As one developer put it: "Bash doesn't understand JSON out of the box, and using the typical text manipulation tools like grep, sed, or awk gets difficult." You'd be trading one install (`pwsh`) for multiple installs (`jq` + `coreutils` + potentially `socat`/`python`/`node` for the HTTP server).

Even `jq` itself causes real-world problems as an undocumented dependency — e.g., a recent Claude Code plugin issue where a Bash script's hidden `jq` dependency broke on Windows/Git Bash because `jq` isn't standard there.

#### Objects vs text parsing

The fundamental design difference is that PowerShell pipes objects while Bash pipes text. As one professional programmer put it: "There are no advantages to text-based shells... the huge disadvantage is that there is no trivial way to convert text back to objects. Conversion requires command-specific parsing and very tedious error checking." Another experienced user: "I have never found an easier way to read in and manipulate data in CSV, XML, or JSON format than PowerShell, even compared with Python." Multiple sources note that Bash text parsing with `awk '{print $2}'` is "error-prone: small changes in output format break the script."

### Community perspective

The internet consensus is nuanced but generally aligns with "right tool for the job":

- **Bash advocates** value ubiquity on Linux, simplicity for small scripts, and startup speed. These are real advantages — for small scripts on Linux-only targets.
- **PowerShell advocates** emphasise structured data handling, cross-platform consistency, and the object pipeline. Multiple sources call PowerShell "better for complex, enterprise-grade automation" and cross-platform workflows.
- **The emerging consensus**: For applications beyond ~100-line scripts that need to handle structured data (JSON, XML, CSV) across platforms, PowerShell 7+ or a real programming language (Python, Go) is more appropriate than Bash. As dotlinux.net summarises: "Bash for simple scripts; PowerShell for complex, enterprise-grade automation" and "PowerShell 7+ is the better choice for consistent multi-OS workflows."
- **Even Bash defenders acknowledge**: Bash "treats everything as plain text, which makes it simple to use, but somewhat limited in its scope. Typically, you need to graduate to a more in-depth programming language if you plan to make scripts that require object-oriented programming or many lines of code."

### Migration cost

A Bash rewrite would require:

1. **~33,500 lines** of PowerShell rewritten from scratch
2. Replacing `[System.Net.HttpListener]` web server with a different technology (Python, Node, Go)
3. Adding `jq` as a hard dependency for all JSON operations (currently zero external deps beyond `pwsh` and `git`)
4. Solving cross-platform file locking without .NET (no portable Bash solution exists)
5. Reimplementing the module system as a convention-based `source` hierarchy with manual namespace discipline
6. Losing Windows native support (would require WSL2 or Git Bash, neither identical to real Bash)
7. Rewriting the entire test suite
8. Solving macOS BSD vs GNU tool incompatibilities (`sed -i`, `date`, `readlink`, etc.)

## Addressing Common Objections

| # | Objection | Response |
|---|-----------|----------|
| 1 | **"Nobody knows PowerShell"** — Most developers grew up on Bash. PowerShell's `Verb-Noun` cmdlets and `-Parameter` syntax feel alien. Contributing means learning a language the team doesn't use day-to-day. | This is the most legitimate concern — onboarding friction and bus factor are real. However, PowerShell 7 syntax is closer to C#/JavaScript than most people expect (`if/else`, `try/catch`, `foreach`, hashtables, dot-notation). More importantly, the *alternative* isn't "just learn Bash" — it's "learn Bash + jq's DSL + GNU-vs-BSD quirks + awk + sed regex dialects." The total surface area of knowledge for a Bash rewrite is arguably larger, just more familiar-looking. |
| 2 | **"It's not installed anywhere except Windows"** — On Linux/macOS, `pwsh` is an extra install step. Every new contributor or CI environment needs it. Bash is just *there*. | True, but a one-time `brew install powershell` or `sudo apt install powershell` is comparable to installing any other dev tool. The CI workflow already handles this in 3 lines. A Bash version would need `jq` installed everywhere too — plus `coreutils` on macOS for GNU compatibility — so you'd trade one install for multiple. |
| 3 | **"PowerShell is for Windows sysadmins, not developers"** — Strong cultural association with Active Directory and Exchange. Doesn't match the mental model of a dev tool. | This perception is outdated. PowerShell 7+ is open-source, cross-platform, and runs on .NET 8. dotbot uses it as an application runtime — HTTP server, MCP protocol, file system watchers, typed modules — not for sysadmin tasks. The `.NET` underpinning is actually a strength: it provides a standard library (crypto, HTTP, file I/O, collections) that Bash simply doesn't have. |
| 4 | **"AI tools generate better Bash"** — LLMs produce more reliable Bash because training data is overwhelmingly Bash/Python. You get better autocomplete, better Stack Overflow answers, and better copilot suggestions. | Fair point today, though the gap is narrowing as PS7 adoption grows. However, AI-generated Bash also inherits the GNU-vs-BSD problem — copilot will happily generate `sed -i` that breaks on macOS. AI-generated PowerShell may need more prompting, but the output is cross-platform by default. For a project that *orchestrates AI tools*, reliability trumps generation convenience. |
| 5 | **"It's a shell script project — use a shell"** — From the outside, dotbot looks like "scripts that orchestrate CLI tools." Bash is the natural choice for that. | This is a misread of the architecture. dotbot has a stdio MCP server, an HTTP web UI, cross-platform file locking, a module system with 20+ encapsulated modules, a process orchestrator managing concurrent AI CLI sessions, and a 4-layer test framework — totalling 33,500 lines. This is an application that happens to be written in a shell language, not a collection of shell scripts. Bash doesn't scale to this level of complexity without bolting on Python/Node/Go for the parts it can't handle natively. |

## Recommendation

**Stay on PowerShell 7+.** The reasons:

1. **The codebase is not a collection of shell scripts** — it's a structured application with an HTTP server, MCP protocol implementation, module system, test framework, and process orchestrator. PowerShell 7 is functioning as an application runtime here, not just a scripting language.
2. **Zero external dependencies** is a real advantage. The README says "No npm, pip, or Docker required" — a Bash rewrite would need `jq` at minimum, likely Python/Node for the HTTP server.
3. **Cross-platform already works**. CI runs on Windows, macOS, and Linux. A Bash rewrite would *lose* native Windows support.
4. **The migration cost is a full rewrite** — not a port. The .NET interop, module system, and structured data handling have no mechanical translation to Bash.
5. **Risk is high, benefit is low.** The project already runs everywhere PowerShell 7 runs. Converting to Bash solves no user-facing problem while introducing months of work and new platform-compatibility bugs.

The one valid concern — that PowerShell isn't pre-installed on Linux/macOS — is already mitigated: the CI workflow includes a 3-line pwsh install step, and users need only `brew install powershell` or equivalent. This is a one-time setup cost comparable to installing `jq`, `node`, or any other tool.
