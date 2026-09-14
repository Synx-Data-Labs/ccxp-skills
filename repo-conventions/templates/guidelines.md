# Developer Guidelines

These guidelines apply to all work in the {{ repo-name }} project.

## Core Principles

- **KISS** / **DRY** — keep it simple, don't repeat yourself
- **Idempotent, sourceable, function-wrapped** bash scripts
- **Fix the root cause, not the symptom**

## Branch and Merge Policy

The `main` branch is the source of truth. Never push directly to `main`.

1. **Create a feature branch** — all changes go through a feature branch, no exceptions
2. **Branch naming**: `t{task-id}-short-description` for tracked tasks; `fix/`, `feat/`, `docs/` prefixes for untracked work
3. **Open a PR** — clear summary and test plan
4. **CI must pass** — all checks green before merge
5. **Merge method** — rebase and merge, via the ccxp-skills `_gh/gh.sh` wrapper (`pr merge --rebase --delete-branch`) — resolve its path relative to wherever the ccxp-skills plugin is installed, not a hardcoded location
6. **Delete the branch after merge**

## TODO Lifecycle

Tasks live as individual files — the filesystem is the index. **Never mirror the index in CLAUDE.md.**

- **Open tasks**: `dev/TODO/*.md`
- **Parked tasks**: `dev/PARKING/*.md`
- **Completed**: `dev/JOURNAL/yyyy-mm-dd-{id}-slug.md`

### Task ID Format

```
TYYYYMMDD-NNNNNN
```

Generate with the shared helper — single source of truth, so every skill that creates a task uses the same generator and the same collision-avoidance rules:

```bash
bash _taskid/new.sh --check ./dev
```

(Resolve `_taskid/new.sh` relative to wherever the ccxp-skills plugin is
installed on this machine — a loaded skill's own directory, printed as
"Base directory for this skill", not a hardcoded path.)

Pass `--check <dev-dir>` so the helper rejects any ID that already exists under `dev/{TODO,PARKING,JOURNAL}/` and retries. Do NOT inline the `printf ... /dev/urandom ...` command in a new skill or script — add a call to this helper instead.

### Task File Header

Task metadata uses **YAML frontmatter** (`---` … `---` at the top of the file), same convention as `SKILL.md` files in `ccxp-skills`. The H1 title follows. See `ccxp-skills/todo/SKILL.md` for the full field schema and semantics.

```markdown
---
estimation: {30m|1h|2h|4h|1d|2d|1w|2w}
status: {Open|Design|Coding|Review|Blocked by T{id}}
source: {GitHub issue, upstream link, or process note}
description: {One-line summary}
---

# T{ID}: {Title}
```

### Status Flow

```
Open → Design → Coding → Review → Done
         ↕                          ↕
    Blocked by T{id}             Parked
```

- **Done** = `git mv` from `dev/TODO/` to `dev/JOURNAL/yyyy-mm-dd-{id}-slug.md`. Include this move in the implementing PR.
- **Parked** = `git mv` from `dev/TODO/` to `dev/PARKING/`.

### Branch Rule

**Do NOT update CLAUDE.md when journaling.** The `dev/JOURNAL/` folder IS the index. Mirroring it in CLAUDE.md duplicates content, eats the auto-loaded context budget, and creates merge conflicts on every completed task. CLAUDE.md only changes when the project's overall structure changes.

## Script Standards

```bash
#!/usr/bin/env bash
set -euo pipefail

function my-operation() {
  local param="${1:-default-value}"
  # Idempotent body
}

# Run only if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  my-operation "$@"
fi
```

Rules: wrap logic in functions, make scripts sourceable, keep operations idempotent, use `set -euo pipefail`.

## Documentation

- **Task tracking**: `dev/TODO/` (active), `dev/JOURNAL/` (completed)
- **Inline comments**: only where logic isn't self-evident
- **Commit messages**: conventional commits format
- **Prefer bullets over paragraphs**: chunk information into bullet points, short lists, and tables so a reader can scan and find the one fact they need — don't bury it inside a paragraph. Keep each level to roughly 3 bullets; nest a sub-list under one of them instead of running past that into a wall of siblings, or folding the extra detail back into prose. Reserve prose for narrative that genuinely doesn't decompose (a root-cause story, a rationale). Applies to README, guidelines, task files, and JOURNAL entries alike.
