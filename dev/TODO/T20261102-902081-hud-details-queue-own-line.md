---
status: In Progress
estimation: 1
source: owner request, this conversation, 2026-11-02
description: /hud details puts the queue on its own line right after the AP line
claimed_by: cc1-ecc09c93:c82925f26e708c76
claimed_role: interactive
scheduled: 2026-11-02
---

# T20261102-902081: HUD details: queue on its own line after AP (6 lines)

## Problem

- **Type**: feature
- Owner: "for ccxp-hud since AP is too long, it's better to keep the queue on its own line right after the AP. So, total we will have 6 lines in details mode, instead of 5 lines."
- Today `detailRows` in `hud/model.ts` (step 4) joins AP, next loop, the 24h cell, a ` || ` separator (`GROUP_SEP`) and the queue breakdown on ONE line, which overflows narrow terminals.
- Done looks like:
  - the queue breakdown renders on its own line directly after the AP line (same content, colors, shrink order); the `||` separator is gone
  - details is up to 6 lines (7 with the CI row); lines with nothing to show stay omitted, no reservation exists
  - docs and comments saying five/six lines, and the tests (`hud/pure.test.ts`, `hud/hooks.test.tsx`; bun/TS, not bats), are updated, with a test that AP on + queue data gives two separate consecutive lines, and the narrow-width cases re-checked
