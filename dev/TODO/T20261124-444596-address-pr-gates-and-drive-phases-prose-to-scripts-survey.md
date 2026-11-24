---
status: Open
estimation: 2
blocked-by: T20261124-870400
source: owner request 2026-11-24 (decision d155), epic E2
related: [T20261124-870400]
description: Survey address-pr gate steps and drive phases for deterministic prose, move the highest-payoff part into a tested script, file the rest
---

# T20261124-444596: address-pr gates and drive phases: survey, then first script

## Problem

- **Type**: chore
- Epic E2. `address-pr/SKILL.md` 369 lines / 37747 B (hard gate 2a, review 2d, test plan 2e, notify 3 are long prose; `scripts/` already has 10 helpers); `drive/SKILL.md` 694 lines / 74633 B (Phase 3 Implement alone is 170 lines; only 4 scripts).
- Survey both with the method from the autopilot task: per step, deterministic versus judgment; list candidate scripts, expected lines removed and risks, ordered by payoff (lines removed and bugs found).
- Implement only the top candidate here (script plus bats tests, `SKILL.md` shortened to a call); file one task per further candidate under epic E2, `ccxp`, `retro`, `ipm`, `todo` skills included by the same ranking.
- Follow `skill-conventions`; behaviour identical; existing address-pr and drive bats stay green.

## Done criteria

- Survey table in this task's Closed section, one script landed with tests, follow-up tasks filed and linked in epic E2.
