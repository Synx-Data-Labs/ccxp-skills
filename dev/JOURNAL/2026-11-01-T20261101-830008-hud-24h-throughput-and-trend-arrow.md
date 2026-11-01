---
status: Done
scheduled: 2026-10-26
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

## Journal

- Root cause confirmed: the owner's pointer repo has no `dev/.autopilot-history.jsonl` (its last cycle, 2026-10-30, predates the 5.6.0 tag, 2026-10-31), so `stats.has_history` was false and the cell showed only `average N/day`
- The arrow already existed in 5.6.0 (`▲` green, `▼` yellow, `=`), after `N loops`; PR #526 only reordered the line, the 24h cell is identical on main and in 5.6.0
- Fix: `autopilot-state.sh stats` adds `approx` and a calendar-day-counter estimate when the log does not cover the window (exact 0 when no cycle ran in 24 h); the HUD always shows the 24h number, puts the arrow right after it (green `▲`, red `▼`, none when equal at one decimal or for a `~` estimate), and keeps the cell on the details AP line until last
- Independent review found "lower bound" was wrong for the calendar-day counters; relabeled as an estimate with no arrow

| File | Change |
|---|---|
| `autopilot/scripts/autopilot-state.sh` | `approx` flag, estimate fallback, text form |
| `hud/model.ts`, `types/index.d.ts` | arrow placement and colours, `~` mark, details step order |
| `hud/scripts/hud-lib.sh`, `hud/scripts/hud-data.sh` | pass `approx` through |
| `hud/pure.test.ts`, `tests/autopilot_state.bats`, `tests/hud_data.bats` | new cases |
| `hud/README.md`, `autopilot/SKILL.md` | documented |

## Closed (2026-11-01)

- Shipped in PR #530; CI green (bats, Markdown Lint, lint-tasks, skill-quality, sync-tasks); independent review posted
- Not live until a release is cut and the owner runs `/ccxp-skills:update`
- Next steps: none required; the HUD shows `~N` without an arrow until the history log covers 24 h, then exact figures with the arrow
