---
status: Review
estimation: 1
scheduled: 2026-11-24
source: release 6.6.0 gate (job 1492)
description: Restore the busVariants export that the alerts-cell removal deleted from hud/model.ts
type: bug
---

# T20261124-502781: restore busVariants in hud/model.ts

## Problem

- **Type**: bug
- 5d4a28a (T20261123-248916) removed the alerts cell and deleted `busVariants` with it. `hud/model.ts` and `hud/pure.test.ts` still use it, so the HUD bus cell would throw a ReferenceError and `claude plugin validate .` warned (TS2304).

## Design

- Restore the function verbatim from `ccxp-skills--v6.5.0`. Every other identifier 5d4a28a removed (`alertsVariants`, `ALERTS_STALE_MIN`, the alerts field) was grepped and has no remaining reference.
- Add `tests/hud_model_refs.bats`: a static guard that every `*Variants(` helper called in `hud/model.ts` is defined there.

## Test plan

- [x] `claude plugin validate .` zero warnings
- [x] `bats tests/hud_*.bats`
