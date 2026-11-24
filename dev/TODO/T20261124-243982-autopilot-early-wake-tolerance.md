---
status: Open
estimation: 1
source: owner message 2026-11-24 (job 1455)
description: Autopilot wake that fires up to ~59 s before next_wake_at reads already-on and skips a dispatch; widen the due tolerance to 60 s
type: bug
---

# T20261124-243982: autopilot wake fired early reads already-on and stalls the ramp

## Problem

- **Type**: bug
- Owner (Shine, 2026-11-24): "I don't understand why 'wake' cannot schedule more AP task, even though we have slots free."
- `autopilot-state.sh hold|wake|record` write `next_wake_at` to the second (e.g. 16:53:42Z); the loop then calls `ScheduleWakeup(delaySeconds: s)`. In the owner's session the wakes fired at the :00 mark, 7 to 50 s BEFORE `next_wake_at` (observed at least four times in one morning: 10:03, 10:53, others).
- `ap-start` -> `_ap_due` (`autopilot/scripts/autopilot-state.sh`) dispatches only when `ap-remaining` <= 30 (hard-coded). A wake more than 30 s early prints `already-on`, and SKILL.md Phase 1 says "never dispatch", so free slots stay free for one more wake.
- Cause (inferred, not verified): ScheduleWakeup reports the wake time rounded to the minute ("Next wakeup scheduled for 10:53:00 (in 170s)"), so a wake can land up to 59 s from the recorded second. The 30 s tolerance cannot cover that; 50 s early was observed.

## Fix

- Named constant `AP_WAKE_TOLERANCE` (default 60 s, env-overridable) used by `_ap_due`; a typed `on` minutes before the wake is still `already-on`.
- SKILL.md Phase 1/4 and `parallel.md`: record the wake with the same delay that is scheduled; ScheduleWakeup rounds to the minute, the 60 s tolerance covers it.
- Bats: wake 10 s early dispatches, 59 s early dispatches, 5 min early is `already-on`, exact-due dispatches.

## Related

- The larger autopilot redesign (holds, per-tier cursors) is pending an owner answer; not started here.

## Test plan

- [ ] `bats tests/autopilot_state.bats` green.
