---
name: autopilot
description: Use when the user explicitly asks to keep working tasks unattended for a set duration — e.g. "/autopilot for the next 6 hours" or "/autopilot 6h"
disable-model-invocation: false
argument-hint: "<duration> | status"
---

Keep dispatching bare `/drive` cycles back-to-back until at least `<duration>` has elapsed, using `ScheduleWakeup` to survive the whole span without staying in one long-running turn. No standup/IPM/retro rituals — that's `/ccxp`'s job. This skill owns only the duration/loop/stop bookkeeping; task selection, claiming, implementing, PR babysitting, and merging are entirely `/drive`'s. Each cycle's `/drive` run happens in a dispatched sub-agent, not inline (see Phase 3) — this skill's own context only ever grows by one compact report per cycle, which is what actually lets a multi-hour run stay small; automatic compaction is a backstop, not the mechanism.

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

## Workflow

### Phase 0: Status (read-only)

If the argument is exactly `status` (case-insensitive, nothing else): read `dev/.autopilot-state.json`.

- **Missing file**: report "autopilot has never run in this repo" and stop. No further phases.
- **Present**: reuse Phase 5's Done/Needs-your-attention bullet formats (its header line is `stopped`-specific — Phase 0 has its own, below) and report it to the user. Do not post to Slack, do not call `ScheduleWakeup` — this phase never touches the loop.
  - Header line: `running` → `<requested-vs-elapsed>, ends <end_time>` from `started_at`/`end_time` (elapsed computed against `now`); `stopped` → `<requested> requested, <elapsed> elapsed — stopped: <stop_reason>` (elapsed computed as `last_cycle_at − started_at` — there is no separate stop timestamp, and `last_cycle_at` is the closest proxy to when the run actually stopped, or `0` if `last_cycle_at` is still `null` because the window elapsed before any cycle ran; `now − started_at` would overstate elapsed by however long ago the run ended).
  - **Done**: `git log --since=<started_at> --diff-filter=A --name-only -- dev/JOURNAL/` to find task files journaled since this run started; for each, read its frontmatter for the `(<repo>#<num>)` PR ref to fill the bullet. Empty → "No tasks merged this run" (or "yet" if `status: running`).
  - **Needs your attention**: apply the **Needs-your-attention filter** (see Important Notes) — in practice this means: skip `status: Blocked by T{id}` entirely (that's a dependency chain, `/drive` Phase 6 recurses into it on its own) and skip any `status: Review` PR that's merely open with routine CI/review/rebase work left (the next cycle's Phase 0 `/address-pr` drains it automatically). Only list a PR here if it's already stuck in a way no skill can resolve unattended — check the task's own `status:` line for a human-only marker (`SUPERVISED`, "needs a human", "needs manual", an external/live-environment spot-check, a maintainer sign-off) — and confirm via `gh pr view <n>` if a PR ref is present. If `last_outcome == "stuck"` (not merely `stuck_count > 0`, which can be stale — see Phase 4's `queue-empty` branch), add a bullet from `last_task`/`last_stuck_reason` — Phase 5's exact wording ("...still backing off when the window closed") only when `status == "stopped"`; if `status == "running"` (still mid-backoff, not yet re-woken), swap the trailing clause for "...currently backing off" instead, since the window hasn't closed. Empty → "Nothing outstanding".

### Phase 1: Establish the end-time

- **Resumed invocation**: the prompt matches `/autopilot until <ISO-8601 timestamp> stuck=<n>` *exactly* (e.g. `/autopilot until 2026-09-17T20:30:00Z stuck=2`) — a strict format check on the timestamp, not a loose match on the word "until". Reuse `end_time` and `stuck_count = <n>` verbatim. The running summary tally does not survive a resume in the prompt text — reconstruct what you can for the final report from this conversation's history, but don't block the loop on it; the loop's correctness depends only on `end_time` and `stuck_count`, both of which ARE threaded through every resume, never on the tally.
- **First invocation** (anything else, including free text that happens to contain the word "until" — e.g. `/autopilot until 5pm` — since it doesn't match the strict resume format above): treat the whole argument as `<duration>` and compute `end_time = now + <duration>` (ISO 8601, e.g. `2026-09-17T20:30:00Z`). Initialize `stuck_count = 0` and start a running tally of the summary this run will report at Phase 5 (cycles run, tasks merged, time spent backing off). Write a fresh `dev/.autopilot-state.json` (see § State file): `status: running`, `started_at: now`, `end_time`, `stuck_count: 0`, `cycle_count: 0`, `last_cycle_at/last_outcome/last_task/last_stuck_reason/stop_reason: null` — this overwrites any stale file left by a previous, already-stopped run.

### Phase 2: Stop check

If `now >= end_time`: go to Phase 5 with stop reason `elapsed`.

### Phase 3: Run one cycle

Dispatch `/drive` (bare auto-pick) via the `Agent` tool instead of invoking it inline — `subagent_type: general-purpose` (needs `/drive`'s full tool surface: git, `gh`, Bash, Edit, Skill), **deliberately no `isolation`**, unlike `/drive`'s own `--dispatch-blockers` mode which uses `isolation: "worktree"`. This is not an oversight — a worktree is actively wrong here: `_session/claimant-id.sh` hashes `git rev-parse --show-toplevel` (the clone path) into the task-claim identity, and a `git worktree` has its own distinct toplevel path. `--dispatch-blockers` gets away with that because it's a single one-off call inside one `/drive` invocation — B's claim only has to succeed once. `/autopilot` dispatches repeatedly, cycle after cycle; giving each cycle a different worktree would give each cycle a *different claimant identity*, breaking the "same clone = same claimant, self-releases its own prior claim" assumption the whole anti-steal system depends on (`_session/task_claim.sh`) — an accumulating-orphaned-claims bug across a long run, not a hypothetical. Plain no-isolation dispatch keeps every cycle's claimant identity pinned to this one clone's path, exactly like the inline behavior it replaces. The wait-state this creates (idle between dispatch and notification, same clone) is no different from the pre-existing hazard of anything else touching this clone while `/drive` runs inline — unchanged by this PR either way, and Phase 0's `status` path is read-only (`git log`, `gh pr view` — no checkout) so it isn't a collision case. Keeping a full `/drive` cycle's internal work (git diffs, CI polling, review iterations, journal writes) out of `/autopilot`'s own context is what bounds a multi-hour run's context growth — there is no `/clear`/`/compact` this skill can trigger itself (neither is exposed as a tool; `/compact` also already runs automatically as a harness-level backstop regardless), so dispatch is the only mechanism actually available to it. This still mirrors `--dispatch-blockers`'s core pattern (`drive/SKILL.md` "Recurse into B", T20260719-204917) — Agent-tool dispatch, compact report only — just without the isolation flag, for the reason above.

The dispatch prompt must be self-contained — the sub-agent has no memory of this conversation. State plainly: this is `/autopilot` invoking `/drive` for its next unattended cycle (bare, auto-pick — no specific task), name the repo/working directory, and require the agent to run `/drive` to completion. Don't just hand it the report template below — the sub-agent is the one directly observing `/drive`'s outcome, so it needs Phase 4's actual classification criteria to self-report accurately, not just a shape to fill in: give it a condensed restatement of what Stuck means (`/drive` errored; returned having neither merged anything nor advanced any task's state — **a commit alone is not advancement; only a merge, or a genuinely self-resolving wait, counts as Progress**; stopped via its own Escalation Rules; or its delegated `/address-pr` call stopped-and-reported without merging — Phase 4's Stuck bullet, verbatim in brief, qualifier included) alongside the format, so it can tell "no advancement" apart from a genuine `WAITING` state itself rather than guessing which section applies. End its final message in exactly this format, so Phase 4 can classify mechanically without reading the sub-agent's full transcript:

```
MERGED: T<id> (<slug>) — PR #<n>
(one line per task merged this cycle, including via blocker recursion; omit the whole section if none)

STUCK: <short reason> — last task T<id> (<slug>) [or "no task identified" if /drive errored before selecting one]
(only if /drive stopped without merging or hit one of its own Escalation Rules — see Phase 4's Stuck conditions; omit otherwise)

QUEUE-EMPTY
(only if /todo next found no free, unblocked, ungated task; omit otherwise)

WAITING: <what's pending — the only legitimate case is address-pr's wait-for-approval merge tier (address-pr/SKILL.md §3): the hard gate already passed (CI green, Claude Code review addressed, test plan verified) but merge needs a human's formal GitHub review approval, e.g. "PR #<n> ready to merge, awaiting human review approval (wait-for-approval tier)">
(only if the cycle ended in this wait-for-approval state, which resolves without further /drive action — either a human merges directly, or the next cycle's Phase 0 completes it once approved; omit otherwise. CI-in-progress is never this case: /drive always waits it out internally and never returns control mid-CI-wait, drive/SKILL.md:426,636)
```

Wait for the dispatched agent's completion notification before proceeding to Phase 4 — do not poll, do not schedule a separate `ScheduleWakeup` for this wait (same pattern as waiting on any other background agent). If the dispatch itself fails or the agent's final message doesn't parse into the format above, treat it as the **Stuck** case in Phase 4 with `last_stuck_reason: "dispatch failed or report unparseable"`.

### Phase 4: Classify the outcome and reschedule

Everything below reads off the dispatched agent's final report (Phase 3's fixed format), not a directly-witnessed `/drive` run — "`/drive` reports/returns/errored" means what the report says (or its absence/malformed shape, per Phase 3's parse-failure fallback).

- **Progress** — none of the four Stuck conditions below fired this cycle, **and** either `/drive` merged something or the cycle ended in a wait state that resolves **without further `/drive` action** — in practice this is only `/address-pr`'s wait-for-approval merge tier (`address-pr/SKILL.md` §3): the hard gate already passed (CI green, review addressed, test plan verified) but merge needs a human's formal GitHub review approval. (CI still running is never this case — `/drive` waits it out internally and never returns control mid-wait, per `drive/SKILL.md`'s unconditional wait instruction, `drive/SKILL.md:426,636`.) — the all-four-clear condition gates the whole bucket, not just the wait-state case, since a multi-task cycle can merge one task via blocker recursion and still hit a Stuck condition on another before returning: reset `stuck_count = 0`. Update the state file: `stuck_count: 0`, `cycle_count += 1`, `last_cycle_at: now`, `last_outcome: "progress"`, `last_task`/`last_stuck_reason: null`. Then `ScheduleWakeup(delaySeconds: 60, prompt: "/autopilot until <end_time> stuck=0", noop: false, reason: "continuing autopilot — last /drive cycle made progress")`. Done with this turn.
- **Empty queue / nothing actionable** — `/drive` reports no free, unblocked, ungated task exists: update the state file (`cycle_count += 1`, `last_cycle_at: now`, `last_outcome: "queue-empty"`, `stuck_count: 0`, `last_task`/`last_stuck_reason: null` — clearing these prevents a stale Stuck bullet in a later `status` report for a run that actually stopped cleanly), then go to Phase 5 with stop reason `queue-empty`. Don't reschedule — there is nothing a further wake would change.
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
(one bullet per item left mid-flight that no skill can resolve unattended; "- Nothing outstanding" if there is truly nothing left)
```

1. **Every `T<id>` or `PR #<n>` reference carries a short slug** — a few words on what it's actually about (task title or a one-line gist), not the bare id — so the report is scannable without looking anything up. Best-effort from this conversation's history; if a slug genuinely can't be recovered (e.g. after a resume with no surviving context), fall back to the bare id rather than guessing.
2. **Done** lists only what actually merged this run. **Needs your attention** applies the same **Needs-your-attention filter** as Phase 0 (see Important Notes) — a Stuck task still mid-backoff when `elapsed` fired always qualifies (that's the definition of Stuck: no skill resolved it); a merely-open PR or a task `Blocked by T{id}` does not, since a fresh `/autopilot`/`/drive` invocation drains/recurses into those automatically — omit them even though the run has stopped. For the `queue-empty` stop reason this is usually "Nothing outstanding". The tally isn't guaranteed to survive a `ScheduleWakeup` resume — reconstruct what you can from this conversation's history, but don't claim precision it can't back up.
3. Update the state file (see § State file): `status: "stopped"`, `stop_reason: <reason>`. Leave `stuck_count`/`cycle_count`/`last_*` at whatever Phase 4 (or the `queue-empty` branch) last set — this is what makes the report reconstructible by a later `/autopilot status` even after this conversation is gone.
4. Post the report to `/slack --channel dev` (`#claude-notification` — not the default automation-alerts channel).
5. Report the same template, filled in the same way, to the user in this turn's response.

## Important Notes

- **Needs-your-attention filter (applies to both Phase 0 and Phase 5).** Only surface an item if no existing skill can resolve it unattended. Concretely, **exclude**:
  - A task that's merely `status: Blocked by T{id}` — that's a dependency chain; `/drive` Phase 6 recurses into the blocker on its own, no human input needed.
  - A PR that's merely open with routine CI failures, a pending review, or a rebase-able conflict — `/address-pr` fixes and drives all of that automatically; the next `/drive` cycle's Phase 0 will drain it.
  **Include** only:
  - `last_outcome == "stuck"` — the loop's own escalation path already exhausted what a skill can do (safety valve, unresolvable conflict, unverifiable test-plan item, or one of `/drive`'s own Escalation Rules).
  - A task whose `status:` line itself flags a human-only condition — e.g. `SUPERVISED`, "needs a human", an external/live-environment spot-check, a maintainer sign-off/design decision — since no skill has the access or authority to close it.
  This keeps the report a to-do list of things only the maintainer can act on, not a live mirror of `/drive`'s in-progress backlog.
- **Never loop within a single turn.** Each `/drive` cycle is exactly one `ScheduleWakeup` boundary — this is what lets a multi-hour `/autopilot` survive context compaction and interruptions cleanly, the same way `/loop`'s dynamic mode does.
- **Context growth is bounded by dispatch, not by clearing.** Neither `/clear` nor `/compact` is available to this skill as an action — both are CLI built-ins a human types, not tools; automatic compaction is the harness's own passive backstop and fires regardless of anything in this file. Phase 3's sub-agent dispatch is what actually keeps `/autopilot`'s own context flat across an arbitrarily long run: a full `/drive` cycle's internal work never enters this conversation, only its compact report does. This is also why `last_task`/tally reconstruction (Phase 5, point 1) is already written to degrade gracefully — the same "no surviving detail, fall back to the bare id" posture applies whether the gap came from a `ScheduleWakeup` resume or from reading only a dispatched agent's summary.
- **Stuck backoff is silent — from `/autopilot`'s side.** `/autopilot` itself only posts to Slack once, at the final Phase 5 stop — a backing-off cycle just reschedules quietly (`noop: true`) and moves on. A Stuck cycle folded in from `/drive`'s own Escalation Rules may already have sent its own Slack message before `/autopilot` ever classified the outcome; that's `/drive`'s notification, not a repeat autopilot post, and it can recur once per backoff retry for as long as the underlying escalation cause persists. The `/address-pr`-delegated Stuck case (safety valve, unresolvable conflict, unverifiable item) posts **no** notification of its own — it's silent through every backoff retry it causes, with no way out but the window elapsing (this path never produces the `queue-empty` reason, only `elapsed`), so the only visibility is this skill's own Phase 5 summary once that happens.
- **Queue-empty is a stop, not a backoff case.** If there is genuinely nothing actionable, waking up again on a timer won't change that; only a future `/stage`/`/todo sweep` adding new work would, and the user can just re-run `/autopilot` then.
- **This does not replace `/ccxp`.** `/ccxp` is the full ritual-aware orchestrator (standup, IPM, retro) meant for the daily/weekly cron cadence; `/autopilot` is a plain duration-boxed `/drive` loop for an interactive "go work for N hours" ask.
- **One active run per repo, best-effort.** The state file assumes a single `/autopilot` loop per repo — there's no lock. Running two concurrently in the same repo will have the second's writes clobber the first's; not guarded against, same as the rest of this skill's concurrency posture today.

## Cross-references

- `/drive` — does all the actual task-selection/implementation/merge work, once per cycle, run via a dispatched sub-agent (Phase 3), not inline
- `drive/SKILL.md`'s `--dispatch-blockers` mode — the precedent this skill's Phase 3 dispatch pattern mirrors (Agent tool, compact report only, T20260719-204917)
- `/ccxp` — the full ritual-aware orchestrator this skill deliberately does not replace
- `/slack` — posts the stop summary (`--channel dev`, i.e. `#claude-notification`)
- `superpowers` `ScheduleWakeup` — the resume mechanism between cycles
- `dev/.autopilot-state.json` — this skill's own gitignored state file (§ State file), read by Phase 0's `status` report
