---
name: autopilot
description: Use when the user explicitly asks to keep working tasks unattended for a set duration — e.g. "/autopilot for the next 6 hours" or "/autopilot 6h"
disable-model-invocation: false
argument-hint: "<duration>"
---

Keep calling bare `/drive` back-to-back until at least `<duration>` has elapsed, using `ScheduleWakeup` to survive the whole span without staying in one long-running turn. No standup/IPM/retro rituals — that's `/ccxp`'s job. This skill owns only the duration/loop/stop bookkeeping; task selection, claiming, implementing, PR babysitting, and merging are entirely `/drive`'s.

## Argument

`<duration>` — free text, read directly rather than parsed by a script: `6h`, `90m`, `for the next 6 hours`, etc. Compute an absolute end-time from it (see Phase 1) — never re-derive "N hours from now" on a later wake, or the window drifts later every cycle.

## Workflow

### Phase 1: Establish the end-time

- **First invocation** (the prompt is the user's original `<duration>` text, not a `... until <timestamp>` resume): compute `end_time = now + <duration>` (ISO 8601, e.g. `2026-09-17T20:30:00Z`). Also initialize `stuck_count = 0` and start a running tally of the summary this run will report at Phase 5 (cycles run, tasks merged, time spent backing off).
- **Resumed invocation** (the prompt reads `/autopilot until <end_time>`): reuse that `end_time` verbatim. `stuck_count` and the running tally do not survive a resume in the prompt text itself — reconstruct what you can for the final summary from what actually happened in this conversation, but don't block the loop on it; the loop's correctness never depends on the tally.

### Phase 2: Stop check

If `now >= end_time`: go to Phase 5 with stop reason `elapsed`.

### Phase 3: Run one cycle

Invoke `/drive` with no argument (bare auto-pick). Let it run to completion — it owns `/todo sweep`, `/todo next`, claiming, implementation, PR, CI, merge, and recursing into blockers on its own.

### Phase 4: Classify the outcome and reschedule

- **Progress** — `/drive` merged something, or left a task in a normal transient wait state (e.g. PR open, CI running, awaiting review): reset `stuck_count = 0`, then `ScheduleWakeup(delaySeconds: 60, prompt: "/autopilot until <end_time>", noop: false, reason: "continuing autopilot — last /drive cycle made progress")`. Done with this turn.
- **Empty queue / nothing actionable** — `/drive` reports no free, unblocked, ungated task exists: go to Phase 5 with stop reason `queue-empty`. Don't reschedule — there is nothing a further wake would change.
- **Stuck** — `/drive` errored, or returned having neither merged anything nor advanced any task's state (the same task it started with is still sitting in the same status with no new commit/PR): `stuck_count += 1`, `delay = min(300 * 2^(stuck_count - 1), 1800)` seconds (5m → 10m → 20m → 30m, capped). If `now + delay >= end_time`: go to Phase 5 with stop reason `elapsed` (don't schedule a wake past the window's own end). Otherwise `ScheduleWakeup(delaySeconds: delay, prompt: "/autopilot until <end_time>", noop: true, reason: "backing off after a stuck /drive cycle (stuck_count=<n>)")`. Done with this turn.

### Phase 5: Stop

1. Build a short summary: requested duration vs. actually elapsed, number of `/drive` cycles run, tasks merged (ids + titles, if known this turn), and the stop reason (`elapsed` or `queue-empty`).
2. Post that summary to `/slack` (no `--channel` — the default automation-alerts channel is exactly for this).
3. Report the same summary to the user in this turn's response.

## Important Notes

- **Never loop within a single turn.** Each `/drive` cycle is exactly one `ScheduleWakeup` boundary — this is what lets a multi-hour `/autopilot` survive context compaction and interruptions cleanly, the same way `/loop`'s dynamic mode does.
- **Stuck backoff is silent.** Only the final Phase 5 stop posts to Slack — a backing-off cycle just reschedules quietly (`noop: true`) and moves on.
- **Queue-empty is a stop, not a backoff case.** If there is genuinely nothing actionable, waking up again on a timer won't change that; only a future `/stage`/`/todo sweep` adding new work would, and the user can just re-run `/autopilot` then.
- **This does not replace `/ccxp`.** `/ccxp` is the full ritual-aware orchestrator (standup, IPM, retro) meant for the daily/weekly cron cadence; `/autopilot` is a plain duration-boxed `/drive` loop for an interactive "go work for N hours" ask.

## Cross-references

- `/drive` — does all the actual task-selection/implementation/merge work, once per cycle
- `/ccxp` — the full ritual-aware orchestrator this skill deliberately does not replace
- `/slack` — posts the stop summary
- `superpowers` `ScheduleWakeup` — the resume mechanism between cycles
