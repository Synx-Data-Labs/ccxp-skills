---
status: Open
estimation: 1
source: owner request, this conversation, 2026-11-24
description: HUD queue max shows three non-overlapping rolling windows (last month / last week / this week) so the trend is visible
type: bug
---

# T20261124-776095: HUD queue max: non-overlapping rolling windows

## Problem

- **Type**: bug
- Owner: "we have a bug in the queue max stats, it should be max last month, last week, this week, thoughts? otherwise, if we increase the queue length, all of them will be the same, and I cannot see the trend." Then: "file a task and drive it to finish."
- Today (`hud/README.md` "Queue high watermark") the queue cell shows three NESTED windows (180d >= 30d >= 7d >= current), enforced in `hud/model.ts` parseHelper; when the queue grows all three equal the current peak, so no trend shows.
- Design, chosen by the owner (rolling over calendar buckets: "do the rolling window"): three adjacent, never overlapping windows relative to now:
  - this week = the trailing 7 days ending now, including the current length
  - last week = the 7 days before that (days 8 to 14 ago)
  - last month = the 4 weeks (28 days) before that (days 15 to 42 ago); owner: "last month, means last 4 weeks"
- Display: `max <lastMonth>/<lastWeek>/<thisWeek>` (e.g. `max 61/74/83`) plus a dim trend arrow comparing this week with last week (up, down, nothing when equal); warning colour when the queue is at the highest of the three.
- Remove the nesting enforcement and the 180-day figure from the queue cell (the issues cell keeps its own 180/30/7 windows, out of scope).
- Rules: windows are elapsed seconds (DST-safe); a window with no changes carries the length in force at its start; a window with no data at all (before the first history) shows `-`; no history yet: this week shows the current length, the others `-`; samples dated in the future (clock set back) are ignored.
- Data: no new source; aggregate the existing `hist-<key>` and `samples-<key>` series in `hud/scripts/hud-queue-hwm.sh`, backward compatible.
- Narrow terminals keep today's steps: `· max a/b/c`, then no watermark, then `queue len/total`.
- Done: bats tests pin each window edge (exactly 7, 14 and 42 days), growing (three numbers differ and rise), shrinking, flat, no changes, no history, narrow terminal; `hud/README.md` section rewritten; `hud/HELP.md` updated.
