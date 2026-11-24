---
status: Done
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

- [x] `bats tests/autopilot_state.bats` green.

## Closed (2026-11-24)

- Shipped in the PR that carries this file. Finding: a 30 s tolerance already existed in `_ap_due` (hard-coded); it was too small for the observed 7-50 s early wakes. Now `AP_WAKE_TOLERANCE` (default 60, env override), tests in `tests/autopilot_state.bats` (exact, 10 s, 50 s, 60 s early dispatch; 61 s and 5 min early already-on), SKILL.md and parallel.md pairing note.
- Unverified: the minute-rounding mechanism in ScheduleWakeup (inferred from the owner's timestamps). A release is needed for the plugin to ship it (not done here).
- Decision: claim PR and separate design PR skipped (one-bug, self-evident, owner-approved); task filed, fixed and closed in one PR.

## Skills invoked

- TDD: partial (tests written with the fix, not red-first)
- Verification: yes, bats tests/autopilot_state.bats 150/150
