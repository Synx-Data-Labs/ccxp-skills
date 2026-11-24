---
status: Open
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

- [ ] `lint_tasks.py` accepts `tier` on the allowlist and rejects a value outside 1..4 (test in `repo-conventions/scripts/test_lint_tasks.py`).
- [ ] `repo-conventions/templates/task.md` documents the optional `tier:` line (1 = red nightly and other urgent work, 2 = new synxdb-support issues, 3 = default, 4 = low); `new-task` mentions it only when the owner states a tier.
- [ ] `todo/SKILL.md` "Task metadata" documents the field, its default and that queue order still orders tasks within a tier; a read helper `todo_tier <file>` in `todo/scripts/_lib.sh` prints the effective tier (with a bats test).
- [ ] No behavior change to selection yet (sub-task 3 uses it).
