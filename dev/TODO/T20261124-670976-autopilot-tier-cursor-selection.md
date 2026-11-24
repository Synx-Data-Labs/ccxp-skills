---
status: Open
estimation: 2
blocks: [T20261124-321658]
source: epic split of T20261124-989194 (job 1514), owner request 2026-11-24
related: [T20261124-989194]
type: feature
description: Make `top` and `pickable` choose within the highest tier with an eligible task, advancing a per-tier cursor that passes over held tasks only
---

# T20261124-670976: Autopilot picks by tier and a cursor

## Problem

- **Type**: feature
- Sub-task 3 of 5 of T20261124-989194 (autopilot cursor and holds).
- Replaces moving stalled tasks to the back of the queue: the order of `queue.md` is untouched, the cursor does the rotation.
- Dependency chain (d158): this task is done before T20261124-321658; queue order follows the chain.

## Done criteria

- [ ] `top [--nth N]` and `pickable` read each task's tier (sub-task 1), choose the highest tier (lowest number) that has an eligible, not-held, not-in-flight task, and return its first such task in `queue.md` order; `--nth` keeps working inside that ordering.
- [ ] A per-tier cursor in the state file remembers the last task dispatched so that a task that ended without a hold is not re-picked ahead of its tier-mates in the same pass; the cursor wraps to the tier's start when it passes the end. A cursor passes over a task only when `holds` lists it.
- [ ] Reserved slots (d154/d157) take only tier 1 and 2 tasks: `top --urgent` considers only those tiers.
- [ ] Tests: tier choice, cursor advance and wrap, held task passed over, release puts it back, reserved-slot tier filter, `--nth`.
