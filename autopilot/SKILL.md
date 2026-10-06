---
name: autopilot
description: Use when the user explicitly asks to keep working tasks unattended for a set duration — e.g. "/autopilot for the next 6 hours" or "/autopilot 6h"
disable-model-invocation: true
argument-hint: "<duration> | status | pause [--now] | resume | stop [--now]"
---

Keep dispatching bare `/drive` cycles back-to-back until at least `<duration>` has elapsed, using `ScheduleWakeup` to survive the whole span without staying in one long-running turn. No standup/IPM/retro rituals — that's `/ccxp`'s job. This skill owns only the duration/loop/pause/stop bookkeeping; task selection, claiming, implementing, PR babysitting, and merging are entirely `/drive`'s. Each cycle's `/drive` run happens in a dispatched sub-agent, not inline (see Phase 3) — this skill's own context only ever grows by one compact report per cycle, which is what actually lets a multi-hour run stay small; automatic compaction is a backstop, not the mechanism.

## Argument

- `<duration>` — free text, read directly rather than parsed by a script: `6h`, `90m`, `for the next 6 hours`, etc. Compute an absolute end-time from it (see Phase 1) — never re-derive "N hours from now" on a later wake, or the window drifts later every cycle.
- `status` — exact match, case-insensitive, no other text. Read-only report of the current/last run; see Phase 0. Does not start or continue the loop.
- `pause [--now]` — exact match (plus the optional `--now` flag), case-insensitive. Pauses a `running` loop — freezes duration bookkeeping and suppresses the next cycle, without ending the run; see Phase 0.1. Must be typed as a new message into this exact session — there is no cross-session or flag-file signaling.
- `resume` — exact match, case-insensitive. Resumes a `paused` loop from where it left off; see Phase 0.1. Distinct from the `/autopilot until <ISO> stuck=<n>` resume-prompt format Phase 1 reads on every `ScheduleWakeup` wake — that one is this skill's own internal continuation contract; this is the user-invoked un-pause.
- `stop [--now]` — exact match (plus the optional `--now` flag), case-insensitive. Ends the run immediately, reporting actual elapsed time rather than the originally-requested duration; see Phase 0.1.

## State file

`dev/.autopilot-state.json` (gitignored) — written by this skill only, at the phase transitions below. It exists purely so a run's status survives a `/clear` (the resume-prompt contract in Phase 1 stays the loop's real, authoritative control values — this file is additive, never load-bearing for the loop itself). Fields:

```json
{
  "status": "running|paused|stopped",
  "started_at": "2026-09-17T14:30:00Z", "end_time": "2026-09-17T20:30:00Z",
  "paused_at": null,
  "stuck_count": 0, "cycle_count": 0,
  "last_cycle_at": null, "last_outcome": null,
  "last_task": null, "last_stuck_reason": null,
  "stop_reason": null,
  "dispatch_clone_path": null
}
```

`last_task` is `{"id": "T...", "slug": "..."}` or `null`. Everything else this skill might want to report (which tasks merged, which PRs are still open) is **not** stored here — Phase 0 derives it live from `dev/TODO/`, `dev/JOURNAL/`, and `gh`, since those are the actual source of truth and a cached copy here would drift.

`dispatch_clone_path` is the dedicated clone Phase 3 dispatches `/drive` into — `null` until first created, then the same path all run. Phase 5 removes the directory on stop. Phase 0.1's hard-kill (`--now`) path never removes it mid-run — see Phase 0.1.

`paused_at` is the ISO-8601 timestamp of the most recent `pause` — set while `status: "paused"`, cleared (`null`) on `resume`. `resume` shifts both `started_at` and `end_time` forward by `now - paused_at` before clearing it (Phase 0.1), so Phase 0/5's elapsed math (`last_cycle_at - started_at`) and Phase 2's `now >= end_time` check both stay correct without any separate pause-duration bookkeeping.

## Workflow

### Phase 0: Status (read-only)

If the argument is exactly `status` (case-insensitive, nothing else): read `dev/.autopilot-state.json`.

- **Missing file**: report "autopilot has never run in this repo" and stop. No further phases.
- **Present**: reuse Phase 5's Done/Needs-your-attention bullet formats (its header line is `stopped`-specific — Phase 0 has its own, below) and report it to the user. Do not post to Slack, do not call `ScheduleWakeup` — this phase never touches the loop.
  - Header line: `running` → `<requested-vs-elapsed>, ends <end_time>` from `started_at`/`end_time` (elapsed computed against `now`); **`paused` → `<requested-vs-elapsed-at-pause>, paused since <paused_at>`** — a distinct header, not the `running` branch reused, computed the same way as `running` but frozen at `paused_at` rather than live against `now` (pausing stops the clock, so showing elapsed against `now` would overstate it); `stopped` → `<requested> requested, <elapsed> elapsed — stopped: <stop_reason>` (elapsed computed as `last_cycle_at − started_at` — there is no separate stop timestamp, and `last_cycle_at` is the closest proxy to when the run actually stopped, or `0` if `last_cycle_at` is still `null` because the window elapsed before any cycle ran; `now − started_at` would overstate elapsed by however long ago the run ended).
  - **Done**: `git log --since=<started_at> --diff-filter=A --name-only -- dev/JOURNAL/` to find task files journaled since this run started; for each, read its frontmatter for the `(<repo>#<num>)` PR ref to fill the bullet. Empty → "No tasks merged this run" (or "yet" if `status: running`).
  - **Needs your attention**: apply the **Needs-your-attention filter** (see Important Notes) — in practice this means: skip `status: Blocked by T{id}` entirely (that's a dependency chain, `/drive` Phase 6 recurses into it on its own) and skip any `status: Review` PR that's merely open with routine CI/review/rebase work left (the next cycle's Phase 0 `/address-pr` drains it automatically). Only list a PR here if it's already stuck in a way no skill can resolve unattended — check the task's own `status:` line for a human-only marker (`SUPERVISED`, "needs a human", "needs manual", an external/live-environment spot-check, a maintainer sign-off) — and confirm via `gh pr view <n>` if a PR ref is present. If `last_outcome == "stuck"` (not merely `stuck_count > 0`, which can be stale — see Phase 4's `queue-empty` branch), add a bullet from `last_task`/`last_stuck_reason` — Phase 5's exact wording ("...still backing off when the window closed") only when `status == "stopped"`; if `status == "running"` (still mid-backoff, not yet re-woken), swap the trailing clause for "...currently backing off" instead, since the window hasn't closed. Empty → "Nothing outstanding".

### Phase 0.1: Pause / resume / stop (control commands)

If the argument matches `pause`, `pause --now`, `resume`, `stop`, or `stop --now` (case-insensitive, no other text besides the optional `--now`): these must be typed as a new message into this exact session — there is no cross-session or flag-file signaling, since this is the only session that can cancel its own pending `ScheduleWakeup` and that receives a new message even mid-cycle, while Phase 3 is waiting on a dispatched `/drive` subagent's completion notification (Phase 3's own wait instruction is conditional on exactly this — see its note there).

Read `dev/.autopilot-state.json` first. `status` must be `running` for `pause`/`stop` to apply, or `paused` for `resume` — any other combination (`pause`/`stop` on an already-`stopped` run, `resume` on a `running` or `stopped` run) is a plain no-op: report the current state via Phase 0's own read path and stop; don't act on the command.

**`pause [--now]`** (requires `status: running`):

1. `ScheduleWakeup(stop: true)` — cancel the next cycle's already-scheduled wakeup. This is always the first action, before touching anything else: without it the loop just keeps dispatching cycles on schedule regardless of this command.
2. If a `/drive` subagent is currently dispatched (this command arrived while Phase 3 was waiting on its completion notification): handle it per **Subagent interrupt** below.
3. Update the state file: `status: "paused"`, `paused_at: now`. Leave `started_at`/`end_time`/`stuck_count`/`last_task` untouched — `resume` needs them as-is.
4. Report the pause to the user (no Slack post — same as Phase 0's own read path, this never posts). Done with this turn; nothing further is scheduled until a `resume` message arrives.

**`resume`** (requires `status: paused`):

1. Compute the pause duration: `now - paused_at`. Shift **both** `started_at` and `end_time` forward by that amount — not `end_time` alone, since Phase 0/5's elapsed math (`last_cycle_at - started_at`) has no separate pause-duration term to subtract; moving `started_at` is what keeps that formula, and Phase 2's `now >= end_time` check, correct across any number of pauses.
2. Update the state file: `status: "running"`, `paused_at: null`, `started_at`/`end_time` as shifted.
3. Go to Phase 3. If `last_task` is set, dispatch `/drive T<last_task.id>` explicitly instead of a bare pick, for this one cycle only — this is what actually continues the interrupted task, rather than leaving it to `/todo next`'s ordinary queue walk, which might pick something else first if the queue changed while paused. If that dispatch reports the task is already Done or claimed by someone else, treat it as benign: immediately fall through to a bare `/todo next` dispatch in this same cycle — not a Stuck outcome, no backoff (none of Phase 4's Stuck conditions apply to this fallback).
4. From here on, Phase 3 onward proceeds exactly as a normal cycle — Phase 4's classification re-establishes `ScheduleWakeup` the usual way.

**`stop [--now]`** (requires `status: running` or `paused`):

1. `ScheduleWakeup(stop: true)` — cancel the next cycle's already-scheduled wakeup, same as `pause` step 1 (a no-op if already `paused`, since `pause` already cancelled it).
2. If a `/drive` subagent is currently dispatched: handle it per **Subagent interrupt** below.
3. Go to Phase 5 with stop reason `user-requested`.

**Subagent interrupt** (shared by `pause`/`stop` step 2 above):

- **Graceful (default, no `--now`)**: `SendMessage` the dispatched subagent (addressed by the `agentId` captured at its Phase 3 dispatch, `autopilot/SKILL.md:111`) asking it to commit any uncommitted work on its current branch with a WIP-prefixed message, push it (no PR required — `/drive` Phase 6's existing "resume by finding the pushed branch" convention is what makes this resumable later), and end its turn. Wait up to 2 minutes for it to actually finish. If it hasn't by then, escalate to `--now` below — pause/stop must never hang indefinitely against a subagent deep in a blocking wait.
- **`--now`**: `TaskStop` the dispatched subagent immediately, no further waiting, no cleanup. Any uncommitted work in `dispatch_clone_path` is lost — the accepted tradeoff for an instant interrupt. Do **not** `rm -rf`/recreate `dispatch_clone_path` as part of this — it's simply left dirty, exactly as today's existing "dirty/mid-rebase" fallback (`autopilot/SKILL.md:106`) already handles on the next dispatch. The priority task that triggered the interrupt is always worked from the user's own regular/interactive clone, never `dispatch_clone_path` — there's no need to reuse or clean up this clone until a future `resume`.

### Phase 1: Establish the end-time

Distinct from the control commands above: the "resumed invocation" case below is this skill's own internal `ScheduleWakeup` continuation contract, never typed by a human — the user-invoked `resume` in Phase 0.1 is a different thing and never reaches this phase at all (it jumps straight to Phase 3).

- **Resumed invocation**: the prompt matches `/autopilot until <ISO-8601 timestamp> stuck=<n>` *exactly* (e.g. `/autopilot until 2026-09-17T20:30:00Z stuck=2`) — a strict format check on the timestamp, not a loose match on the word "until". Reuse `end_time` and `stuck_count = <n>` verbatim. The running summary tally does not survive a resume in the prompt text — reconstruct what you can for the final report from this conversation's history, but don't block the loop on it; the loop's correctness depends only on `end_time` and `stuck_count`, both of which ARE threaded through every resume, never on the tally.
- **First invocation** (anything else, including free text that happens to contain the word "until" — e.g. `/autopilot until 5pm` — since it doesn't match the strict resume format above): treat the whole argument as `<duration>` and compute `end_time = now + <duration>` (ISO 8601, e.g. `2026-09-17T20:30:00Z`). Initialize `stuck_count = 0` and start a running tally of the summary this run will report at Phase 5 (cycles run, tasks merged, time spent backing off). Write a fresh `dev/.autopilot-state.json` (see § State file): `status: running`, `started_at: now`, `end_time`, `stuck_count: 0`, `cycle_count: 0`, `last_cycle_at/last_outcome/last_task/last_stuck_reason/stop_reason/dispatch_clone_path: null` — this overwrites any stale file left by a previous, already-stopped run (a prior run's dispatch clone, if any, was already removed at its own Phase 5 stop; `null` here just means Phase 3 will create one fresh on this run's first dispatch).

### Phase 2: Stop check

If `now >= end_time`: go to Phase 5 with stop reason `elapsed`.

### Phase 3: Run one cycle

**Ensure the dispatch clone exists (once per run, then reuse it every cycle).** Read `dispatch_clone_path` from `dev/.autopilot-state.json`. If `null` or the directory no longer exists (e.g. `/tmp` cleared since a `/clear`/resume), create it and record the path back into `dispatch_clone_path`:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_HASH="$(printf '%s' "$REPO_ROOT" | shasum -a 256 | cut -c1-8)"
CLONE_PATH="/tmp/autopilot-clone-$(basename "$REPO_ROOT")-${REPO_HASH}"
[ -d "$CLONE_PATH" ] || git clone --recurse-submodules "$(git -C "$REPO_ROOT" remote get-url origin)" "$CLONE_PATH"
```

If a prior cycle left it dirty or mid-rebase (crashed before Phase 7 cleanup), just `rm -rf "$CLONE_PATH"` and re-run the block above.

- **Full clone (own `.git`), not a worktree, not shallow.** A worktree shares `.git` with the parent — git refuses a branch already checked out elsewhere, and `/drive` checks out `main` constantly while the parent session normally sits there at rest, so a worktree would collide almost every cycle. `--dispatch-blockers` gets away with `isolation: "worktree"` only because it's one-off, not reused. Non-shallow since this clone lives for potentially hours.
- **Reused, never recreated, for the run's life.** Same path every cycle → same `claimant_id` (`_session/claimant-id.sh` hashes the clone's toplevel path) → claims behave like a normal peer clone (`_session/task_claim.sh` peer-mode already supports this). A fresh clone/worktree per dispatch would instead give every cycle a different identity, breaking "same clone = same claimant".

Dispatch `/drive` (bare auto-pick, or `/drive T<last_task.id>` on the first cycle after a Phase 0.1 `resume` — see there) via the `Agent` tool — `subagent_type: general-purpose`, **no `isolation` parameter** (the clone above already provides it; the tool's own worktree isolation would be a different, non-reused worktree per call). This is also what bounds a multi-hour run's own context growth — no `/clear`/`/compact` exists for this skill to call. **Note the returned `agentId`** — Phase 0.1's graceful pause/stop path addresses this exact subagent via `SendMessage` to interrupt it mid-cycle.

The prompt must be self-contained: this is `/autopilot` invoking `/drive` for its next cycle (bare, auto-pick); name `$CLONE_PATH`; require `/drive` run to completion. Give it Phase 4's classification criteria too, not just the report shape (a commit alone is not advancement — only a merge or a self-resolving wait counts as Progress).

**Verified, not assumed: a dispatched sub-agent's Bash tool does not keep a `cd` across separate calls** — `cd` in one call, then a bare `pwd` in the next, landed back in the original directory every time. A one-time "`cd` there first" instruction is not enough and would silently put most of `/drive`'s work back in the interactive session's clone — the exact collision this exists to prevent. State the rule without exception instead: **every bash command for the whole `/drive` run must begin with `cd "$CLONE_PATH" &&` in that same call** — never a bare command trusting a prior `cd`.

End its final message in exactly this format, so Phase 4 can classify mechanically without reading the sub-agent's full transcript:

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

Wait for the dispatched agent's completion notification before proceeding to Phase 4 — do not poll, do not schedule a separate `ScheduleWakeup` for this wait (same pattern as waiting on any other background agent) — **unless a new message matching `pause [--now]` or `stop [--now]` arrives first, which takes priority over this wait; see Phase 0.1.** If the dispatch itself fails or the agent's final message doesn't parse into the format above, treat it as the **Stuck** case in Phase 4 with `last_stuck_reason: "dispatch failed or report unparseable"`.

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
3. Update the state file (see § State file): `status: "stopped"`, `stop_reason: <reason>` (`"user-requested"` when reached via Phase 0.1's `stop`), `paused_at: null` (a stop reached directly from `paused` would otherwise leave a stale timestamp behind — harmless but not meaningful once stopped). Leave `stuck_count`/`cycle_count`/`last_*` at whatever Phase 4 (or the `queue-empty` branch) last set — this is what makes the report reconstructible by a later `/autopilot status` even after this conversation is gone.
4. **Remove the dispatch clone**: if `dispatch_clone_path` is set, `rm -rf "$dispatch_clone_path"` (plain directory removal — it's a real clone, not a worktree) and set `dispatch_clone_path: null` in the state file.
5. Post the report to `/slack --channel dev` (`#acme-dev-notifications` — not the default automation-alerts channel).
6. Report the same template, filled in the same way, to the user in this turn's response.

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
- **One active run per repo, best-effort.** The state file assumes a single `/autopilot` loop per repo — there's no lock. Running two concurrently in the same repo will have the second's writes clobber the first's. The dispatch clone's path is also deterministic per repo, so two concurrent runs would share it — not just a JSON clobber, but two dispatched `/drive` cycles doing live git operations in the same directory at once. Not a new hazard in kind (this skill has never guarded against concurrent runs), but worth naming precisely.

## Cross-references

- `/drive` — does all the actual task-selection/implementation/merge work, once per cycle, run via a dispatched sub-agent (Phase 3), not inline
- `drive/SKILL.md`'s Phase 1.5 ephemeral cross-repo clone — the precedent Phase 3's dispatch clone mirrors, reused across cycles instead of per-task
- `drive/SKILL.md`'s `--dispatch-blockers` mode — a one-off `isolation: "worktree"` dispatch, fine for a single call but not for `/autopilot`'s repeated cycles (see Phase 3)
- `/ccxp` — the full ritual-aware orchestrator this skill deliberately does not replace
- `/slack` — posts the stop summary (`--channel dev`, i.e. `#acme-dev-notifications`)
- `superpowers` `ScheduleWakeup` — the resume mechanism between cycles, and what Phase 0.1's `pause`/`stop` cancel (`stop: true`) before anything else
- `SendMessage` — Phase 0.1's graceful interrupt of the in-flight dispatched `/drive` subagent on `pause`/`stop`
- `TaskStop` — Phase 0.1's hard-kill escape hatch (`--now`, or the graceful-timeout escalation)
- `dev/.autopilot-state.json` — this skill's own gitignored state file (§ State file), read by Phase 0's `status` report and Phase 0.1's `pause`/`resume`/`stop`
