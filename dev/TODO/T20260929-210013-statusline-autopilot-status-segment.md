---
status: Open
estimation: 1h
source: this conversation, 2026-09-29
related: T20260924-366770
---

# T20260929-210013: Add optional autopilot status segment to the statusline

## Problem

- **Type**: feature
- `statusline-command.sh` (`statusline-setup/scripts/statusline-command.sh:106-120`)
  builds `ctx_part`/`branch_part`/`task_part` but has no visibility into
  whether `/autopilot` is running in this clone — a user watching the
  terminal has no glanceable signal that a multi-hour unattended run is
  active, how far into its window it is, or how it's going.
- `/autopilot` already maintains `dev/.autopilot-state.json`
  (`autopilot/SKILL.md` § State file) per clone, with `started_at`,
  `end_time`, `stuck_count`, `cycle_count` — cheap to read, no extra
  git/gh calls needed.
- Requested format: an optional `ap: 1/5hr 3/10` segment, inserted
  **before** the existing `ctx:` segment, only present when
  `dev/.autopilot-state.json` exists and `status: "running"`:
  - `1/5hr` — hours elapsed / hours requested, from `started_at`/`end_time`
    (elapsed = `now - started_at`; requested = `end_time - started_at`).
  - `3/10` — `stuck_count` / `cycle_count` verbatim from the state file.
    (Confirmed with the user: `stuck_count` for the "needs attention"
    number rather than the richer, git/gh-derived "Needs your attention"
    list `autopilot/SKILL.md` Phase 0/5 compute — that list is too
    expensive to recompute on every statusline render. `cycle_count` for
    the total, matching "already gone through N tasks" directly.)
- Done looks like: `sl-join` (`statusline-setup/scripts/statusline-command.sh:84-91`)
  emits `ap: ... | ctx: ... | branch: ... | TASK: ...` when autopilot is
  running in this clone, and omits the `ap:` segment entirely (falling
  back to today's output) when `dev/.autopilot-state.json` is absent or
  `status: "stopped"`.

## Context

- `tests/statusline_setup.bats` already covers `statusline-command.sh`'s
  existing segments — extend it with cases for autopilot running /
  stopped / absent-state-file.
- `dev/.autopilot-state.json` is gitignored and per-clone, same as the
  claim/session state this script already reads (`sl-claimed-task-label`,
  `statusline-setup/scripts/statusline-command.sh:60-80`) — no new
  cross-clone concerns.
