---
status: Open
estimation: 2
source: split of T20261125-424111
related: T20261125-424111, T20261125-264487
description: schema marker file, plugin schema.env, runner gate
---

# T20261125-305580: Schema marker and gate

## Problem

- **Type**: feature
- Do: `dev/.ccxp-schema` marker, `_schema/schema.env`, `_schema/schema.sh` with `repo-schema`, `plugin-schema`, `status`, `gate` (exit 0 ok, 20 warn: repo behind, 21 refuse: below min). bats.
- Part of [T20261125-424111](T20261125-424111-ccxp-upgrade-path-schema-marker-and-migrations.md); do NOT run any migration on real task files.
