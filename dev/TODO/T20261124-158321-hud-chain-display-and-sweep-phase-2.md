---
status: Open
estimation: 2
source: owner request 2026-11-24 (decision d158), epic E3
description: HUD shows the dependency chain and a waiting-on-deps count instead of held; sweep Phase 2 orders dependencies and drops satisfied depends_on entries
---

# T20261124-158321: HUD chain display and sweep Phase 2

## Problem

- **Type**: feature
- Epic E3 (`dev/EPICS/E3-dependency-chain.md`); owner's words: "I want to remove 'blocked', and replace by its dependency chain."
- Do: HUD (`hud/scripts/hud-lib.sh`, `hud/README.md`, `hud/HELP.md`) replaces held with the chain of the driven task (`T1 -> T2 -> T3`, depth) and a `waiting on deps` count; human-only conditions get their own count from `needs:`. `todo-sweep.sh` Phase 2: order dependencies before dependants (kept), drop satisfied `depends_on` entries, never rewrite status.
- Rebase on the HUD jobs in flight before starting; tests: `tests/hud_queue_source.bats`, `tests/hud_lib.bats`, `tests/todo_sweep.bats`. Then file the deprecation task that removes `Blocked by` and the compat reader, and record the epic open question Q5 (window length) in this task's Closed section.
