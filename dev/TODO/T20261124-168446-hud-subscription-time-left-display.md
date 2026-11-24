---
status: In Progress
estimation: 1
blocks: [T20261124-140678]
source: Owner chat 2026-11-24 (job 1490)
related: T20261103-169088
description: HUD shows the 5-hour and 7-day subscription windows with time left until reset, and caches the snapshot for the autopilot
claimed_by: cc1-50ac6891:eb8e263254b40cff
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261124-168446: HUD shows subscription time left (5h and 7d) and caches it

## Problem

- **Type**: feature
- Owner (2026-11-24): "and for the context in the hud, i want to know how much time left for the current subscription session to refresh, so that I can scale the AP max_dop properly? For example, if the subscription time limit is only 20% left, I would reduce the maxdop of AP down to 3." And: "file a new task, display first".
- Today the opt-in `rate` cell (`hud/model.ts` `rateSegs`, read in `hud/register.tsx` `usagePart`) shows only the 5-hour window as `5h 65% left`, with a runout estimate; there is no time-to-reset and no 7-day window.
- Source of data (verified in the status-line docs, https://code.claude.com/docs/en/statusline.md): `rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage` (0 to 100) and `rate_limits.five_hour.resets_at`, `rate_limits.seven_day.resets_at` (Unix epoch seconds). `rate_limits` exists only for claude.ai Pro, Max and Ultra logins and only after the first API response; each window may be absent on its own and is dropped once its `resets_at` passes.
- The HUD is a mod: it reads the same data from `$.session.usage().rateLimits[]` (`kind`, `percentUsed`, `resetsAt`).
- Only the HUD sees this data; the autopilot (`autopilot/scripts/autopilot-state.sh`) cannot, so the HUD must also write a snapshot file.

## Phase 1 (this task): display

- Band: the rate cell shows both windows, used or left percentage in the existing tone plus time to reset, e.g. `5h 20% left · resets 1h12m  7d 66% left · 3d4h`; a missing window shows nothing; no data shows no cell; never an error.
- Width: when both do not fit, show the window with less headroom; `/hud details` shows both in full.
- Colour: the HUD's existing `rateTone` (red under 10 left, orange under 25, else green).
- Cache file: atomic write (temp file plus rename), mode 600, no secrets, under the HUD cache dir (`state/hud-cache/`): used percentages, reset epochs, `written_at`; format documented in `hud/README.md` for the autopilot to read.
- Logic in `hud/model.ts` (pure) and a script under `hud/scripts/`; tests: TS (`hud/pure.test.ts`, `hud/hooks.test.tsx`) and bats; update `hud/README.md` and `hud/HELP.md`.
- Tests cover: both present, one missing, both missing, past reset time, rounding, colours at the boundaries.

## Phase 2 (separate task)

- Autopilot steering, filed as T20261124-140678 (blocked by this task).
