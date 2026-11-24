---
status: Open
estimation: 2
blocks: [T20261124-670976]
source: epic split of T20261124-989194 (job 1514), owner request 2026-11-24
related: [T20261124-989194]
type: feature
description: Add recorded holds to the autopilot state with commands to create, list and release them
---

# T20261124-340374: Autopilot holds: store, `hold`, `release`, `holds`

## Problem

- **Type**: feature
- Sub-task 2 of 5 of T20261124-989194 (autopilot cursor and holds).
- d152: the dispatcher never skips or holds a task on its own judgment; a hold is a recorded fact with a reason and a release condition. Nothing consumes holds yet (sub-task 3).
- Dependency chain (d158): this task is done before T20261124-670976; queue order follows the chain.

## Done criteria

- [ ] `autopilot-state.sh hold-add <T-id> <kind> <release-condition> "<reason>"` with kind `waiting|needs-human|stalled` and condition `until <time>`, `run:<id>`, `pr:<n>`, `file-changed <path>` or `task-left-todo <T-id>`; refuses (exit 2) an unknown kind or condition and an empty reason (d152: no hold without both).
- [ ] `holds [--json]` lists them (task, kind, reason, condition, since); `release <T-id>` removes one; `holds-check` releases every hold whose condition is met (time passed, run concluded via `gh`, PR merged or closed, file mtime or git change since the hold, task no longer in `dev/TODO`) and prints what it released.
- [ ] Holds live in the state file (local, gitignored) and survive `off`/`start`; `prune` drops holds of tasks that left `dev/TODO`.
- [ ] Tests in `tests/autopilot_state.bats` for add, refusals, list, release, each condition kind (with stubbed `gh`) and prune.
