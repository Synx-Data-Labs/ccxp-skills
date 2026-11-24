---
status: Open
estimation: 2
blocks: [T20261124-444596]
blocked-by: T20261124-315192
source: owner request 2026-11-24 (decision d155), epic E2
related: [T20261124-444596]
description: Turn autopilot SKILL.md Phase 3 and 4 deterministic classification and housekeeping dispatch prose into tested scripts
---

# T20261124-870400: autopilot Phase 3/4 classification and housekeeping dispatch into scripts

## Problem

- **Type**: chore
- Epic E2. `autopilot/SKILL.md` is 193 lines / 24794 B; Phase 3 (run one cycle, lines 77 to 123) and Phase 4 (classify, notify, reschedule, lines 124 to 161) are about 85 lines of mostly deterministic steps. The helper `autopilot/scripts/autopilot-state.sh` already holds 1072 lines.
- Step 1: survey, per step, what is deterministic (classification of a cycle outcome, housekeeping dispatch choice, notify text) versus judgment (what to do about an unexpected state). Record it in this task before moving anything.
- Step 2: move the deterministic part into subcommands of `autopilot-state.sh` or a new `autopilot/scripts/classify.sh`, with bats tests; `SKILL.md` keeps orchestration and judgment, following `skill-conventions` (§ on scripts and §9 paths).
- Behaviour identical: existing `tests/autopilot_state.bats` stays green; do not touch the early-wake fix of job #1455 (PR 711) beyond rebasing on it.
- Report lines of prose removed and bugs found (a duplicated rule or a script/prose mismatch counts).

## Done criteria

- Before/after line count of Phase 3/4 recorded, new tests green, `SKILL.md` Phase 3/4 at most half of today's size.
