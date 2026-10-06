---
status: In Progress — Design approved in-conversation 2026-10-06
scheduled: 2026-10-05
estimation: 5
source: this conversation, 2026-10-06
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
---

# T20261006-391349: Add /autopilot pause/resume and an explicit user-invoked stop

## Problem

- **Type**: feature
- `/autopilot` (`autopilot/SKILL.md`) only special-cases the `status` argument
  (Phase 0) — there is no user-invoked way to pause, resume, or explicitly
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

## Design

### Decisions

- **Trigger**: `pause [--now]`, `resume`, `stop [--now]` are new
  special-cased `/autopilot` arguments (Phase 0-style, alongside `status`)
  — but unlike `status`, they must be typed into the *same* chat window
  currently running the loop. That's the only session that can cancel its
  own `ScheduleWakeup` and that receives a new message even mid-cycle,
  while waiting on a dispatched `/drive` subagent's completion
  notification. No cross-session/flag-file signaling.
- **`--now` is symmetric** across `pause` and `stop`: forces an immediate
  `TaskStop` kill of any in-flight dispatched `/drive` subagent instead of
  asking it to wrap up.
- **Graceful default** (no `--now`): `SendMessage` the in-flight subagent
  (addressed by the `agentId` captured at Phase 3 dispatch) asking it to
  commit any uncommitted work to the current branch with a WIP-prefixed
  message, push it (no PR required), and end its turn. Reuses `/drive`
  Phase 6's existing "resume by finding the pushed branch" convention — no
  `/drive` skill changes needed, only an added line in `/autopilot`'s own
  self-contained dispatch prompt.
- **Timeout**: wait up to 2 minutes for the subagent to wrap up; if it
  hasn't, auto-escalate to a hard `TaskStop` kill (same as `--now`) —
  pause/stop must never hang indefinitely.
- **State schema** (`dev/.autopilot-state.json`): `status` gains
  `"paused"`; new `paused_at` field. At resume, **both** `started_at` and
  `end_time` are shifted forward by `now - paused_at` — not `end_time`
  alone. Phase 0/5's existing elapsed math (`last_cycle_at - started_at`)
  has no separate pause-duration bookkeeping to subtract, so `started_at`
  itself must move or paused time silently counts as elapsed; shifting it
  keeps that formula, and Phase 2's `now >= end_time` check, both correct
  across any number of pauses with no new report-side logic. `stuck_count`
  is untouched by pause/resume.
- **Clone handling**: pause/stop's hard-kill path never auto-cleans
  `dispatch_clone_path` — left exactly as today's existing
  "dirty/mid-rebase" fallback already handles it (cleaned up lazily on the
  next dispatch). The priority task is always worked from the user's own
  regular/interactive clone, never `dispatch_clone_path` — this is what
  makes the clone-identity/claim-reuse question moot rather than something
  to solve.
- **Resume** re-dispatches `/drive T<last_task>` explicitly (not bare) for
  the first cycle back. If that can't continue (already Done/merged, or
  claimed elsewhere in the interim), treat it as benign: fall straight
  through to a bare `/todo next` pick in the same cycle — not Stuck, no
  backoff.
- **New `stop_reason`**: `"user-requested"`, covering both an immediate
  `stop` and a pause that's never resumed.
- **Report format unchanged** — no new pause-stats line; the existing
  `<requested> requested, <elapsed> elapsed` math stays correct because
  `started_at` itself is shifted (see State schema above), not because the
  report gains new logic.
- **Idempotency**: pause-while-paused / resume-while-not-paused are plain
  no-ops — report the current state (e.g. "already paused since <time>")
  and do nothing further.
- **`/autopilot status` shows a distinct "paused" header** — not reused
  from the `running` branch — reporting elapsed-so-far, when it was
  paused, and the (already-shifted) remaining budget on resume.

### Open

- Exact wording of the "wrap up" instruction text in the dispatch prompt
  (don't fabricate a commit if there's nothing to commit, don't
  force-push mid-rebase, etc.) — left to implementation, not
  design-blocking.

### Out of scope

- Cross-session/flag-file pause signaling.
- A "paused N times" reporting line.
- Any change to `/ccxp`'s cron cadence or to `/drive`'s canonical
  `SKILL.md`.

### Test Plan

- Manual dry-run (matches autopilot's existing zero-automated-test
  precedent — no new scripts introduced): pause mid-cycle while a `/drive`
  subagent is dispatched, verify graceful wrap-up pushes a branch and the
  subagent ends within the timeout.
- Force the 2-minute graceful timeout to elapse (or simulate via a
  non-responsive subagent) and verify auto-escalation to `TaskStop`.
- `resume` after a graceful pause: verify it redispatches
  `/drive T<last_task>` first, then falls through to bare `/todo next` if
  that task is already Done/claimed-elsewhere.
- `stop`/`stop --now` from both the inter-cycle wait and mid-cycle states:
  verify `dev/.autopilot-state.json` ends with `stop_reason:
  "user-requested"` and Phase 5's elapsed-vs-requested report reflects
  only active (non-paused) time.
- `/autopilot status` while paused: verify the distinct "paused" header.

Estimation revised from 1 to 5: new state schema, three new argument
branches each touching Phase 2–5, a subagent-interrupt protocol
(`SendMessage` + timeout + `TaskStop` escalation) threaded through two
commands, and a new Phase-4 fallback classification — confined to one
skill file's prose, but materially larger than a 1–3 point task.
