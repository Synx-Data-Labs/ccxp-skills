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

- **Resumed invocation**: the prompt matches `/autopilot until <ISO-8601 timestamp> stuck=<n>` *exactly* (e.g. `/autopilot until 2026-09-17T20:30:00Z stuck=2`) — a strict format check on the timestamp, not a loose match on the word "until". Reuse `end_time` and `stuck_count = <n>` verbatim. The running summary tally does not survive a resume in the prompt text — reconstruct what you can for the final report from this conversation's history, but don't block the loop on it; the loop's correctness depends only on `end_time` and `stuck_count`, both of which ARE threaded through every resume, never on the tally.
- **First invocation** (anything else, including free text that happens to contain the word "until" — e.g. `/autopilot until 5pm` — since it doesn't match the strict resume format above): treat the whole argument as `<duration>` and compute `end_time = now + <duration>` (ISO 8601, e.g. `2026-09-17T20:30:00Z`). Initialize `stuck_count = 0` and start a running tally of the summary this run will report at Phase 5 (cycles run, tasks merged, time spent backing off).

### Phase 2: Stop check

If `now >= end_time`: go to Phase 5 with stop reason `elapsed`.

### Phase 3: Run one cycle

Invoke `/drive` with no argument (bare auto-pick). Let it run to completion — it owns `/todo sweep`, `/todo next`, claiming, implementation, PR, CI, merge, and recursing into blockers on its own.

### Phase 4: Classify the outcome and reschedule

- **Progress** — none of the four Stuck conditions below fired this cycle, **and** either `/drive` merged something or the cycle ended in a wait state that resolves **without further `/drive` action** (CI still running, a review genuinely still pending) — the all-four-clear condition gates the whole bucket, not just the wait-state case, since a multi-task cycle can merge one task via blocker recursion and still hit a Stuck condition on another before returning: reset `stuck_count = 0`, then `ScheduleWakeup(delaySeconds: 60, prompt: "/autopilot until <end_time> stuck=0", noop: false, reason: "continuing autopilot — last /drive cycle made progress")`. Done with this turn.
- **Empty queue / nothing actionable** — `/drive` reports no free, unblocked, ungated task exists: go to Phase 5 with stop reason `queue-empty`. Don't reschedule — there is nothing a further wake would change.
- **Stuck** — any of the following, regardless of whether an intermediate commit exists (a commit alone is not advancement — only a merge, or a genuinely self-resolving wait, counts as Progress): `/drive` errored; returned having neither merged anything nor advanced any task's state; stopped via its own Escalation Rules (`drive/SKILL.md`'s table — sent a Slack notification and stopped, e.g. repeated test/CI failure, missing credentials); **or `/drive`'s delegated `/address-pr` call stopped-and-reported without merging** (its §2.f safety valve — 5 full iterations, or a fix that introduces new failures — an unresolvable rebase conflict in §2.b, or an unverifiable manual test-plan item in §2.e — none of these route through `drive/SKILL.md`'s Escalation Rules table or post their own Slack message, so this is the one Stuck case with no notification of its own until Phase 5). On any of these: `stuck_count += 1`, `delay = min(300 * 2^(stuck_count - 1), 1800)` seconds (5m → 10m → 20m → 30m, capped). If `now + delay >= end_time`: go to Phase 5 with stop reason `elapsed` (don't schedule a wake past the window's own end). Otherwise `ScheduleWakeup(delaySeconds: delay, prompt: "/autopilot until <end_time> stuck=<stuck_count>", noop: true, reason: "backing off after a stuck /drive cycle (stuck_count=<n>)")`. Done with this turn.

### Phase 5: Stop

1. Build a short summary: requested duration vs. actually elapsed, and the stop reason (`elapsed` or `queue-empty`). Add `/drive` cycles run and tasks merged (ids + titles) as best-effort from this conversation's history — the tally isn't guaranteed to survive a resume, so don't claim precision it can't back up.
2. Post that summary to `/slack` (no `--channel` — the default automation-alerts channel is exactly for this).
3. Report the same summary to the user in this turn's response.

## Important Notes

- **Never loop within a single turn.** Each `/drive` cycle is exactly one `ScheduleWakeup` boundary — this is what lets a multi-hour `/autopilot` survive context compaction and interruptions cleanly, the same way `/loop`'s dynamic mode does.
- **Stuck backoff is silent — from `/autopilot`'s side.** `/autopilot` itself only posts to Slack once, at the final Phase 5 stop — a backing-off cycle just reschedules quietly (`noop: true`) and moves on. A Stuck cycle folded in from `/drive`'s own Escalation Rules may already have sent its own Slack message before `/autopilot` ever classified the outcome; that's `/drive`'s notification, not a repeat autopilot post, and it can recur once per backoff retry for as long as the underlying escalation cause persists. The `/address-pr`-delegated Stuck case (safety valve, unresolvable conflict, unverifiable item) posts **no** notification of its own — it's silent through every backoff retry it causes, with no way out but the window elapsing (this path never produces the `queue-empty` reason, only `elapsed`), so the only visibility is this skill's own Phase 5 summary once that happens.
- **Queue-empty is a stop, not a backoff case.** If there is genuinely nothing actionable, waking up again on a timer won't change that; only a future `/stage`/`/todo sweep` adding new work would, and the user can just re-run `/autopilot` then.
- **This does not replace `/ccxp`.** `/ccxp` is the full ritual-aware orchestrator (standup, IPM, retro) meant for the daily/weekly cron cadence; `/autopilot` is a plain duration-boxed `/drive` loop for an interactive "go work for N hours" ask.

## Cross-references

- `/drive` — does all the actual task-selection/implementation/merge work, once per cycle
- `/ccxp` — the full ritual-aware orchestrator this skill deliberately does not replace
- `/slack` — posts the stop summary
- `superpowers` `ScheduleWakeup` — the resume mechanism between cycles
