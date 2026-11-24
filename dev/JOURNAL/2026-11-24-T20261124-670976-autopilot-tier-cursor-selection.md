---
status: Done
estimation: 2
blocks: [T20261124-321658]
source: epic split of T20261124-989194 (job 1514), owner request 2026-11-24
related: [T20261124-989194]
type: feature
description: Make `top` and `pickable` choose within the highest tier with an eligible task, advancing a per-tier cursor that passes over held tasks only
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261124-670976: Autopilot picks by tier and a cursor

## Problem

- **Type**: feature
- Sub-task 3 of 5 of T20261124-989194 (autopilot cursor and holds).
- Replaces moving stalled tasks to the back of the queue: the order of `queue.md` is untouched, the cursor does the rotation.
- Dependency chain (d158): this task is done before T20261124-321658; queue order follows the chain.

## Done criteria

- [x] `top [--nth N]` and `pickable` read each task's tier (sub-task 1), choose the highest tier (lowest number) that has an eligible, not-held, not-in-flight task, and return its first such task in `queue.md` order; `--nth` keeps working inside that ordering.
- [x] A per-tier cursor in the state file remembers the last task dispatched so that a task that ended without a hold is not re-picked ahead of its tier-mates in the same pass; the cursor wraps to the tier's start when it passes the end. A cursor passes over a task only when `holds` lists it.
- [x] Reserved slots (d154/d157) take only tier 1 and 2 tasks: `top --urgent` considers only those tiers.
- [x] Tests: tier choice, cursor advance and wrap, held task passed over, release puts it back, reserved-slot tier filter, `--nth`.

## Closed (2026-11-24)

- Shipped in PR #762 (claim PR #761): `autopilot-state.sh top [--nth N] [--urgent]` picks inside the highest tier (frontmatter `tier:`, default 3) with a free task, per-tier cursors in the state (`cursors`, set by `busy on <id>`, kept over `off`/`start`), held tasks passed over by `top` and `pickable`, `top --urgent` limited to tiers 1 and 2; `todo-next.sh` gained `--tier` and `--ids`. 7 new tests in `tests/autopilot_state.bats`.
- Review rounds found and fixed a cursor that lost its place while its task was in flight or held, and a `top` that took 20 s per call (now one queue scan, peer claims checked only for the candidates it takes, about 4 s on this repo).
- Known and accepted: with a cursor set, `/top` moves a task to the front of its tier only relative to the cursor rotation; no bats case for a peer-claimed task in `top` (the claim check is the existing `todo-claim-state`). `busy on --urgent` is not restricted by tier (`parallel.md` lets `/top`'d tasks use the reserved slots).
- Follow-ups filed: none.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, tests written alongside the code
- Verification (`superpowers:verification-before-completion`): yes, local bats, skill score and plugin validate before every push, plus three independent review rounds on #762
- Systematic debugging (`superpowers:systematic-debugging`): no
- Receiving code review (`superpowers:receiving-code-review`): yes, two findings fixed (cursor place, performance)
