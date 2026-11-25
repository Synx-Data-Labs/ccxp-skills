---
status: Open
estimation: 2
depends_on: [T20261125-255147]
source: split of T20261125-264487 (retire blocks), epic E3
related: T20261125-264487
description: queue-op stage and top, todo-sweep ordering, epic.sh, task-state.sh and migrate-task read dependants derived from depends_on, with the legacy blocks line as a warned fallback
---

# T20261125-361713: Queue consumers read derived dependants

## Problem

- **Type**: feature
- Readers of `blocks:` today: `_queue/queue-op.sh:168` (`/stage` insert-before target, `/top` expansion), `todo/scripts/todo-sweep.sh` (blocker ordering), `epic/scripts/epic.sh:244`, `_session/task-state.sh:187`, `migrate-task/scripts/migrate.sh:67`.
- Do: each uses the shared `todo-dependants` / `todo-deps` from T20261125-255147 (depends_on first, legacy `blocks:` fallback with a warning); `/top` expands a task into its `depends_on` chain; sweep orders from `depends_on`; update `stage/SKILL.md`, `top/SKILL.md`, `todo/SKILL.md` sweep text.
- Tests: `tests/queue_op.bats`, `tests/todo_sweep.bats`, `tests/epic.bats`, `tests/task-state.bats`, `tests/migrate_task.bats`.
