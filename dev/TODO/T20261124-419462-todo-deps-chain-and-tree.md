---
status: Open
estimation: 2
blocks: [T20261124-177980]
depends_on: [T20261125-366351]
source: owner request 2026-11-24 (decision d158), epic E3
description: todo-deps.sh chain and tree: the derived dependency chain view with cycle detection and the first open leaf
---

# T20261124-419462: todo-deps.sh chain and tree

## Problem

- **Type**: feature
- Epic E3 (`dev/EPICS/E3-dependency-chain.md`); owner's words: "I want to remove 'blocked', and replace by its dependency chain."
- Depends on the compat reader from the schema task (T20261124-320024).
- Do: `todo/scripts/todo-deps.sh chain T<id>` prints `T<goal> <- T<dep1> <- T<dep2>` with each node's status and claimant, names a cycle instead of looping, caps depth at 10, and prints the first open leaf; `tree` lists every task with open dependencies. Read-only; `--json` for the HUD.
- A leaf claimed by a live peer shows as in progress by that peer. Tests in a new `tests/todo-deps.bats` (chain, diamond, cycle, depth cap, peer-claimed leaf, legacy `Blocked by` via the compat reader). Docs: one short paragraph in `todo/SKILL.md`, detail in a script header.
