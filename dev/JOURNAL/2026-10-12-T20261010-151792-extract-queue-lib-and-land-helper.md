---
status: Done
scheduled: 2026-10-12
estimation: 5
source: split from T20260928-101526
related: [T20260928-101526]
description: Extract `_queue/queue.sh` and a shared land-as-PR helper
claimed_by:
claimed_role:
---

# T20261010-151792: Extract `_queue/queue.sh` and a shared land-as-PR helper

## Problem

- **Type**: refactor
- Queue editing is written out in `stage`, `top`, `bottom`, `todo sweep` and coded again in `migrate.sh` (README §2); commit/PR boilerplate is copied 3 times.
- Done looks like: `_queue/queue.sh` and a land-as-PR helper, both with BATS tests, consumed by the skills.

## Solution

- Extract the queue ops first, then the land helper; each its own PR.

## Test plan

- [x] New BATS suites green; existing skill tests unchanged.

## Done criteria

- [x] Both helpers exist, tested, and referenced from the skills.

## Closed (2026-10-12)

- Shipped in two PRs: #335 (`_queue/queue.sh` + `tests/queue_lib.bats`, consumed by stage/top/bottom/todo sweep/migrate-task) and the follow-up land-helper PR (`_gh/land.sh` + `tests/land.bats`, consumed by stage/top/bottom).
- Done criteria met: both helpers exist, are BATS-tested (12+2 and 4 tests) and are referenced from the skills; existing `migrate_task.bats` unchanged and green.
- Not converted: `/gcpr`, `/claim`, retro and drive keep their own commit/PR steps (they carry task-status flips and PR-body conventions beyond the 3-skill boilerplate); no follow-up filed.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, not invoked as a skill (tests written alongside the code)
- Verification (`superpowers:verification-before-completion`): yes, full bats + shellcheck run before each PR
- Systematic debugging (`superpowers:systematic-debugging`): no, didn't get stuck (one broken-python3 env quirk)
- Receiving code review (`superpowers:receiving-code-review`): yes, /address-pr on #335, 3 findings fixed, 2 declined with comment
