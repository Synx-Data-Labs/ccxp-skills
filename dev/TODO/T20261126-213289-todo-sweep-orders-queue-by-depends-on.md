---
status: In Progress
estimation: 1
source: owner request 2026-11-26 (typed words quoted below), epic E3 spec item 7, decisions d158 and d182
type: feature
claimed_by: cc1-50ac6891:3259fb54c60ab149
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261126-213289: `/todo sweep` orders queue.md by depends_on

## Problem

- Owner's words (2026-11-26): "also, /todo sweep can use the \"depends_on\" to adjust the priority in the queue.md."
- Decision d158 (retire the `Blocked by` status): a task records its dependency chain in `depends_on` and is never shown as blocked; the owner's words are quoted in `dev/EPICS/E3-dependency-chain.md`.
- Decision d182 (retire `blocks:`): `depends_on` stays the only authored relation; dependants are its inverse and old `blocks:` lines are read as a fallback.
- Today `todo/scripts/todo-sweep.sh` Phase 2 ("enforce blocker ordering") derives order violations only from `status: Blocked by` (`sw_blockers`), so a task with `depends_on: [Y]` and Y queued behind it is never reported or fixed.
- Done looks like: `plan` and `apply --phase 2` order the queue from `depends_on`, with the legacy `Blocked by` status and `blocks:` still read as a fallback.

## Design

Design approved in-conversation 2026-11-26 (owner request above); no design PR.

- **Edge source**: one edge `dependency -> dependant` per id the compat reader `todo-deps` returns for a task (`depends_on` plus legacy `Blocked by`), plus one per id in a task's legacy `blocks:` line (`todo-legacy-blocks`, same stderr warning as `todo-dependants`, now shared through `todo-legacy-blocks-warn`). No new parsing.
- **Open dependencies only**: an edge whose ends are not both in `dev/TODO/` (done, journaled, parked, unknown) is ignored; sweep never rewrites `depends_on`.
- **Move**: for every edge where the dependency is queued behind its dependant, move the dependency immediately before the dependant (the `/top --before` behaviour, `q_insert_before`, never the absolute front); dependencies of the same task keep their relative order; the loop repeats until the order is topological.
- **Cycle**: detected before anything is written; `plan` prints `CYCLE <ids>`, `apply --phase 2` exits 4 and moves nothing.
- **Plan output**: `ORDER_VIOLATION <dependency> <dependant> <edge>` where `<edge>` is `depends_on`, `blocked-by` (legacy status) or `blocks` (legacy field).

## Test plan

- BATS in `tests/todo_sweep.bats`: linear chain, diamond, cycle, missing/closed dependency, legacy `Blocked by` and `blocks:` fallback, idempotent second apply.
- `bats tests/todo_sweep.bats tests/todo-deps.bats tests/todo-lib.bats`, then the whole suite and the `gcpr` doc lints.

## Not in scope

- A release, version bump or tag (maintainer-triggered).
- Dropping a satisfied `depends_on` entry or striking `## Dependencies` lines for it.
