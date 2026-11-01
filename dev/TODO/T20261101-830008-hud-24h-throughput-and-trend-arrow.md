---
status: Open
estimation: 1
source: owner request via ccxp-hud, 2026-11-01
description: HUD details line shows last-24h throughput always, with a green up / red down arrow against the average
---

# T20261101-830008: HUD shows last-24h throughput with a trend arrow against the average

## Problem

- **Type**: bug
- Owner report: with `/hud details` on, the last-24h throughput never shows, only `average N/day`, so the two cannot be compared.
- Root cause: `hud/model.ts` `apStatsVariants` drops the 24h number when `stats.has_history` is false, and `dev/.autopilot-history.jsonl` only exists once a cycle ran on 5.6.0+ (the owner's pointer repo has none: its last cycle predates the 5.6.0 tag).
- The arrow exists (`▲` green / `▼` yellow / `=`) but sits after `N loops`, not next to the 24h number; down is yellow, not red; flat shows `=`.
- Done: 24h number always shown (exact 0 when no cycle in 24 h, `~N` lower bound from the state's calendar-day counters when the log does not cover the window), green `▲` right after the 24h merged count when above the average, red `▼` when below, no arrow when equal at one decimal or when there is no average; tests for each.
