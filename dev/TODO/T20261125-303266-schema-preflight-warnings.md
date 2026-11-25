---
status: Open
estimation: 2
source: split of T20261125-424111
related: T20261125-424111, T20261125-264487
description: drive, todo and autopilot preflight warn on schema drift and refuse below min_repo_schema
---

# T20261125-303266: Schema preflight warnings and gate

## Problem

- **Type**: feature
- Do: call `schema.sh gate` from `drive/scripts/preflight.sh`, todo and autopilot preflight; warn text "repo schema N, plugin needs M: run /ccxp-upgrade"; refuse below min. bats.
- Part of [T20261125-424111](T20261125-424111-ccxp-upgrade-path-schema-marker-and-migrations.md); do NOT run any migration on real task files.
