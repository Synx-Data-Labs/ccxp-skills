---
status: Review
estimation: 1
source: Owner chat 2026-11-24 (job 1523, decisions d166 and d167)
related: T20261124-168446
description: HUD limit cell shows % left, runs out in Nm and reset time with timezone, colored by the gap to runout
---

# T20261124-363815: HUD limit cell colored by the gap to runout

## Problem

- **Type**: feature
- Owner (2026-11-24): "HUD, I like the 'runs out in 28m', and with the 'reset 13:55 CST', and we color it based on the gap, if >30m, we are green, >10m, we are yellow, and <10m we are red." And: "decision d166 [and d167] should be a new task to improve the HUD."
- d166: the limit cell is colored by the time until runout: more than 30 minutes green, more than 10 up to 30 yellow, 10 or less red; replaces any percent-based coloring.
- d167: the limit row shows % left, the runout text `runs out in 28m` and the reset time with timezone abbreviation `reset 13:55 CST`; no `5-hour limit` or `7d` window label; only the window with less headroom is shown; API-equivalent cost stays retired (d164).
- Builds on T20261124-168446 (percent left, reset time, no window labels, cost retired); do not duplicate it.

## Spec

- Runout text only when the projected runout is before the reset; otherwise no runout text and green.
- Thresholds are named constants; `NO_COLOR` handling as the rest of the HUD.
- Timezone abbreviation computed from the system timezone.
- Narrow forms drop the reset text first, then runout, and keep % left; the details row shows the full text.
- Tests: boundaries 31/30/11/10 minutes and the no-runout case; update the old-cell inventory test, `hud/README.md` and `hud/HELP.md`.
- The cell keeps its place in the SESSION section row of the sectioned layout.
