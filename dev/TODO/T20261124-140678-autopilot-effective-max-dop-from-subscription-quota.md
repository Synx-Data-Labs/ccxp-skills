---
status: Open
scheduled: 2026-12-07
estimation: 1
source: Owner chat 2026-11-24 (job 1490)
depends_on: [T20261124-168446, T20261124-182499]
related: [T20261103-169088]
description: Autopilot computes an effective max_dop from the HUD's subscription-quota cache (burn rate vs time left), opt-in
---

# T20261124-140678: Autopilot steers max_dop from subscription quota headroom

## Problem

- **Type**: feature
- Owner (2026-11-24): "if the subscription time limit is only 20% left, I would reduce the maxdop of AP down to 3." Phase 2 of the display-first request. Depends on T20261124-168446 (the HUD cache file `rate-limits.json`, closed 2026-11-24, shipped in PR #745 and #748) and on T20261124-182499 (max_dop minimum 3, `reserved_slots`, closed). Owner rule d158 retires the `Blocked by` status, so the dependency is the `depends_on:` field; queue order keeps it after both.
- Ordering: after T20261124-168446 and after the open autopilot-config task for max_dop minimum 3 and the `reserved_slots` key (owner decision d157: `max_dop` must be 3 or more because 2 slots are always reserved; T20261103-169088 is the earlier config task, the min-3 follow-up is T20261124-182499).

## Design

- Input: the HUD's rate-limit cache file; fresh data only (age under a configured limit); absent or stale means no change.
- Decision: burn rate versus time left, not percent alone (20 percent left with 10 minutes to the reset is fine; 20 percent left with 4 hours is not). Both the 5h and 7d windows count; the tighter one wins.
- Output: an effective `max_dop`; the configured value is never rewritten. Floor is `reserved_slots + 1` (3 by default).
- At the low-headroom floor: new dispatches pause and running cycles finish.
- Config: thresholds configurable; the whole feature opt-in (default off).
- Visibility: show the effective value in `autopilot-state.sh status` and the HUD AP cell.
- Caveats to document: running cycles cannot be shrunk; the quota is shared across all the owner's sessions, so the cache can lag another session's burn.
