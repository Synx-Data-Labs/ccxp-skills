---
status: Done
estimation: 1
source: Owner chat 2026-11-24 (job 1527)
related: T20261124-168446
description: HUD limit cell shows the window that runs out first; colour and text share whole-minute rounding
---

# T20261124-382725: HUD limit cell prefers the window that runs out first

## Problem

- **Type**: feature
- Owner (2026-11-24): "limit cell prefer window that runs out first". Decision d167 amended: no window label; show % left, runout and reset time with timezone.
- Before: `tighter()` in `hud/model.ts` showed the window with less % left, which can hide a window that will actually run out sooner.
- Rounding mismatch from job 1523: colour used exact seconds, text rounded to minutes (10m20s showed `10m` in yellow).

## Solution

- `firstToRunOut` ranks windows by earliest projected runout before their own reset; no runout ranks last; none or a tie falls back to less % left, then 5h. A spent window (0 left) counts as gap 0.
- Gap is floored to whole minutes before colour and text, so both agree (10m20s reads `10m`, red).
- Cache file still gets both windows (unchanged). Gap colour (d166) comes from the chosen window.

## Test plan

- `hud/pure.test.ts`: 5h first, 7d first, neither runs out, one window missing, ties, spent window; rounding boundaries at 10m20s, 10m59s, 11m, 30m59s, 31m. Old-cell inventory updated (27m to 26m under rounding down).
- `claude plugin test .`: only the 2 failures that also fail on clean main.

## Done criteria

- README and HELP updated; PR merged with green CI and an independent review. No release or version bump.
