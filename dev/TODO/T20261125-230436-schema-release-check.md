---
status: Open
estimation: 1
source: split of T20261125-424111
related: T20261125-424111, T20261125-264487
description: release check: schema bump needs a migration and a test; release notes list migration ids
---

# T20261125-230436: Schema release check

## Problem

- **Type**: feature
- Do: `schema.sh release-check` fails when `CCXP_SCHEMA` has no migration directory or no fixture test; wire into CI and the release procedure in `dev/guidelines.md`.
- Part of [T20261125-424111](T20261125-424111-ccxp-upgrade-path-schema-marker-and-migrations.md); do NOT run any migration on real task files.
