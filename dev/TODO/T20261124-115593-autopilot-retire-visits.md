---
status: In Progress
estimation: 2
blocks: [T20261124-989194]
source: epic split of T20261124-989194 (job 1514), owner request 2026-11-24
related: [T20261124-989194]
type: feature
description: Remove `visits`, `visit`, `advance`, `max_visits`, `park`/`parked-list` machinery and update every doc and test (d156)
claimed_by: cc1-50ac6891:da50a3e74f488718
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261124-115593: Retire the visits counter, max_visits and park-after-N

## Problem

- **Type**: feature
- Sub-task 5 of 5 of T20261124-989194 (autopilot cursor and holds).
- d156: once the cursor and holds ship, the cursor replaces bottoming and visit counting. This is the last sub-task, so the umbrella closes with it.
- Dependency chain (d158): this task is done before T20261124-989194; queue order follows the chain.

## Done criteria

- [ ] Remove the `visits` and `parked` state, the `visit`, `advance`, `parked`, `parked-list` subcommands, the `max_visits` config key and the `visit|advance|park` history lines; `stats` and `final-report` keep working (a hold list replaces `parked-list` in "Needs your attention").
- [ ] Update `autopilot/SKILL.md` Phase 0, 0.2, 3, 4, 5 and Important Notes, `autopilot/parallel.md`, top-level `README.md` and `hud/README.md`; `drive/SKILL.md` and `bottom/SKILL.md` references to autopilot bottoming are reworded.
- [ ] `tests/autopilot_state.bats` drops the visits and park tests and keeps the rest green; an old state file with `visits` or `parked` reads without error and the keys are dropped on the next write.
- [ ] `claude plugin validate .` shows zero warnings.
