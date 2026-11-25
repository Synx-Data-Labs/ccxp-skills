---
status: In Progress
estimation: 5
depends_on: [T20261125-255147, T20261125-361713, T20261125-187172, T20261125-366351]
source: owner request 2026-11-25 (decisions d158, d159, d174), epic E3
related: T20261124-177980, T20261124-112157, T20261124-158321, T20261124-320024
description: Retire the blocks frontmatter field; depends_on is the only authored relation and dependants are derived from its inverse
claimed_by: cc1-50ac6891:106b09463f085cb8
claimed_role: interactive
scheduled: 2026-11-30
---

# T20261125-264487: Retire `blocks`, keep only `depends_on`

## Problem

- **Type**: feature
- Owner's words (2026-11-25): "retire 'blocks', and only keep 'depends_on'" and "file and drive it now".
- Today a relation is stored twice: `blocks: [T..]` on the blocker and `depends_on: [T..]` on the dependant (`depends_on` came with T20261124-320024 / PR #742; E3 spec item 1 says both sides stay maintained). Two copies drift.
- Goal: `depends_on` is the ONLY authored field; every "what does this unblock" list is derived from the inverse of `depends_on` over the board.
- Epic E3 (`dev/EPICS/E3-dependency-chain.md`); linked tasks: T20261124-177980 (migration design changes here), T20261124-112157, T20261124-158321.

## Scope

- Readers stop treating `blocks:` as authoritative: `todo-next`/`todo-list` `Unblocks:`, `todo-sweep`, `autopilot-state`, the autopilot big-task rule, `/stage`, `/top`, `epic.sh`, `task-state.sh`, `migrate-task`, the HUD blocked bucket and chain, the new-task template and comments, repo-conventions and skill docs, lint allowlist and messages.
- Compat reader: an old `blocks:` line is read as a dependants list (task A `blocks: [X]` means X depends on A), with a warning, never a failure, during the migration window (consumer repos such as synxdb-build-pipeline carry hundreds of files and run the installed plugin).
- Migration: `todo-deps.sh migrate [--dry-run]` rewrites each `blocks: [X]` on A into A's id in X's `depends_on`, then removes `blocks:` (design in T20261124-177980). Never run on real task files in this job.
- Autopilot big-task rule: the original umbrella gets `depends_on: [sub-tasks]` and queue order (sub-tasks right before it); its `status:` stays untouched.

## Split (big-task rule, each sub-task estimation 1-2)

- T20261125-255147 core: shared derived-dependants reader with compat warning, `Unblocks:`, lint, template and docs.
- T20261125-361713 queue consumers: `queue-op` (stage and top `--before`), sweep ordering, `epic.sh`, `task-state.sh`, `migrate-task`.
- T20261125-187172 HUD blocked bucket and chain, autopilot big-task rule.
- T20261125-366351 `todo-deps.sh migrate` with dry-run, and the T20261124-177980 design update.
- Follow-ups filed (driven after the plugin release carrying this): T20261125-288322 (ccxp-skills own `dev/TODO`), T20261125-315142 (synxdb-build-pipeline).

## Out of scope

- Stale-claims research task, and the epic-simplification idea (`type: epic`): possible follow-up dependencies, not part of this task.
