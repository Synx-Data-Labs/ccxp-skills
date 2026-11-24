---
status: Done
estimation: 1
blocks: [T20261124-140678]
source: Owner chat 2026-11-24 (job 1490)
related: T20261103-169088
description: HUD limit cell shows the subscription percent left and reset time, and caches both windows for the autopilot
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261124-168446: HUD shows subscription limit left and reset time, and caches it

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

## Closed (2026-11-24)

- **Shipped in**: PR #745 (both windows with time left, `hud/scripts/hud-rate-cache.sh`, cache file `rate-limits.json`, tests, docs) and PR #748 (owner follow-up: the limit cell shows only the percent left and the reset time, window with less headroom, API-equivalent cost cell retired). Staging PR #720, claim PR #736. PR #739 was closed by mistake (branch deleted after a failed merge) and superseded by #745.
- **Data used (verified against the status-line docs)**: `rate_limits.five_hour` and `rate_limits.seven_day`, each `used_percentage` (0-100) and `resets_at` (epoch seconds); the mod reads them as `rateLimits[]` `kind`, `percentUsed`, `resetsAt`. A missing window or no data (API-key login) shows nothing and never errors.
- **Cache file for the autopilot**: `<profile>/state/hud-cache/rate-limits.json`, mode 600, atomic, no secrets, `{version, written_at, five_hour, seven_day}`; `hud-rate-cache.sh read [--max-age N]` for readers; a write never rolls a window back. Format in `hud/README.md`.
- **Design**: approved in conversation (owner's brief), no design PR.
- **Tests**: `claude plugin test .` 252 pass; 2 fail on a clean `main` too (config queue-source question text, "no ci configured" row count), unrelated; `tests/hud_rate_cache.bats` (16 tests).
- **Not done here (separate tasks)**: the limit-cell revision (runout text, reset clock with timezone, colouring by the gap to the runout; owner decisions d166 and d167) is a new HUD task by another job; the autopilot steering is T20261124-140678 (it depends on this task's cache file, which has landed).
- Quality probe: `dev/quality/metrics.jsonl` records the run; no regression.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, tests were written with the code, not red-first (see Closed)
- Verification (`superpowers:verification-before-completion`): yes, test runs before each push and a fresh independent review on every PR head (#720 x4, #736, #745, #748 x3; the closed #739 x3)
- Systematic debugging (`superpowers:systematic-debugging`): no, nothing got stuck
- Receiving code review (`superpowers:receiving-code-review`): yes, /address-pr 2.d on #739 (3 rounds) and #748 (2 rounds), 1 pushback (window without `resets_at`)
