---
status: In Progress
estimation: 1
source: Job 1339 analysis (n362), owner 2026-11-20 "then fix n362"
description: HUD staleness cells - alerts checked Xm ago, stalled autopilot when next_wake_at is overdue
type: feature
related: T20261120-230152
claimed_by: cc1-50ac6891:8a3d643f5ec9366f
claimed_role: interactive
scheduled: 2026-11-16
---

# T20261120-645606: HUD staleness cells for alerts check and autopilot (n362 step 2)

## Problem

- **Type**: feature
- Nobody could tell that Slack alerts were never checked and that autopilot was stalled (`next_wake_at` 2026-11-18T20:27Z, 2 days overdue).
- Add an "alerts checked Xm ago" cell reading the `alerts-due.sh` state (#657); when #657 state is absent on main or on the profile, degrade gracefully (show "alerts never checked" or hide, per r1339 B.2) without errors.
- Add a stalled-autopilot cell, red-styled, when `next_wake_at` is overdue (threshold documented, default 10 min); local files only, no network; bats tests.
- Analysis: r1339 proposal B.2 and C.3. Do not touch versions, tags or releases.
