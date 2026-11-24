---
status: Done
estimation: 2
blocks: [T20261124-340374]
source: epic split of T20261124-989194 (job 1514), owner request 2026-11-24
related: [T20261124-989194]
type: feature
description: Add the `tier:` task frontmatter field (integer 1..4, default 3 when absent)
---

# T20261124-345756: `tier:` frontmatter field

## Problem

- **Type**: feature
- Sub-task 1 of 5 of T20261124-989194 (autopilot cursor and holds).
- Option A of the owner's decision: the tier lives in the task file frontmatter, not in `## P<n>` headers of `queue.md`. d160: red-nightly related tasks are tier 1, new synxdb-support issues tier 2.
- Dependency chain (d158): this task is done before T20261124-340374; queue order follows the chain.

## Done criteria

- [x] `lint_tasks.py` accepts `tier` on the allowlist and rejects a value outside 1..4 (test in `repo-conventions/scripts/test_lint_tasks.py`).
- [x] `repo-conventions/templates/task.md` documents the optional `tier:` line (1 = red nightly and other urgent work, 2 = new synxdb-support issues, 3 = default, 4 = low); `new-task` mentions it only when the owner states a tier.
- [x] `todo/SKILL.md` "Task metadata" documents the field, its default and that queue order still orders tasks within a tier; a read helper `todo_tier <file>` in `todo/scripts/_lib.sh` prints the effective tier (with a bats test).
- [x] No behavior change to selection yet (sub-task 3 uses it).

## Closed (2026-11-24)

- Shipped in the PR that adds `tier` to `repo-conventions/scripts/lint_tasks.py` (`check_tier`, tests `test_tier_1_to_4_passes`, `test_tier_out_of_range_fails`), `todo-tier` in `todo/scripts/_lib.sh` (bats `todo-tier`), the template line in `repo-conventions/templates/task.md` and the "Task metadata" entry in `todo/SKILL.md`.
- No selection change: sub-task T20261124-670976 consumes the tier.
