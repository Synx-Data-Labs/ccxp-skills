---
status: Open
estimation: 2
source: split of T20261125-424111
depends_on: [T20261125-305580]
related: T20261125-424111, T20261125-264487
description: ordered idempotent migration runner with check/apply and fixtures; migration 0001 wrapper
---

# T20261125-119704: Migration runner and bats

## Problem

- **Type**: feature
- Do: `schema.sh pending|check|apply` over `_schema/migrations/NNNN-slug`; marker written only after all applied; idempotent. Migration 0001 wraps `todo-deps.sh migrate` (job 1577, T20261125-366351) and reports unavailable until it lands. Before/after fixtures and bats.
- Part of [T20261125-424111](T20261125-424111-ccxp-upgrade-path-schema-marker-and-migrations.md); do NOT run any migration on real task files.
