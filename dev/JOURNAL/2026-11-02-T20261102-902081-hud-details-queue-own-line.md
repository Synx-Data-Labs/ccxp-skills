---
status: Done
estimation: 1
source: owner request, this conversation, 2026-11-02
description: /hud details puts the queue on its own line right after the AP line
claimed_by:
claimed_role:
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
- Owner additions, same task (2026-11-02):
  - details never abbreviate: queue `ready` / `blocked` / `decisions` / `external` / `epics` (`x` = epic, `e` = external), and no other details cell drops to a short form; a too-wide line is cut with an ellipsis; short forms stay in the one-row band
  - "fix the HUD due display too": `next loop due` only within a small grace; a long-overdue wake reads as stalled

## Done criteria

- Queue on its own line after AP, no `||`: `hud/pure.test.ts` "AP on + queue data: AP and queue are two separate consecutive lines" and "CI first and alone ... (seven lines)"
- Full labels, cut with an ellipsis at every width: "the queue line never abbreviates", "a narrow terminal cuts a line with an ellipsis", version squeeze tests
- Grace chosen: 10 minutes (`STALL_GRACE_SEC` in `hud/model.ts`; the autopilot tick or a slow cycle runs a few minutes late). Not due / due within grace / overdue minutes, hours, days / paused and busy unaffected: the four "next loop:" tests
- README updated: `hud/README.md` (`/hud details`, Queue cell, 24h cell, Version cell)

## Closed (2026-11-02)

- Shipped in PR #541.
- Met: all done criteria above; `hud/pure.test.ts` 125/125 and `hud/configure.test.ts` 21/21 locally (deno plus a `claude-code/testing` shim; `claude plugin test .` and so `hud/hooks.test.tsx` could not run here, only its test title changed).
- Details are 6 lines at most (7 with CI); lines with nothing to show are omitted, no line is reserved.
- No version bump or release (not authorized, not required by the PR checks).

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, not available in this run; tests written with the change
- Verification (`superpowers:verification-before-completion`): no, not available; verified by running the suites and a demo render
- Systematic debugging: no, did not get stuck
- Receiving code review: see /address-pr on PR #541
