---
status: Open
estimation: 1
source: Conversation 2026-10-26 (i211), found during the PR #436 migration of T20260813-406012
---

# T20261026-665838: Finish /migrate-task live push half

## Problem

- **Type**: feature
- `migrate-task/SKILL.md` lines 73-75 say the live push and PR-opening half (creating the destination task file and PR in the target repo) remains an unimplemented stub (`migrate.sh`, `return 8`).
- `migrate-task/scripts/migrate.sh:246` marks the stub; the design task's Solution #6 describes the intended behavior.
- Evidence: the [PR #436](https://github.com/Synx-Data-Labs/ccxp-skills/pull/436) migration of T20260813-406012 had to be done by hand because of this gap.
- Priority: low.
