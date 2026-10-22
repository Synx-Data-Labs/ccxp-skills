---
status: In Progress
estimation: 1
source: conversation 2026-10-14 (user: "i like /epic, we can add command like drive|status|refresh")
related: [T20261012-333879]
description: New /epic skill — status, refresh, and a sequential epic-driven /drive loop
claimed_by: cc1-50ac6891:e68b46eab14758b1
claimed_role: interactive
scheduled: 2026-10-12
---

# T20261014-144630: /epic skill (status | refresh | drive)

## Problem

- **Type**: feature
- Epics (`dev/EPICS/E<n>-*.md`) are read-only to the tooling; nothing drives an epic's member tasks, and `queue.md` order ignores epic membership.
- Done looks like: `/epic status|refresh|drive` ships with a tested script, passes the skill-quality gate, and is indexed in `README.md`.

## Design

- `drive <E<n>>`: members in epic-file order; skip-and-record done / peer-claimed / `Blocked by` open / SUPERVISED; plain (other-repo) members listed as not driveable.
- One fresh sub-agent per task runs `/drive <TID>`; failures are summarized and the loop moves on; final report orders leftovers by deadline, then `queue.md` position.
- `refresh`: `epic-links.sh sync` + `lint`, report moved/plain members, propose (never auto-add) related `dev/TODO` candidates.
- `status`: read-only member table plus `epic-status.sh render`.
- Deterministic parts in `epic/scripts/epic.sh` (`tests/epic.bats`); loop and judgment stay in `epic/SKILL.md`.
- Model-invocable like every skill; the description wording ("explicitly asks") restricts it.

## Done criteria

- [x] `epic/SKILL.md`, `epic/scripts/epic.sh`, `tests/epic.bats`, baseline score recorded.
- [x] README index, `_taskid/README.md`, `/ccxp` pointer updated.
- [ ] PR merged; one real `/epic drive` dry run on a small epic observed.
