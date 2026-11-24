---
status: Open
estimation: 2
blocks: [T20261124-158321]
source: owner request 2026-11-24 (decision d158), epic E3
description: Drive Phase 6 and autopilot pick work the first open leaf of the dependency chain; the goal stays In Progress, no skipping
---

# T20261124-112157: Drive and autopilot work the first open leaf

## Problem

- **Type**: feature
- Epic E3 (`dev/EPICS/E3-dependency-chain.md`); owner's words: "I want to remove 'blocked', and replace by its dependency chain."
- Do: `/drive` Phase 6 records `depends_on` instead of writing `Blocked by` and keeps the goal's real status (drops the `status.sh Blocked` mirror); auto-pick and `/autopilot` work the first open leaf from `todo-deps.sh chain`; autopilot `bottom` and `park` guards read `depends_on`; `todo-gated` drops `Blocked by` and reads `needs:` (auto-pick and the ccxp pre-flight gate, epic spec item 5). Resolves epic open question Q4.
- SKILL.md edits minimal and net-zero (autopilot/SKILL.md is size-sensitive for skill quality); detail goes to docs and scripts. Tests: `tests/todo-next.bats`, `tests/autopilot_state.bats`, drive eval where one exists.
