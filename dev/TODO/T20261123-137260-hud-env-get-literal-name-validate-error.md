---
status: Open
estimation: 1
source: Job 1393/1394, 2026-11-23 (release 6.5.0 blocked)
type: bug
related: T20261122-212315
description: claude plugin validate rejects the dynamic $.env.get(name) in hud/register.tsx; blocks the 6.5.0 release gate
---

# T20261123-137260: Fix `claude plugin validate` error: $.env.get needs a literal name (hud/register.tsx:380)

## Problem

- **Type**: bug
- `claude plugin validate .` (CLI 2.1.330) fails on main with 1 error at `hud/register.tsx:380`: `vars[name] = (await $.env.get(name)) || undefined` - the validator requires a literal variable name.
- Introduced by commit 088b055 (/hud help and read-only /hud config, T20261122-212315); the 6.4.0 tag uses only literal names.
- `dev/guidelines.md` requires zero validation warnings before the bump PR and before tagging, so the 6.5.0 release is blocked.
- Done: validate reports zero errors/warnings; /hud config output unchanged; HUD tests green, with a regression test if feasible.
