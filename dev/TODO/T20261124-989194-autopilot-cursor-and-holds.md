---
status: Open
estimation: 1
source: owner request, this conversation, 2026-11-24 (job 1514; decisions d152, d156, d160)
related: [T20261124-182499, T20261124-870400]
type: feature
description: Autopilot picks by tier and a cursor, and recorded holds replace bottoming and the visits counter
---

# T20261124-989194: Autopilot cursor and holds replace bottom and visits

## Problem

- **Type**: feature
- Owner's words: "I was thinking 'bottom' is replaced by the 'cursor'?" and, answering the open design question, "cursor: option A".
- Option A: a task's tier comes from a `tier:` field in the task file's frontmatter, not from `## P<n>` headers in `queue.md`.
- Today a cycle that ends `NEEDS-ATTENTION` or `STUCK` has the task `/bottom`ed (a housekeeping PR edits `queue.md`) and bumps a visits counter; after `max_visits` the task is parked (`autopilot/SKILL.md` Phase 3 and 4).
- d156: retire the visits counter, `max_visits` and park-after-N once cursor and holds ship; the cursor replaces bottoming and visit counting.
- d152: the dispatcher never skips or holds an eligible task on its own judgment; any hold is a recorded hold with a reason and a release condition.
- d154 and d157: 2 slots are reserved for urgent work; d160: red-nightly related tasks go to tier 1, new synxdb-support issues land in tier 2.
- Done looks like: tiers and cursors pick the task, holds are listed and released with a command, the HUD queue cell shows the held count, and the visits machinery is gone.

## Design (to be split, about 5 sub-tasks)

- `tier:` frontmatter field
  - Integer 1..4; a task without it has the default tier 3.
  - Validated by `lint_tasks.py` and the task template; documented in `todo/SKILL.md` "Task metadata".
- Per-tier cursors
  - The autopilot picks inside the highest tier that has an eligible task.
  - Within a tier a cursor advances through the `queue.md` order; stalled tasks are not moved to the back.
  - A cursor passes over a task only when it has a recorded hold.
- Holds
  - Kinds `waiting`, `needs-human`, `stalled`; each records a reason and one release condition: `until <time>`, `run:<id>`, `pr:<n>`, `file-changed <path>`, `task-left-todo <T-id>`.
  - Stored in the autopilot state (local, gitignored), with a command to list and release them.
  - The HUD queue cell shows the held count, with no per-task text.
- Replacing bottom and visits
  - A cycle that ends `NEEDS-ATTENTION` or `STUCK` creates a hold (`needs-human` or `stalled`) instead of a bottom PR: no `queue.md` edit and no housekeeping PR.
  - The visits counter, `max_visits` and the park path are removed in the last sub-task; `SKILL.md` Phase 3 and 4, `parallel.md`, `README.md` and the tests are updated then.
  - Queue-order changes stay owner or sweep driven.
- Compatibility: reserved slots take only tier 1 and 2 tasks; `top --nth` keeps working.
- Tests: extend `tests/autopilot_state.bats` (hold, release, cursor, tier selection). Docs: `autopilot/SKILL.md`, `hud/README.md` where needed.

## Done criteria

- [ ] Sub-tasks filed and landed as one docs-only PR, the first one driven in the same run.
- [ ] `claude plugin validate .` shows zero warnings.

## Split (2026-11-24)

- Sub-tasks, in dependency order (each `blocks:` the next; the last blocks this task):
  1. T20261124-345756: `tier:` frontmatter field
  2. T20261124-340374: holds store, `hold-add`, `release`, `holds`
  3. T20261124-670976: tier and cursor selection
  4. T20261124-321658: stalled cycle creates a hold, HUD held count
  5. T20261124-115593: retire visits, `max_visits`, park-after-N
- This task closes when sub-task 5 merges.
