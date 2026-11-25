---
status: Open
estimation: 2
depends_on: [T20261125-366351, T20261125-264487]
target-repo: Synx-Data-Labs/synxdb-build-pipeline
source: follow-up of T20261125-264487 (retire blocks); cross-repo, drive after the plugin release carrying it
related: T20261125-288322
description: Migrate synxdb-build-pipeline task files from blocks to depends_on with todo-deps.sh migrate, after the installed plugin carries the derived-dependants readers
---

# T20261125-315142: Migrate synxdb-build-pipeline from `blocks:` to `depends_on`

## Problem

- **Type**: chore
- That repo has hundreds of task files and its autopilot cycles use the installed plugin: migrate only after the release with the compat-reading plugin is installed there.
- Do (in a fresh clone of the target repo): `todo-deps.sh migrate --dry-run` and review the report (unknown ids, files that cannot convert); run `migrate`; its lint passes; one PR through its own gates.
- Read-only dry run first, written to this task's Closed section.
