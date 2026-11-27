---
status: Done
estimation: 1
source: owner request via coordinator, 2026-11-27 (HUD after 6.10.0)
related: T20261126-122285
description: HUD drops the queue max last-month/last-week/this-week stats and the AP next loop text
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261127-294152: HUD drops the old queue max stats and the AP next loop text

## Problem

- **Type**: chore
- Owner (2026-11-27): "did I mention that I don't need the \"max 228 last month / 215 last week / 231 this week ▲\" in hud, since we already have the \"TREND\"?"
- Owner (2026-11-27): "did I also mention, I don't need the \"next loop ...\" information in the HUD?"
- Queue max segment: `hud/model.ts` (queue cell, band and details), `hud/README.md` "Queue high watermark", `hud/HELP.md`, `hud/pure.test.ts`.
- Next loop text: `hud/model.ts` AP wake item, README, HELP, tests; the red stalled signal must stay.
- Done: both texts gone from band and `/hud details`; TREND rows, AP counts and the stalled indicator untouched; HUD tests pass.

## Design

- d190: HUD drops the old "max N last month / N last week / N this week" stats now that the TREND one-liner exists (owner quote above).
- d191: HUD drops the AP "next loop ..." information (owner quote above); the red stalled indicator stays as the autopilot health signal.

## Closed (2026-11-27)

- Shipped in the PR that carries this file (ccxp-skills), not released: no version bump or tag.
- Queue max removed: `hud/model.ts` (render, `parseHelper`), `types/index.d.ts` (`QueueMax`), `hud/scripts/hud-data.sh` (no `queue.hwm`), README, HELP, tests. `hud-queue-hwm.sh` stays as a library (TREND and the issues cell source it).
- Next loop removed from the AUTOPILOT details row; kept `running` cycles and a red `stalled <span>` (details) / `stalled 2d` (band); `stalledFor` logic unchanged. The band never showed the next-loop text.
- Verification: `claude plugin test .` 278 pass, 2 fail (the same 2 fail on main before this change: config queue-source wording, `no ci configured` row count); hud bats files pass.
- Left alone on purpose: the issues cell `max 18 180d / 15 30d / 12 7d` (a different segment) and the TREND rows.
- Quality probe: no probe record written (a removal-only chore).

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, deletion of a display segment; tests were rewritten alongside
- Verification (`superpowers:verification-before-completion`): yes, full TS and hud bats runs before the PR
- Systematic debugging (`superpowers:systematic-debugging`): no, did not get stuck
- Receiving code review (`superpowers:receiving-code-review`): see /address-pr
