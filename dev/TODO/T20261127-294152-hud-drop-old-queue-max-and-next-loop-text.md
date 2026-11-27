---
status: Open
estimation: 1
source: owner request via coordinator, 2026-11-27 (HUD after 6.10.0)
related: T20261126-122285
description: HUD drops the queue max last-month/last-week/this-week stats and the AP next loop text
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
