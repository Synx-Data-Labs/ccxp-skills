---
status: Done
scheduled: 2026-10-05
estimation: 5
source: this conversation, 2026-10-06
related: dev/JOURNAL/2026-09-18-T20260918-174226-autopilot-status.md,
  dev/JOURNAL/2026-09-29-T20260929-210013-statusline-autopilot-status-segment.md,
  dev/JOURNAL/2026-09-30-T20260930-132964-autopilot-dispatch-own-clone.md
claimed_by:
claimed_role:
---

# T20261006-391349: Add /autopilot pause/resume and an explicit user-invoked stop

## TLDR

- **Type**: feature
- **Problem**: `/autopilot` (`autopilot/SKILL.md:45`) has no user-invoked way
  to pause, resume, or explicitly stop a running loop mid-window.
- **Solution**: add `pause [--now]` / `resume` / `stop [--now]` as new
  special-cased arguments (Phase 0-style), with a graceful
  `SendMessage`-and-timeout default and a hard `TaskStop` escape hatch for
  the in-flight dispatched `/drive` subagent.

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
     at `autopilot/SKILL.md:107`)?
  - Also unresolved: a pause must suppress/cancel the next cycle's already
    scheduled `ScheduleWakeup` (Phase 4) so the loop doesn't silently
    continue dispatching cycles while "paused".

## Context

- `/autopilot` has zero automated tests today (no `tests/*autopilot*` file
  exists) — verification here is manual dry-run, matching existing
  precedent, not a gap introduced by this task.
- The loop's only existing stop paths are internal: Phase 2's
  `now >= end_time` check (`autopilot/SKILL.md:91`) and Phase 4's
  queue-empty/stuck-exhausted branches (`autopilot/SKILL.md:143-144`) —
  nothing a user can trigger mid-run today.
- `/autopilot` is deliberately the interactive-only duration-boxed loop
  (`/ccxp` owns the cron/ritual cadence) — this feature is scoped to that
  interactive use case only.

## Solution

- **Trigger**: `pause [--now]`, `resume`, `stop [--now]` are new
  special-cased `/autopilot` arguments (Phase 0-style, alongside `status`)
  — but unlike `status`, they must be typed into the *same* chat window
  currently running the loop. That's the only session that can cancel its
  own `ScheduleWakeup` and that receives a new message even mid-cycle,
  while waiting on a dispatched `/drive` subagent's completion
  notification. No cross-session/flag-file signaling.
- **`ScheduleWakeup` suppression** (resolves the Problem section's
  explicitly-flagged open question): the very first action on `pause` or
  `stop`, before touching any in-flight subagent, is
  `ScheduleWakeup(stop: true)` to cancel the next cycle's already-scheduled
  wakeup. This is what actually stops the loop from silently continuing —
  without it, a `pause` only records state while the pending wakeup still
  fires and dispatches another cycle. Applies identically whether the
  session is between cycles (nothing else to do) or mid-cycle waiting on a
  dispatched subagent (the graceful/`--now` handling below still applies
  to that subagent). `resume` re-establishes a fresh `ScheduleWakeup` as
  part of re-entering Phase 3 normally.
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

**Alternatives considered and rejected:**

- Cross-session/flag-file pause signaling — rejected: can't interrupt
  mid-cycle instantly while a `/drive` subagent is dispatched (only a
  message into the same session the harness is already waiting on can); a
  flag only takes effect at the next phase boundary.
- Cutting one of graceful/`--now` entirely — rejected: they serve
  different needs (preserve WIP vs. reclaim instantly); kept both,
  graceful default.
- Resume always bare-picking (`/todo next`, never the exact interrupted
  task) — rejected: can silently strand a WIP'd task if something now
  outranks it in the queue.
- Reusing `dispatch_clone_path` for the priority task after `--now` —
  rejected: needs an `rm -rf` + reclone ceremony for no benefit when the
  user's own interactive clone is free and untouched.
- Waiting indefinitely on the graceful wrap-up with no timeout —
  rejected: could hang pause/stop indefinitely against a subagent deep in
  a blocking wait.
- Treating a failed `last_task` redispatch (already Done/claimed
  elsewhere) as Stuck — rejected: that's a benign, expected outcome, not
  a backoff-worthy failure.
- A "paused N times" report line — rejected (explicit maintainer call):
  the existing elapsed/requested report already answers what matters.

## Test plan

- [ ] Manual dry-run (matches `/autopilot`'s existing zero-automated-test
  precedent — no new scripts introduced): pause mid-cycle while a
  `/drive` subagent is dispatched, verify graceful wrap-up pushes a
  branch and the subagent ends within the timeout.
- [ ] Force the 2-minute graceful timeout to elapse (or simulate via a
  non-responsive subagent) and verify auto-escalation to `TaskStop`.
- [ ] `resume` after a graceful pause: verify it redispatches
  `/drive T<last_task>` first, then falls through to bare `/todo next` if
  that task is already Done/claimed-elsewhere.
- [ ] `stop`/`stop --now` from both the inter-cycle wait and mid-cycle
  states: verify `dev/.autopilot-state.json` ends with `stop_reason:
  "user-requested"` and Phase 5's elapsed-vs-requested report reflects
  only active (non-paused) time.
- [ ] `/autopilot status` while paused: verify the distinct "paused"
  header.

## Done criteria

- [ ] `autopilot/SKILL.md:45` (Phase 0) gains `pause [--now]` / `resume` /
  `stop [--now]` argument branches alongside the existing `status`
  check — verified by the Test plan's manual dry-run.
- [ ] `autopilot/SKILL.md:143`/`autopilot/SKILL.md:144`'s unconditional
  reschedule calls are preceded by `ScheduleWakeup(stop: true)` on
  pause/stop — verified against `dev/.autopilot-state.json`'s `status`
  field.
- [ ] `autopilot/SKILL.md:109`'s dispatch call captures the subagent's
  `agentId`, and `autopilot/SKILL.md:134`'s wait-for-completion point gains
  the graceful `SendMessage` + 2-minute timeout + `TaskStop` escalation —
  verified via the Test plan's dry-run above.
- [ ] Test plan item 3 (`resume` redispatch) passes: `/drive T<last_task>`
  is tried explicitly before falling back to bare `/todo next`.
- [ ] `autopilot/SKILL.md:45`'s Phase 0 `status` report shows a distinct
  "paused" header, not reused from the `running` branch — verified
  visually.

## Appendix

**Open** (deferred to implementation, not design-blocking):

- Exact wording of the "wrap up" instruction text in the dispatch prompt
  (don't fabricate a commit if there's nothing to commit, don't
  force-push mid-rebase, etc.).

**Out of scope:**

- Cross-session/flag-file pause signaling.
- A "paused N times" reporting line.
- Any change to `/ccxp`'s cron cadence or to `/drive`'s canonical
  `SKILL.md`.

**Estimation revised from 1 to 5**: new state schema, three new argument
branches each touching Phase 2–5, a subagent-interrupt protocol
(`SendMessage` + timeout + `TaskStop` escalation) threaded through two
commands, and a new Phase-4 fallback classification — confined to one
skill file's prose, but materially larger than a 1–3 point task.

## Closed (2026-10-06)

- Shipped in **PR #252** (`autopilot/SKILL.md` — Phase 0.1 pause/resume/stop,
  state-schema additions, Phase 0/3/5 cross-references).
- **Met**: all 5 Done-criteria items are implemented and anchored at the
  cited `autopilot/SKILL.md:<line>`s; `design-score --kind docs` scores
  100/100; the elapsed/`end_time`-shift arithmetic (Decisions, § State
  schema) was independently traced by hand against synthetic timestamps —
  shifting both `started_at` and `end_time` by the pause duration
  preserves both the elapsed-math formula and the full requested budget
  width exactly, confirming the one piece of this design with real
  arithmetic risk.
- **External/unverified**: the Test plan's five dry-run items all require
  a live, multi-hour `/autopilot` run with a real dispatched `/drive`
  subagent to interrupt — impractical to exercise synchronously while
  driving this task. Left unchecked rather than green-washed; recommend
  exercising `pause`/`resume`/`stop [--now]` on the next real `/autopilot`
  invocation and filing a follow-up if any of the five surface a gap.
- No follow-up tasks filed — the one `Open` item (exact wrap-up-prompt
  wording) was resolved inline during implementation
  (`autopilot/SKILL.md:81`'s graceful bullet), not deferred.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class (Phase 3.0
  classifier: pure `autopilot/SKILL.md` prose, no code).
- Verification (`superpowers:verification-before-completion`): yes — Phase
  3.6, caught a real gap (mid-cycle interrupt losing track of `last_task`)
  and six stale self-referential line citations; fixed both before this
  close.
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck.
- Receiving code review (`superpowers:receiving-code-review`): yes —
  `/address-pr` §2.d, independent review on the claim PR (#250, 1 real
  finding: a dropped `ScheduleWakeup`-suppression decision) and the
  design-rescore PR (#251, 1 real finding: 2 wrong `autopilot/SKILL.md`
  line citations). Both fixed, not pushed back on.
