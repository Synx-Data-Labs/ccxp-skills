---
status: Open
estimation: 1
source: Owner request in session, 2026-11-24 (job 1500)
related: T20261124-182499
description: HUD AP band shows the autopilot's effective max_dop and how it is used
---

# T20261124-239428: HUD shows the autopilot's effective max_dop

## Problem

- **Type**: feature
- Owner: "oh, for the hud, we should display the AP's maxdop there. so that at least we know what's the current config."
- Today the AP band shows elapsed time, loops, merged and 24h stats, but not the configured parallelism (`max_dop` in `dev/.autopilot-config.json`, read by `autopilot-state.sh config-show --json`).
- Done looks like:
  - Compact form in the AP band: running cycles out of max_dop (`AP on 8/16`).
  - Full form in `/hud details`: `max_dop 16 (14 routine + 2 reserved)` once `reserved_slots` exists (T20261124-182499); until then `max_dop` alone.
  - Warning color when running cycles are at the routine limit; one narrow-width shrink step drops it.
  - Silent when the autopilot is off and no config exists.
  - Tests, `hud/README.md` and the HUD help text updated.
