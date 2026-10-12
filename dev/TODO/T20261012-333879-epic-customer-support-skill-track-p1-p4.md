---
status: Blocked by T20261012-278418
estimation: 1
scheduled: 2026-10-12
source: this conversation, 2026-10-12 (user: "an epic task to keep track of all 4 subtasks ... we drive the epic, which drives the subtasks by priority")
related: [T20261012-109735, T20261012-949870, T20261012-383399, T20261012-278418]
description: Epic tracking the four-phase customer-support skill (intake, dry-run reporter, live reporting, CI enforcement)
---

# T20261012-333879: epic: customer support skill (track P1-P4)

## Problem

- **Type**: feature
- Goal: customer-reported GitHub issues get intake into a `support` task type, status updates with an ETA (daily, 4h, hourly as the due date nears), and a simplified repro plus an e2e regression test committed together with the fix.
- This epic only tracks the four phase tasks; each phase carries its own design and done criteria. Company-specific wiring is tracked in the company repo, not here.

## Children (ordered; chain P1 -> P2 -> P3 -> P4)

- [ ] **T20261012-109735** (P1): intake, `support` task type, lint keys, repro and same-commit regression gates.
- [ ] **T20261012-949870** (P2): status reporter engine in dry-run (cadence, renderer, marker, tick).
- [ ] **T20261012-383399** (P3): live reporting (manual-approved one-shot, then scheduled tick on one real task).
- [ ] **T20261012-278418** (P4): CI enforcement of the regression-commit rule and cadence tuning.

## Open questions (answered in the children; Q-numbers match their files)

- Q1 tone/approval, Q2 deadline format, Q3 opt-in storage, Q4 quiet hours, Q5 past-due cadence, Q6 hourly comment style, Q7 who posts, Q8 engine host, Q9 e2e test location, Q10 due-date source, Q11 Slack mirroring.
- Each is answered in the owning child's Closed section; the epic is not done while any stays open.

## Done criteria

- All four children are closed (in `dev/JOURNAL/`), and the open questions above are answered.

## How to drive

- Intended behavior: `/drive T20261012-333879` works through the children in queue/priority order, driving each child via `/drive`; the epic closes when all four are closed.
- Existing mechanism, used as-is: this epic is `Blocked by` the chain tail (P4), which is blocked by P3, P2, P1. `/drive`'s Phase 6 blocker recursion then reaches P1 first.
  - Resolved blockers cascade: as each child lands in `dev/JOURNAL/`, the next unblocks (`/todo sweep` strikes the stale block).
  - Once P4 closes, this epic unblocks; close it (checklist ticked, move to journal).
- Gap, not fixed here: the recursion chain is epic -> P4 -> P3 -> P2 -> P1 (depth 4), and `/drive` Phase 6 escalates at depth >= 3 ("task-graph rot") instead of recursing.
  - Workaround: drive the children directly in order (`/drive T20261012-109735`, then the next), using this epic as the tracking checklist.
  - A drive enhancement (epic-aware: walk a children checklist, exempt epics from the depth smell) needs its own task.
