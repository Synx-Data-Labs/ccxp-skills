---
status: Open
estimation: 1
source: this conversation, 2026-10-06
---

# T20261006-391349: Add /autopilot pause/resume and an explicit user-invoked stop

## Problem

- **Type**: feature
- `/autopilot` (`autopilot/SKILL.md`) only special-cases the `status` argument
  (Phase 1) — there is no user-invoked way to pause, resume, or explicitly
  stop a running loop mid-window. Today a run only ends itself, via Phase 2
  (`elapsed`) or Phase 4 (`queue-empty`/exhausted stuck backoff).
- Need: when a higher-priority task shows up mid-run, pause the loop so its
  duration bookkeeping (`started_at`/`end_time` in
  `dev/.autopilot-state.json`) freezes for the paused span, work the
  priority task, then resume and continue counting from where it left off.
- Need: an explicit `stop` that ends the run immediately on request. Note
  Phase 5's report (`<requested> requested, <elapsed> elapsed — stopped:
  <reason>`) already computes actual-vs-requested elapsed correctly for the
  existing stop paths — what's missing is a user-invoked stop *reason* and
  trigger, not the reporting math itself.
- Open design question (surfaced by the user, not yet resolved) — what
  happens to the in-flight dispatched `/drive` subagent (Phase 3) when a
  pause/stop lands mid-cycle:
  1. **Graceful**: have the dispatched `/drive` WIP-commit and push
     everything it's working on to the remote branch, and have `/autopilot`
     remember the last task (`last_task` already exists in state) so a
     resume picks the same task back up.
  2. **`--now`**: kill the dispatched subagent immediately, no cleanup.
     Open sub-question the user flagged themselves: if killed hard, how do
     you still use the same dispatch clone (`dispatch_clone_path`) to work
     the priority task, given `/drive`'s claimant identity is hashed from
     that clone's own toplevel path (`_session/claimant-id.sh`, referenced
     at `autopilot/SKILL.md:70`)?
  - Also unresolved: a pause must suppress/cancel the next cycle's already
    scheduled `ScheduleWakeup` (Phase 4) so the loop doesn't silently
    continue dispatching cycles while "paused".
