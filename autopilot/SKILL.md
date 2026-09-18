---
name: autopilot
description: Use when the user explicitly asks to keep working tasks unattended for a set duration — e.g. "/autopilot for the next 6 hours" or "/autopilot 6h"
disable-model-invocation: false
argument-hint: "<duration> | status"
---

Keep calling bare `/drive` back-to-back until at least `<duration>` has elapsed, using `ScheduleWakeup` to survive the whole span without staying in one long-running turn. No standup/IPM/retro rituals — that's `/ccxp`'s job. This skill owns only the duration/loop/stop bookkeeping; task selection, claiming, implementing, PR babysitting, and merging are entirely `/drive`'s.

## Argument

- `<duration>` — free text, read directly rather than parsed by a script: `6h`, `90m`, `for the next 6 hours`, etc. Compute an absolute end-time from it (see Phase 1) — never re-derive "N hours from now" on a later wake, or the window drifts later every cycle.
- `status` — exact match, case-insensitive, no other text. Read-only report of the current/last run; see Phase 0. Does not start or continue the loop.

## State file

`dev/.autopilot-state.json` (gitignored) — written by this skill only, at the phase transitions below. It exists purely so a run's status survives a `/clear` (the resume-prompt contract in Phase 1 stays the loop's real, authoritative control values — this file is additive, never load-bearing for the loop itself). Fields:

```json
{
  "status": "running|stopped",
  "started_at": "2026-09-17T14:30:00Z", "end_time": "2026-09-17T20:30:00Z",
  "stuck_count": 0, "cycle_count": 0,
  "last_cycle_at": null, "last_outcome": null,
  "last_task": null, "last_stuck_reason": null,
  "stop_reason": null
}
```

`last_task` is `{"id": "T...", "slug": "..."}` or `null`. Everything else this skill might want to report (which tasks merged, which PRs are still open) is **not** stored here — Phase 0 derives it live from `dev/TODO/`, `dev/JOURNAL/`, and `gh`, since those are the actual source of truth and a cached copy here would drift.

### Phase 0: Status (read-only)

If the argument is exactly `status` (case-insensitive, nothing else): read `dev/.autopilot-state.json`.

- **Missing file**: report "autopilot has never run in this repo" and stop. No further phases.
- **Present**: build the same bullet-list template as Phase 5, filled in as follows, and report it to the user. Do not post to Slack, do not call `ScheduleWakeup` — this phase never touches the loop.
  - Header line: `running` → `<requested-vs-elapsed>, ends <end_time>` from `started_at`/`end_time`; `stopped` → `<requested> requested, <elapsed> elapsed — stopped: <stop_reason>`.
  - **Done**: `git log --since=<started_at> --diff-filter=A --name-only -- dev/JOURNAL/` to find task files journaled since this run started; for each, read its frontmatter for the `(<repo>#<num>)` PR ref to fill the bullet. Empty → "No tasks merged this run" (or "yet" if `status: running`).
  - **Needs your attention**: scan `dev/TODO/*.md` for `status: Review` with a PR ref in the title → `gh pr view <n>` for each to report open/CI/review state; scan for `status: Blocked by T{id}`. If `stuck_count > 0`, add a bullet from `last_task`/`last_stuck_reason` (same wording as Phase 5's Stuck bullet). Empty → "Nothing outstanding".

### Phase 1: Establish the end-time

- **Resumed invocation**: the prompt matches `/autopilot until <ISO-8601 timestamp> stuck=<n>` *exactly* (e.g. `/autopilot until 2026-09-17T20:30:00Z stuck=2`) — a strict format check on the timestamp, not a loose match on the word "until". Reuse `end_time` and `stuck_count = <n>` verbatim. The running summary tally does not survive a resume in the prompt text — reconstruct what you can for the final report from this conversation's history, but don't block the loop on it; the loop's correctness depends only on `end_time` and `stuck_count`, both of which ARE threaded through every resume, never on the tally.
- **First invocation** (anything else, including free text that happens to contain the word "until" — e.g. `/autopilot until 5pm` — since it doesn't match the strict resume format above): treat the whole argument as `<duration>` and compute `end_time = now + <duration>` (ISO 8601, e.g. `2026-09-17T20:30:00Z`). Initialize `stuck_count = 0` and start a running tally of the summary this run will report at Phase 5 (cycles run, tasks merged, time spent backing off). Write a fresh `dev/.autopilot-state.json` (see § State file): `status: running`, `started_at: now`, `end_time`, `stuck_count: 0`, `cycle_count: 0`, `last_cycle_at/last_outcome/last_task/last_stuck_reason/stop_reason: null` — this overwrites any stale file left by a previous, already-stopped run.

### Phase 2: Stop check

If `now >= end_time`: go to Phase 5 with stop reason `elapsed`.

### Phase 3: Run one cycle

Invoke `/drive` with no argument (bare auto-pick). Let it run to completion — it owns `/todo sweep`, `/todo next`, claiming, implementation, PR, CI, merge, and recursing into blockers on its own.

### Phase 4: Classify the outcome and reschedule

- **Progress** — none of the four Stuck conditions below fired this cycle, **and** either `/drive` merged something or the cycle ended in a wait state that resolves **without further `/drive` action** (CI still running, a review genuinely still pending) — the all-four-clear condition gates the whole bucket, not just the wait-state case, since a multi-task cycle can merge one task via blocker recursion and still hit a Stuck condition on another before returning: reset `stuck_count = 0`. Update the state file: `stuck_count: 0`, `cycle_count += 1`, `last_cycle_at: now`, `last_outcome: "progress"`, `last_task`/`last_stuck_reason: null`. Then `ScheduleWakeup(delaySeconds: 60, prompt: "/autopilot until <end_time> stuck=0", noop: false, reason: "continuing autopilot — last /drive cycle made progress")`. Done with this turn.
- **Empty queue / nothing actionable** — `/drive` reports no free, unblocked, ungated task exists: update the state file (`cycle_count += 1`, `last_cycle_at: now`, `last_outcome: "queue-empty"`), then go to Phase 5 with stop reason `queue-empty`. Don't reschedule — there is nothing a further wake would change.
- **Stuck** — any of the following, regardless of whether an intermediate commit exists (a commit alone is not advancement — only a merge, or a genuinely self-resolving wait, counts as Progress): `/drive` errored; returned having neither merged anything nor advanced any task's state; stopped via its own Escalation Rules (`drive/SKILL.md`'s table — sent a Slack notification and stopped, e.g. repeated test/CI failure, missing credentials); **or `/drive`'s delegated `/address-pr` call stopped-and-reported without merging** (its §2.f safety valve — 5 full iterations, or a fix that introduces new failures — an unresolvable rebase conflict in §2.b, or an unverifiable manual test-plan item in §2.e — none of these route through `drive/SKILL.md`'s Escalation Rules table or post their own Slack message, so this is the one Stuck case with no notification of its own until Phase 5). On any of these: `stuck_count += 1`, `delay = min(300 * 2^(stuck_count - 1), 1800)` seconds (5m → 10m → 20m → 30m, capped). Update the state file: `stuck_count`, `cycle_count += 1`, `last_cycle_at: now`, `last_outcome: "stuck"`, `last_task` (the task this cycle was working, or `null` if `/drive` errored before selecting one), `last_stuck_reason` (a short phrase — which of the conditions above fired). If `now + delay >= end_time`: go to Phase 5 with stop reason `elapsed` (don't schedule a wake past the window's own end). Otherwise `ScheduleWakeup(delaySeconds: delay, prompt: "/autopilot until <end_time> stuck=<stuck_count>", noop: true, reason: "backing off after a stuck /drive cycle (stuck_count=<n>)")`. Done with this turn.

### Phase 5: Stop

Build one report, in this exact bullet-list template — never a prose paragraph — and use it verbatim for both the Slack post and the in-chat report below: a wall-of-text summary is a bug, not a style choice.

```
Autopilot run: <requested> requested, <elapsed> elapsed — stopped: <reason>

Done:
- Merged T<id> (<slug>) — PR #<n>
(one bullet per merged task this run; "- No tasks merged this run" if none)

Needs your attention:
- PR #<n> (T<id>, <slug>) still open — <specific status>, pick up via /address-pr <n>
- Stuck after <k> consecutive backoff cycles (most recently on T<id>, <slug> — or "no task identified" if /drive errored before selecting one) — <reason>, still backing off when the window closed
(one bullet per item left mid-flight; "- Nothing outstanding" if there is truly nothing left)
```

1. **Every `T<id>` or `PR #<n>` reference carries a short slug** — a few words on what it's actually about (task title or a one-line gist), not the bare id — so the report is scannable without looking anything up. Best-effort from this conversation's history; if a slug genuinely can't be recovered (e.g. after a resume with no surviving context), fall back to the bare id rather than guessing.
2. **Done** lists only what actually merged this run. **Needs your attention** lists everything left mid-flight at stop time — an open PR with unresolved CI/review, a Stuck task still mid-backoff when `elapsed` fired, or (for the `queue-empty` stop reason) nothing at all if the queue is genuinely clear. The tally isn't guaranteed to survive a `ScheduleWakeup` resume — reconstruct what you can from this conversation's history, but don't claim precision it can't back up.
3. Update the state file (see § State file): `status: "stopped"`, `stop_reason: <reason>`. Leave `stuck_count`/`cycle_count`/`last_*` at whatever Phase 4 (or the `queue-empty` branch) last set — this is what makes the report reconstructible by a later `/autopilot status` even after this conversation is gone.
4. Post the report to `/slack` (no `--channel` — the default automation-alerts channel is exactly for this).
5. Report the same template, filled in the same way, to the user in this turn's response.

## Important Notes

- **Never loop within a single turn.** Each `/drive` cycle is exactly one `ScheduleWakeup` boundary — this is what lets a multi-hour `/autopilot` survive context compaction and interruptions cleanly, the same way `/loop`'s dynamic mode does.
- **Stuck backoff is silent — from `/autopilot`'s side.** `/autopilot` itself only posts to Slack once, at the final Phase 5 stop — a backing-off cycle just reschedules quietly (`noop: true`) and moves on. A Stuck cycle folded in from `/drive`'s own Escalation Rules may already have sent its own Slack message before `/autopilot` ever classified the outcome; that's `/drive`'s notification, not a repeat autopilot post, and it can recur once per backoff retry for as long as the underlying escalation cause persists. The `/address-pr`-delegated Stuck case (safety valve, unresolvable conflict, unverifiable item) posts **no** notification of its own — it's silent through every backoff retry it causes, with no way out but the window elapsing (this path never produces the `queue-empty` reason, only `elapsed`), so the only visibility is this skill's own Phase 5 summary once that happens.
- **Queue-empty is a stop, not a backoff case.** If there is genuinely nothing actionable, waking up again on a timer won't change that; only a future `/stage`/`/todo sweep` adding new work would, and the user can just re-run `/autopilot` then.
- **This does not replace `/ccxp`.** `/ccxp` is the full ritual-aware orchestrator (standup, IPM, retro) meant for the daily/weekly cron cadence; `/autopilot` is a plain duration-boxed `/drive` loop for an interactive "go work for N hours" ask.
- **One active run per repo, best-effort.** The state file assumes a single `/autopilot` loop per repo — there's no lock. Running two concurrently in the same repo will have the second's writes clobber the first's; not guarded against, same as the rest of this skill's concurrency posture today.

## Cross-references

- `/drive` — does all the actual task-selection/implementation/merge work, once per cycle
- `/ccxp` — the full ritual-aware orchestrator this skill deliberately does not replace
- `/slack` — posts the stop summary
- `superpowers` `ScheduleWakeup` — the resume mechanism between cycles
- `dev/.autopilot-state.json` — this skill's own gitignored state file (§ State file), read by Phase 0's `status` report
