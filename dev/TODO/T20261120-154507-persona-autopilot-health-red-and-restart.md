---
status: In Progress
estimation: 1
source: Job 1339 analysis B(3) option 1 (L117), owner choice 2026-11-20
description: Persona treats overdue autopilot as a red HUD item and offers a one-line restart
type: feature
related: T20261120-645606
claimed_by: cc1-50ac6891:4e719af42e9ae3b0
claimed_role: interactive
scheduled: 2026-11-16
---

# T20261120-154507: Autopilot health - overdue autopilot is red and offers a restart (n362 step 4)

## Problem

- **Type**: feature
- Autopilot was `status: on` with `next_wake_at` 2 days overdue and nothing flagged it; the HUD stalled cell exists but is not alerting.
- Extends T20261120-645606: red styling for "autopilot on but `next_wake_at` overdue > 10 min".
- Persona prose (tiny, within the 48000-byte guard; detail in a doc): on seeing the overdue state, offer a one-line restart.
- Update agent-pairing README and persona-refresh per repo rules; bats tests. Do not touch versions, tags or releases.
