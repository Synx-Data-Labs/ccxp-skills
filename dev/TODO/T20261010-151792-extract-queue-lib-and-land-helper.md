---
status: In Progress
scheduled: 2026-10-12
estimation: 5
source: split from T20260928-101526
related: [T20260928-101526]
description: Extract `_queue/queue.sh` and a shared land-as-PR helper
claimed_by: cc1-50ac6891:367a03e82acbfe81
claimed_role: interactive
---

# T20261010-151792: Extract `_queue/queue.sh` and a shared land-as-PR helper

## Problem

- **Type**: refactor
- Queue editing is written out in `stage`, `top`, `bottom`, `todo sweep` and coded again in `migrate.sh` (README §2); commit/PR boilerplate is copied 3 times.
- Done looks like: `_queue/queue.sh` and a land-as-PR helper, both with BATS tests, consumed by the skills.

## Solution

- Extract the queue ops first, then the land helper; each its own PR.

## Test plan

- [ ] New BATS suites green; existing skill tests unchanged.

## Done criteria

- [ ] Both helpers exist, tested, and referenced from the skills.
