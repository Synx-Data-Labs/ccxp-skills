---
status: Done
estimation: 1
source: owner request, this conversation, 2026-11-24 (job 1514; decisions d152, d156, d160)
related: [T20261124-182499, T20261124-870400]
type: feature
description: Autopilot picks by tier and a cursor, and recorded holds replace bottoming and the visits counter
claimed_by:
claimed_role:
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

- [x] Sub-tasks filed and landed as one docs-only PR, the first one driven in the same run.
- [x] `claude plugin validate .` shows zero warnings.

## Split (2026-11-24)

- Sub-tasks, in dependency order (each `blocks:` the next; the last blocks this task):
  1. T20261124-345756: `tier:` frontmatter field
  2. T20261124-340374: holds store, `hold-add`, `release`, `holds`
  3. T20261124-670976: tier and cursor selection
  4. T20261124-321658: stalled cycle creates a hold, HUD held count
  5. T20261124-115593: retire visits, `max_visits`, park-after-N
- This task closes when sub-task 5 merges.

## Closed (2026-11-24)

What shipped (owner request "we need to drive the task to build the cursor", cursor option A, d152, d156, d158 to d162):

- `tier:` frontmatter, 1 to 4, default 3: lint and the `todo-tier` reader (PR #741; the lint and reader now agree on `02`, `+2` and `2.0`, fixed in PR #749).
- Holds store (PR #749, claim #746, close #759): `hold-add`, `holds [--json]`, `release`, `holds-check`; kinds `waiting|needs-human|stalled`; conditions `until`, `run:`, `pr:`, `file-changed`, `task-left-todo`; carried over `off`/`start`.
- Tier cursor selection (PR #762, claim #761, close #764): `top` and `pickable` pick in the highest tier with a free task, per-tier cursors, held tasks passed over, `top --urgent` for the reserved slots, `top --nth` intact.
- Holds replace bottom (PR #765, claim #766, close #767): `hold-report` turns a stalled cycle into a hold; no `/bottom`, no `queue.md` edit, no housekeeping agent or PR; HUD queue cell shows the hold count (`hd`).
- Visits retired (PR #768, claim #769, close #770): `visits`, `max_visits` and park-after-N removed.
- Also: PR #747 fixed the `todo` skill score ratchet left red by #741; the umbrella and sub-task lines were swept into `queue.md` in chain order (PR #749).

Known and accepted gaps: a `file-changed` hold also releases when a pull rewrites the task file; no hold is made while the loop is paused; a held task keeps its claim until the clone's next claim; `busy on --urgent` is not restricted by tier; `hud/pure.test.ts` could not run with the real runner locally. The changes reach the owner's running loop only after the owner updates the plugin; no release, tag or version bump was made.

Follow-ups filed: none.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, tests written alongside the code
- Verification (`superpowers:verification-before-completion`): yes, per sub-task
- Systematic debugging (`superpowers:systematic-debugging`): no
- Receiving code review (`superpowers:receiving-code-review`): yes, findings fixed in each sub-task PR
