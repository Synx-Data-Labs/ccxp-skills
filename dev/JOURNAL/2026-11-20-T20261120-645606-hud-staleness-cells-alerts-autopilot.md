---
status: Done
estimation: 1
source: Job 1339 analysis (n362), owner 2026-11-20 "then fix n362"
description: HUD staleness cells - alerts checked Xm ago, stalled autopilot when next_wake_at is overdue
type: feature
related: T20261120-230152
claimed_by:
claimed_role:
scheduled: 2026-11-16
---

# T20261120-645606: HUD staleness cells for alerts check and autopilot (n362 step 2)

## TLDR

- **Type**: feature
- **Problem**: nobody could tell that Slack alerts were never checked and that autopilot was stalled (`next_wake_at` 2 days overdue).
- **Solution**: a new HUD "alerts checked Xm ago" cell fed by `alerts-due.sh`'s local state (degrading to no cell when the plugin has no alerts check); the stalled-autopilot cell already exists on main (`stalled 2d`) and is made red by T20261120-154507.

## Problem

- Evidence: r1339 section 0: `~/.claude-work/ccxp-alerts/` did not exist (the alerts check never ran on this profile) and the autopilot loop was 2 days overdue; neither was visible.
- Impact: the persona's CI and Slack checks only run at turns and autopilot wakes, so a silent stall meant no detection.

## Context

- #657 (alerts-due.sh, `last-check`, `hold` under `<profile>/ccxp-alerts/`) is on main, so the state exists; a plugin version without `agent-pairing/scripts/alerts-due.sh` must still work (graceful degradation).
- The stalled cell exists: `hud/model.ts` `stalledFor` and the band `stall` item (`hud/README.md` "Stalled cell"); this task does not duplicate it.

## Solution

- `hud/scripts/hud-alerts.sh` (local files only): `{"checked_at","held"}` from `last-check` and `hold`; null when off (`alerts: false`, `CCXP_ALERTS=0`) or when this plugin has no `alerts-due.sh`; "never checked" (checked_at 0) when the state is absent.
- `hud/model.ts` `alertsVariants`: dim `alerts checked 12m ago` within 30 min, warning beyond or when never checked, error `alerts held`; new `alerts` field after `issues` in both modes, dropped before the queue and nightly cells; a details line.
- Alternatives rejected:
  - showing the cell only when the persona is in use: the HUD cannot tell, and the missing check is exactly what must be visible;
  - a second stalled cell: one already exists, T20261120-154507 only restyles it.

## Test plan

- [x] `bats tests/hud_alerts.bats` (epoch, never checked, hold, garbage and future stamps, degradation, hud-data wiring).
- [x] `hud/pure.test.ts`: `parseHelper`, `alertsVariants`, band drawing, config switch, details superset (not runnable outside the Claude Code test runner; reviewed by hand).
- [ ] CI: bats suite green on the PR.

## Done criteria

- [x] "alerts checked Xm ago" with stale colouring: `hud/model.ts` `alertsVariants`, `hud/pure.test.ts` "alerts cell".
- [x] Graceful degradation without #657: `tests/hud_alerts.bats` "degrades to null".
- [x] Stalled autopilot cell for an overdue `next_wake_at`: already present, `hud/pure.test.ts` "next loop" tests (red styling is T20261120-154507).

## Closed (2026-11-20)

- Shipped in the PR that moves this file to `dev/JOURNAL/` (job 1342).
- Quality regression note: only added files and lines; the new cell is the task.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, bats tests written with the code in one pass
- Verification (`superpowers:verification-before-completion`): yes, local bats runs plus /address-pr gate
- Systematic debugging (`superpowers:systematic-debugging`): no, did not get stuck
- Receiving code review (`superpowers:receiving-code-review`): yes, /address-pr review
