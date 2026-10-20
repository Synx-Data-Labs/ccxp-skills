# Developer Guidelines

These guidelines apply to all work in the ccxp-skills project.

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
5. **Merge method** — rebase and merge (`bash ../_gh/gh.sh pr merge --rebase --delete-branch`)
6. **Delete the branch after merge**
7. **Approval gate** — a repo with `.github/workflows/pr-approve.yml` gets a real GitHub approval from `synx-merge-bot`: `/address-pr` dispatches the workflow (pinned to the reviewed commit) after a clean independent review, then arms `gh pr merge --auto`. Enable `required_approving_review_count: 1` with dismiss-stale-reviews and an **empty bypass list**

## TODO Lifecycle

Tasks live as individual files — the filesystem is the index. **Never mirror the index in CLAUDE.md.** See [`lifecycle.md`](../lifecycle.md) at the repo root for the full task ID format, status flow, and procedures — this repo IS the canonical source other repos point back to.

- **Open tasks**: `dev/TODO/*.md`
- **Parked tasks**: `dev/PARKING/*.md`
- **Completed**: `dev/JOURNAL/yyyy-mm-dd-{id}-slug.md`

### Task File Header

Task metadata uses **YAML frontmatter** (`---` … `---` at the top of the file), same convention as `SKILL.md` files in `ccxp-skills`. The H1 title follows. See `todo/SKILL.md` for the full field schema and semantics.

```markdown
---
estimation: {1|2|3|5|8}
status: {Open|Design|In Progress|Review|Blocked by T{id}}
source: {GitHub issue, upstream link, or process note}
description: {One-line summary}
---

# T{ID}: {Title}
```

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

## Release & Versioning

This repo ships as a single Claude Code plugin (`.claude-plugin/plugin.json`) bundling many skills under one version number. There is no per-skill versioning — a change anywhere in the plugin affects the whole release.

### SemVer Classification Rubric

Classify each change since the last tag, per skill, then bump the plugin to the **most severe level found in the batch** (most-severe-wins) — one breaking change anywhere means the whole plugin goes MAJOR, even if the rest of the diff is patch/minor-level.

| Level | Trigger | Caller impact |
|-------|---------|----------------|
| **PATCH** (x.y.Z) | Bug fix to an existing skill | None beyond correctness — no behavior/interface change a caller would notice |
| **MINOR** (x.Y.z) | New skill added, or new backward-compatible capability on an existing skill (new optional flag/subcommand) | Old invocations still work unchanged |
| **MAJOR** (X.y.z) | Skillset redesign, or any breaking change to how an existing skill is invoked/behaves | Old invocation breaks — e.g. renaming an agent persona changes its `claude --agent <name>` invocation, breaking anyone with the old name baked into a script/alias |

### On-Demand Publish Process

Publishing a tag is **maintainer-triggered, not automatic on merge**. `claude plugin tag` cuts the git tag (`ccxp-skills--v{version}`), validating that `plugin.json`'s `version` field and the marketplace entry (`.claude-plugin/marketplace.json`) agree before it will create the tag.

Workflow:

1. **Review** what's merged into `main` since the last tag (`git log <last-tag>..main`)
2. **Classify** each change per the rubric above; take the most-severe level across the whole batch
3. **Bump** `plugin.json`'s `version` field accordingly, in its own small PR (through the normal Branch and Merge Policy above)
4. **Tag**: run `claude plugin tag [--push]` from the repo root to cut (and push) the `ccxp-skills--v{version}` tag once the bump PR is merged

## Documentation

- **Task tracking**: `dev/TODO/` (active), `dev/JOURNAL/` (completed)
- **Inline comments**: only where logic isn't self-evident
- **Commit messages**: conventional commits format
- **Prefer bullets over paragraphs**: chunk information into bullet points, short lists, and tables so a reader can scan and find the one fact they need — don't bury it inside a paragraph. Keep each level to roughly 3 bullets; nest a sub-list under one of them instead of running past that into a wall of siblings, or folding the extra detail back into prose. Reserve prose for narrative that genuinely doesn't decompose (a root-cause story, a rationale). Applies to README, guidelines, task files, and JOURNAL entries alike.
