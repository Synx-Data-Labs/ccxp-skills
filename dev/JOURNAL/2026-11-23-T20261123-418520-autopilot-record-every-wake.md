---
status: Done
estimation: 2
source: Owner request 2026-11-23 (job 1380)
type: fix
description: Autopilot records next_wake_at with every ScheduleWakeup it arms, so an idling loop never reads as stalled
claimed_by:
claimed_role:
---

# T20261123-418520: Autopilot records every armed wake

## Problem

- Owner's words: "quick q, how come the AP can have overdue?" ... "let's file a task for this bug and fix it."
- `autopilot-state.sh` writes `next_wake_at` only in `record` and `hold`
- While the loop idles (slots busy with `max_dop` above 1, or a long task), the dispatcher re-arms `ScheduleWakeup` (15-30 min) with no state write
- Evidence: `next_wake_at` 20:27Z while now 23:47Z and the loop alive; the HUD stalled cell / `/hud details` ("next loop overdue 2d 16h") report a live loop as stalled

## Design

- New `autopilot-state.sh wake <seconds> [reason]`: sets `next_wake_at = now + seconds` (1-86400), no counters, slots or `last_hold`; no write unless status is `on`
- `hold` stays as is (it also sets `last_hold`, used by the parallel guard and ramp)
- SKILL.md and parallel.md: one rule, "never arm a wake without recording it"; each `ScheduleWakeup` follows `record`, `hold` or `wake` in the same step, including a wake that fires while every slot is busy
- HUD: no change needed; `stalledFor` and `hud-lib.sh` already treat a busy loop (any fresh slot mark, so `busy_slots` above 0) as never overdue; documented in `hud/README.md`

## Acceptance criteria

- [x] bats: stale wake reads overdue, then 0 after `wake`; nothing else touched
- [x] Docs updated (SKILL.md, parallel.md, hud/README.md)

## Closed (2026-11-23)

- Shipped in PR #703 (merged); released in ccxp-skills 6.5.0 (tag `ccxp-skills--v6.5.0`).
- Met: both acceptance criteria above are checked.

## Skills invoked

- TDD (`superpowers:test-driven-development`): not recorded (closed from the job 1380 hand-off)
- Verification (`superpowers:verification-before-completion`): yes, /address-pr gate on #703
- Systematic debugging (`superpowers:systematic-debugging`): no
- Receiving code review (`superpowers:receiving-code-review`): see PR #703 review comments
