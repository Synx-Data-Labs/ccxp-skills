---
status: Open
estimation: 2
source: split of T20261125-264487 (retire blocks), epic E3
related: T20261125-264487, T20261124-320024
description: Shared reader derives dependants from the inverse of depends_on; legacy blocks lines are read with a warning; Unblocks, lint, template and docs follow
---

# T20261125-255147: Derived dependants reader, compat warning, core docs

## Problem

- **Type**: feature
- `todo-next.sh:150` prints `Unblocks:` straight from the `blocks:` line; `todo/scripts/_lib.sh` has `todo-deps` (a task's own dependencies) but no inverse.
- Do: add `todo-dependants <id> [todo-dir]` to `_lib.sh` (every task whose `todo-deps` names the id, plus ids from the id's own legacy `blocks:` line, deduplicated, with one stderr warning per file carrying `blocks:`); use it for `Unblocks:` in `todo-next` and `todo-list`.
- Lint: `blocks` stays allowed but warns (deprecated, run `todo-deps.sh migrate`), never fails; update the template, `new-task`, `todo/SKILL.md`, `lifecycle.md`, `repo-conventions/SKILL.md`, E3 epic wording.
- Tests: `tests/todo-lib.bats` (derived dependants, dedup, legacy blocks merged, warning on stderr), `tests/todo-next.bats`, lint tests.
