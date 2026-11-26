---
status: Open
estimation: 2
depends_on: [T20261125-255147]
source: split of T20261125-264487 (retire blocks), epic E3
related: T20261125-264487, T20261124-177980
description: todo-deps.sh migrate rewrites each blocks entry into depends_on on the other task, removes blocks, with a dry-run report; T20261124-177980 design updated
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261125-366351: `todo-deps.sh migrate` for `blocks:` with dry-run

## Problem

- **Type**: feature
- Do: new `todo/scripts/todo-deps.sh` with `dependants <id>` and `migrate [--dry-run] [--dir DIR]`. For each old `blocks: [X..]` on task A: add A's id to each X's `depends_on` (create the key, deduplicate, keep trailing comments and notes), then remove the `blocks:` key from A. Idempotent. Entries naming an unknown id are reported and kept out of the rewrite (A keeps nothing it cannot place; reported as "cannot convert").
- `--dry-run` prints per-file actions and counts, writes nothing. Update T20261124-177980's design to say `migrate` handles `blocks:` this way (its `Blocked by` conversion part stays there); T20261124-419462 (now depends on this task) adds `chain`/`tree` to the same script.
- Do NOT run it on any real task file in this job. Tests: `tests/todo-deps.bats` on a fixture board (dry-run report, rewrite, idempotence, unknown id).
