---
status: Open
estimation: 3
source: Conversation 2026-10-27 (user spec for the ccxp-hud redesign)
related: T20261022-287778
description: Redesign the ccxp-hud band as one row in two modes (AP on/off) with a configurable CI cell, /hud pane toggle and /hud setup
---

# T20261027-237157: ccxp-hud one-row band, AP on/off modes, configurable CI cell

## Problem

- **Type**: feature
- The band wrapped to up to three rows and always showed the jobs ledger, which the user already sees elsewhere.
- Done looks like:
  - One row at every width; two modes picked from autopilot state.
  - AP off: `repo | branch | T<id> slug | CI | you HH:MM`. AP on: `AP elapsed/duration loops n ✓merged | ctx % | CI | you HH:MM`.
  - Jobs cell removed (pane keeps its ledger line).
  - CI cell = last run of a workflow configured in `ccxp-hud.json` (`ci` key, user file + project override); unset means no cell. Cached, non-blocking, silent on any failure.
  - `/hud pane` toggles; `/hud setup` writes the `ci` block after validation and confirmation.

## Decisions

- Mode: AP on = running, backing off or paused (paused marked); else off.
- Task slug = the task title, cut at a word boundary.
- Fields order is fixed per mode; `fields` only switches cells off. An old explicit `fields` list without `repo`/`ci` hides them.
- CI default is unset (no cell); nothing hard coded. synxdb-build-pipeline would set `{"ci": {"workflow": "nightly-orchestrator.yml"}}` in its project `.claude/ccxp-hud.json` (not added by this task).
- Plugin version not bumped here (separate bump PR per dev/guidelines.md).

## Test plan

- [x] `claude plugin test .` (band modes, tiers, drop order, CI states, config, setup, pane toggle)
- [x] `bats tests/hud_data.bats tests/hud_ci.bats`
- [ ] Live terminal check: see T20261022-287778 (new items added there).
