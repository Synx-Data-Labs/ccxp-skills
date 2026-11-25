---
status: Open
estimation: 2
depends_on: [T20261125-255147]
source: split of T20261125-264487 (retire blocks), epic E3
related: T20261125-264487, T20261124-158321
description: HUD blocked bucket counts open depends_on, autopilot big-task rule gives the umbrella depends_on its sub-tasks instead of sub-tasks blocks the umbrella
---

# T20261125-187172: HUD blocked bucket and autopilot big-task rule on depends_on

## Problem

- **Type**: feature
- HUD `hud/scripts/hud-lib.sh` "blocked" bucket counts only legacy `Blocked by T<id>` status; it must also count a task with an open `depends_on` entry (and, from the compat reader, a task named in an open task's legacy `blocks:`). Update `hud/README.md`, `hud/HELP.md`, `hud/model.ts` comment.
- `autopilot/SKILL.md` Big tasks rule tells sub-tasks to carry `blocks: <original>`. Change it: the original gets `depends_on: [sub-ids]` and queue order puts the sub-tasks right before it; its `status:` stays untouched. Keep net-zero size (the file is size-sensitive); `autopilot-state.sh` comments follow.
- Tests: `tests/hud_queue_source.bats` (blocked bucket), `tests/autopilot_state.bats`. Rebase on HUD changes already on main first.
