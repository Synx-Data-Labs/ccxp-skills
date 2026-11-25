---
status: Open
estimation: 2
source: split of T20261125-424111
depends_on: [T20261125-119704]
related: T20261125-424111, T20261125-264487
description: /ccxp-upgrade skill: dry-run report, one branch and PR, --all over the registry
---

# T20261125-107918: /ccxp-upgrade skill

## Problem

- **Type**: feature
- Do: `ccxp-upgrade/SKILL.md` per the parent design: fresh worktree, dry-run report, ONE branch and ONE PR through lint/review/`/address-pr`, `--all` over `ccxp-repos.json`.
- Part of [T20261125-424111](T20261125-424111-ccxp-upgrade-path-schema-marker-and-migrations.md); do NOT run any migration on real task files.
