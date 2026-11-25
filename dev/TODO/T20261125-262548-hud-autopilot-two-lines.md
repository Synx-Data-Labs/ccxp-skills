---
status: In Progress
estimation: 1
source: owner request in this conversation, 2026-11-25
description: /hud details AUTOPILOT section on two lines (status, then progress stats)
claimed_by: cc1-50ac6891:92f71c7e1feb348f
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261125-262548: HUD details: AUTOPILOT section on two lines

## Problem

- **Type**: feature
- Owner: "for the HUD, the AUTOPILOT output line is super long, see if you can help me organize it into 2 lines?"
- The `/hud details` AUTOPILOT row (`detailRows` in `hud/model.ts`) puts state, max_dop use, holds, next loop and the 24h/average cell on one line.
- Wanted: line 1 = status (on/paused/off, slots in use of max_dop with running cycles, next loop or overdue/stalled); line 2 = progress (24h merged arrow over loops, average per day, `N held by autopilot`).
- Keep every cell, colors, thresholds, NO_COLOR and the no-abbreviation rule; other sections and the one-row band unchanged.
