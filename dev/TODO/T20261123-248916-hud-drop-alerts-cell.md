---
status: Review
estimation: 2
scheduled: 2026-11-23
source: owner message 2026-11-23 (job 1357)
description: Remove the Slack alerts-check cell and its config, helper and docs from the HUD
type: chore
claimed_by: cc1-50ac6891:beaec3e8bffbdc37
claimed_role: interactive
---

# T20261123-248916: drop the "alerts" cell from the HUD

## Problem

- **Type**: chore
- Owner (Shine, 2026-11-23): "we can drop the 'alerts' related features out of the HUD. The whole point is to track CI status, the customer support issues, and make sure we stay on top of them. So, whether we saw the slack alerts or not doesn't matter."
- The cell (`alerts checked 12m ago`, `alerts never checked`, `alerts held`) measured whether the persona had looked at Slack, not whether failures are handled.

## Design

- Remove from the HUD only: the `alerts` field and config key, `hud/scripts/hud-alerts.sh` and its bats, the model, types, detail row, help topic and README section. `agent-pairing/scripts/alerts-due.sh` and the persona's alerts check stay; they are not HUD features.
- A leftover `"alerts"` key or `alerts` entry in `fields` is ignored (unknown keys already are).
- The replacement the owner wants is tracked in T20261123-424791.

## Test plan

- [x] `bats tests/hud_*.bats` (help guard now covers `bus` too)
- [x] pure and hooks tests updated by hand (they only run in the Claude Code test runner)
