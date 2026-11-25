---
status: Open
estimation: 2
blocks: [T20261124-112157]
depends_on: [T20261125-366351]
source: owner request 2026-11-24 (decision d158), epic E3
description: Migration script from status Blocked by to depends_on with a dry-run mode, plus a read-only dry-run report on synxdb-build-pipeline
---

# T20261124-177980: Blocked by migration script and dry-run report

## Problem

- **Type**: feature
- Epic E3 (`dev/EPICS/E3-dependency-chain.md`); owner's words: "I want to remove 'blocked', and replace by its dependency chain."
- Do: `todo-deps.sh migrate [--dry-run]` per epic spec item 6 (real status `Design` if a `## Design` section exists else `Open`, notes kept, typed `person:` / `ext:` forms to `needs:`); idempotent; tests for each case.
- Design change (T20261125-264487, owner: "retire 'blocks', and only keep 'depends_on'"): `blocks:` is no longer back-filled on the other side. `migrate` also rewrites every old `blocks: [X]` on task A into A's id in X's `depends_on` (key created when absent, deduplicated, notes and comments kept), then removes the `blocks:` key; `--dry-run` reports per-file actions and counts. That `blocks:` half lands in T20261125-366351 (`todo/scripts/todo-deps.sh`); this task adds the `Blocked by` and typed-form conversion to the same script and the report below.
- Report: run the dry run against the real synxdb-build-pipeline queue read-only, by materialising its `dev/TODO` files with `git show origin/main:` into a scratch directory; state how many `Blocked by` files would convert and list any that cannot (and why) in this task's Closed section. Never write in that repo.
