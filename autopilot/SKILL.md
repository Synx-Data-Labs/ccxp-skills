---
name: autopilot
description: Use when the user explicitly asks to turn the unattended background /drive loop on or off, pause or resume it, or check its status — "/autopilot on", "/autopilot off", "/autopilot pause", "/autopilot resume", "/autopilot status"
argument-hint: "on | off | pause | resume | status"
---

While `on`, keep running `/drive` one task after another, using `ScheduleWakeup` to survive without one long turn, until `/autopilot off`. Nothing drivable → notify once, wait, try again. No standup/IPM/retro (that is `/ccxp`'s job). This skill owns the on/off/loop/pause bookkeeping, not selection, implementation or merging. Each cycle's `/drive` runs in a dispatched sub-agent, so context grows by one report per cycle.

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

## Argument

Exactly one of these (case-insensitive, nothing else). There is no duration argument and no resume token.

- `on` — start the loop, or (when already on) run the next cycle if one is due. See Phase 1.
- `off` — stop the loop and remove the dispatch clone. Phase 0.1.
- `pause` / `resume` — stop dispatching but keep the clone and state / continue. Phase 0.1.
- `status` — read-only report. Phase 0.

Anything else (including a leftover pre-redesign wake such as `/autopilot until <ISO> stuck=<n>` or `/autopilot 6h`): run Phase 0's report, say the command is not supported, and do nothing else. A state file from the old design (no `"schema": 2`) reads as `off`.

## Helper and files

All state arithmetic lives in `<skills-root>/autopilot/scripts/autopilot-state.sh` (unit-tested in `tests/autopilot_state.bats`); call it instead of editing JSON by hand. Run it with `bash`, one command per call.

- `dev/.autopilot-state.json` (gitignored, schema 2) — the loop's source of truth. Fields: `status` on|paused|off, `started_at`, `paused_at`, counters (`cycle_count`, `merged_count`, `stuck_count`, `waiting_count`, `*_today`), `last_outcome`/`last_task`/`last_stuck_reason`, `next_wake_at`, `busy_since`, `current_task` (the task id the busy cycle drives; set by `busy on T<id>`, cleared by `busy off`/`record`; informational only, the HUD names the cycle by its ledger job instead (`running r<n>`); optional, 5.4.0 files without it work), `dispatch_clone_path`, notify-once flags, `notices`. Also `visits` (task id to its count of no-progress visits) and `parked` (the last 50 tasks the loop parked: `{id, at, reason, visits}`); both are local to this machine and carry over `off`/`start`, and a 5.9.0 file without them loads unchanged. Writes are atomic. There is **no skip list and nothing in any task file** that says why a task could not be finished: the queue order is the record of priority (Phase 3).
- `dev/.autopilot-history.jsonl` (gitignored, append-only) — one `{ts, outcome, merged, task}` line per `record` call (`task` is a task id or `""`; no free text, no secrets). Written by `record` itself (so nothing else logs a merge), plus one `{ts, outcome: visit|advance|park, merged: 0, task, visits}` line per visit, reset and park (`stats` ignores those); a write failure is swallowed and never breaks `record`. It survives `off`/`start`. The state file also keeps `lifetime_started_at`, `lifetime_cycles` and `lifetime_merged`, which `start` carries over (a state from before they existed is seeded from its run counters), so `off` then `start` never resets the lifetime baseline.
- `autopilot-state.sh stats [--json]` — progress over the rolling last 24 h (merged, cycles, stuck, waiting, idle; `capped` ticks are not cycles) and the lifetime average per 24 h (`lifetime_merged / max(1, days since lifetime_started_at)`), with a trend (`up`/`down`/`flat` for 24 h merged against the average at one decimal). The 24 h figures are exact when the log reaches back over the whole window, or when no cycle ran inside it; otherwise (`approx: true`) they are the larger of the log and the state's calendar-day counters, an estimate that can be off either way (the HUD marks it `~` and draws no arrow). Earlier work counts through the state counters, so the average is meaningful from day one. The HUD's AP band shows it as `last 24h: 8 merged ▲ / 26 loops · average 5.2/day`, green `▲` above the average, red `▼` below, no arrow when equal at one decimal (`hud/README.md`).
- `dev/.autopilot-config.json` (gitignored, optional) — `{"daily_cycle_cap": 24, "daily_merge_cap": 12, "idle_retry_minutes": 45, "max_visits": 3}`. A missing file or key uses these defaults; they are not command arguments. `max_visits` is how many no-progress visits park a task.
- This skill must run in the main session: only it can `ScheduleWakeup` and receive `pause`/`off`.

## Workflow

### Phase 0: Status (read-only)

For `status` (and for an unsupported argument): run `autopilot-state.sh report` and relay it. Then add, derived live and never from a cache:

- **Done**: `autopilot-state.sh done` (journal files added since `started_at`, one bullet each; prints "- No tasks merged this run" when empty).
- **Needs your attention**: `autopilot-state.sh parked-list` (tasks the loop parked since this run started: `parked by autopilot: T<id> — <reason>`), plus a task whose `status:` flags a human-only condition (`SUPERVISED`, a sign-off) and an open PR stuck in a way no skill resolves; apply the filter in Important Notes.

No Slack post, no `ScheduleWakeup`: this phase never touches the loop.

### Phase 0.1: off / pause / resume

1. `ScheduleWakeup(stop: true)` first, always (for `off` and `pause`).
2. A sub-agent dispatched (mid-cycle, the cycle agent or the Phase 4 housekeeping agent)? `SendMessage` it to commit and push WIP (no PR needed, `/drive` resumes from a pushed branch) and report; wait up to 2 minutes, then `TaskStop`. When it has reported (or been stopped), run `autopilot-state.sh busy off`.
3. `off`: `autopilot-state.sh off` prints `off <clone-path>`. Capture the final report **before** removing the clone, from the clone's fresh `main` (the bottom and park PRs land there first): `git -C <clone-path> pull -q`, then `AUTOPILOT_REPO_ROOT=<clone-path> autopilot-state.sh final-report > <tmp file>` (Phase 5). Then remove the clone directory with `rm -rf` of the literal path (it is under `/tmp`, which the rm-guard hook allows) and post the saved report to the user. `noop` (already off, or nothing to pause): report the current state and stop.
4. `pause`: `autopilot-state.sh pause` (`noop` if not on: report the state); keep the clone and state; report.
5. `resume`: `autopilot-state.sh resume` prints `dispatch` (go to Phase 2, the cap check, then one cycle now) or `busy` (the interrupted cycle is still finishing: do nothing, its Phase 4 re-reads `on` and arms the next wake) or `noop` (not paused: report).

### Phase 1: on

Run `autopilot-state.sh start`:

- `started` — fresh run; go to Phase 2.
- `dispatch` — already on and a cycle is due (the wake fired); go to Phase 2.
- `already-on` — a typed `on` before the next wake is due, or a cycle is running: report `already on, next cycle at <next_wake_at>` and stop. Never dispatch, never schedule.
- `busy` — a previous run's cycle is still finishing: report it and do nothing; that cycle's Phase 4 arms the next wake.
- `paused` — report "paused; use /autopilot resume" and stop.

### Phase 2: Cap check

`autopilot-state.sh cap` prints `ok` or `capped:cycles|merges`. On `capped:*`: `autopilot-state.sh record capped`, send its notice kind if not `none` (Phase 4 Notify), then `ScheduleWakeup(<delay capped>, "/autopilot on")` and end the turn. The loop stays on; it re-checks hourly and resumes after the daily rollover.

### Phase 3: Run one cycle

**Dispatch clone** (once per run, reused every cycle). Read `dispatch_clone_path`; if `null` or missing, create it and record the path in the state file:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
CLONE_PATH="$(bash <skills-root>/autopilot/scripts/autopilot-state.sh clone-path "$REPO_ROOT")"
[ -d "$CLONE_PATH" ] || git clone --recurse-submodules "$(git -C "$REPO_ROOT" remote get-url origin)" "$CLONE_PATH"
```

`clone-path` prints `/tmp/autopilot-clone-<repo-name>-<8 hex of sha256(repo root)>`.

A dirty or mid-rebase leftover: remove the directory and re-run the block. Full clone, never a worktree or shallow; the same path every cycle keeps the same `claimant_id` (`_session/claimant-id.sh`).

**No pick in the dispatcher.** The dispatcher does not walk the queue or keep a skip list; `/drive` takes the top eligible task of `queue.md`. `git -C "$CLONE_PATH" checkout main -q && git -C "$CLONE_PATH" pull -q`, then `autopilot-state.sh prune "$CLONE_PATH"` (drops visit counters of tasks that left `dev/TODO`) and `autopilot-state.sh pickable "$CLONE_PATH"` (a cheap read, no agent) prints:

- `pick`: `todo-next.sh --skip-gated` finds a task `/drive` may take. Dispatch.
- `drift`: nothing pickable, but `todo-sweep.sh plan` has mechanical findings (untracked task file, stale queue entry, closed-but-queued task); `/drive`'s own Phase 1 sweep fixes them. Dispatch. A drift dispatch that merges nothing ends `idle`/`stuck` and waits out its back-off, so permanent drift costs at most one agent per interval.
- `none`: queue empty, or every queued task gated or parked. Go to Phase 4 `idle` without dispatching.

**Priority is the queue, and the task files stay clean.** Nothing is written to a task file to say why a cycle could not finish it. A cycle that ends `NEEDS-ATTENTION` or `STUCK` without advancing the task is a **no-progress visit**: Phase 4 has the task `/bottom`ed (so the next cycle picks the next task) and bumps its visit counter. After `max_visits` (default 3) no-progress visits the task is **parked** (`dev/PARKING/`, a `## Parked` section with the last reason, off the queue); the owner revives it by hand. A visit that advances the task (merged, split into sub-tasks, a design PR merged, a claim that led to work) resets the counter. Statuses that already mean "not for the loop" (`Blocked by T<id>`, `SUPERVISED`, `BLOCKED`, `needs manual`, `sign-off`) are skipped by auto-pick as before. Task size is never a reason to stall: a big or umbrella task is picked and split (see **Big tasks** below). Worst case: 3 visits for each blocked task; the daily cycle and merge caps spread them over days (a repo with 47 blocked tasks needs about 140 no-progress visits).

**Dispatch** `/drive --auto-selected` (no id: auto-pick, Phase 0 PR drain still runs) via the `Agent` tool (`subagent_type: general-purpose`, no `isolation`) after `autopilot-state.sh busy on "$(autopilot-state.sh top "$CLONE_PATH")"` (the task `/drive` is about to pick; an empty id is ignored); note the `agentId`. The cycle's ledger start line must pass `--flags autopilot` (e.g. `ledger.sh start <n> "autopilot cycle" --flags autopilot`) so the HUD shows `running r<n>` while it runs. One `/drive` at a time (16 GB machine): never start a second while one is busy. The prompt is self-contained: name `$CLONE_PATH`, require `/drive` to run to completion, give Phase 4's classification rules, and add the guardrail and the big-task rule below. A `/todo sweep` park ask (Step B) needs a human: the sub-agent reports it as `STUCK`. **Every bash command for the whole `/drive` run begins `cd "$CLONE_PATH" &&`** (a sub-agent's Bash does not keep `cd` between calls).

**Eligibility guardrail (in the prompt).** Before claiming anything, `/drive` reads the design. Build, implementation and release-engineering work is eligible and runs end to end through the normal `/drive` gates, **including real runs**: dispatching real build workflows, pushing images or packages to the team's registries or artifact stores, uploading artifacts, tagging release candidates. Real runs follow the task's own done-criteria and the repo's runbooks. If the design calls for any of the following, it must stop and answer `NEEDS-ATTENTION: T<id> — <reason>`: (a) a customer-visible post or announcement, or a message sent to a third party; (b) an action or contact toward HashData or any upstream project; (c) spending money or signing up for a paid service; (d) installing software that changes the owner's machine state outside the repo/clone; (e) access to an owner account or credentials the sub-agent does not have; (f) an open owner decision the task text leaves unresolved; (g) deleting registry artifacts (the owner approves the exact list first); (h) final customer-facing release promotion or app-store submission (a push to a registry or repo that customers consume counts as (h); a tag is allowed only when the workflow it triggers stays inside the permitted runs). Task size, estimation or being an umbrella is not on this list. For (f), a sub-task may be filed for the open question, but the agent must not guess the answer. **Stopping.** On any of (a) to (h) answer `NEEDS-ATTENTION: T<id> — <reason>`: write nothing to the task file to say why (the dispatcher bottoms the task). If a design PR, a split, a pushed branch, an open PR or real work landed before the stop, also report `ADVANCED:` for it (see the format below); `ADVANCED` is only for work that landed in this run, never for work from an earlier run, otherwise a task that keeps stopping at the same guardrail would reset its own counter each cycle. When `/drive` recursed into a `Blocked by` blocker (Phase 6) and that blocker stalls, report `NEEDS-ATTENTION: T<blocker>`; the goal keeps its `Blocked by` status. Existing merge gates stay: green CI with all required checks finished, independent review posted on the PR, `gh pr merge --rebase`, never `--admin` or a bypass.

**Big tasks (in the prompt).** There is no size limit. If the task is too big to finish in one run (e.g. estimation 5, or an umbrella), the sub-agent does not stop or skip: it breaks the task into small sub-tasks (estimation 1-2 each, a bounded number per cycle, about 5; a sub-task that is itself too big may split again only once), files them with the repo's normal task flow (`/new-task`, or the template plus `_taskid/new.sh`), enqueues them right before the original (give each sub-task `blocks: T<original-id>` in its frontmatter and run `/stage <sub-id>`, which inserts it immediately before the queued original; or, for one already queued, `/top <sub-id> --before <original-id>`; queue order is enough, so leave the original's `status:` alone, because a `Blocked by` status makes `eligible` refuse it), lands the split as one small docs-only PR through the normal gates, then `/drive`s the first sub-task end to end in the same run. It reports the split (sub-task ids and titles) before the MERGED/STUCK lines. A task claimed by another live session is still not taken over.

End the sub-agent's final message in exactly this format:

```
MERGED: T<id> (<slug>) — PR #<n>[; runs: <run/registry URLs>]      (one line per merged task; omit if none; list any real build/publish/push run URLs)
STUCK: <short reason> — last task T<id> (<slug>)[; runs: <URLs>]   (list anything already published; only if it stopped without merging or hit its own Escalation Rules)
ADVANCED: T<id> — <what moved>        (a task moved forward without being finished: a design PR merged, a split landed, a branch pushed or a PR opened, work that continues next cycle; never for a claim alone; omit if none)
NEEDS-ATTENTION: T<id> — <reason>     (only per the guardrail above)
WAITING: <what is pending>            (only address-pr's wait-for-approval tier, a human's formal approval; CI-in-progress is never this)
```

Wait for the completion notification; don't poll. Housekeeping (Phase 4) runs as a second small sub-agent after this one reports, never in parallel with it. A failed dispatch or an unparseable report is **Stuck** ("dispatch failed or report unparseable"). An `off`/`pause` arriving during the wait takes priority (Phase 0.1).

### Phase 4: Classify, notify, reschedule

First re-read `autopilot-state.sh status`: not `on` means off/pause won while the cycle ran; run `busy off`, record nothing further and schedule nothing.

Write the sub-agent's final message to a temp file and run `autopilot-state.sh classify <file>`: it prints `<outcome> <merged-count> <task-id|-> <reason>` (exit 2 = unparseable, printed as a stuck line). The rules `classify` applies, in this order:

- **progress**: something merged, or a task was `ADVANCED`, and nothing Stuck. Wake in 60 s.
- **waiting**: nothing merged, `WAITING:` reported. Back-off ladder 5, 10, 20, 30 min (capped), using `waiting_count`.
- **stuck**: `/drive` errored, merged and advanced nothing, hit its own Escalation Rules, or its `/address-pr` stopped without merging. Same ladder, using `stuck_count`.
- **bottomed**: the only lines are `NEEDS-ATTENTION`. The stalled task is about to leave the top of the queue, so wake in 60 s; it touches neither `stuck_count`, `waiting_count` nor a notice flag.
- **idle**: no eligible task (Phase 3 `pickable` found none, or `/drive` reported none). Retry every `idle_retry_minutes` (default 45, valid range 30-60).

**Visits (before `record`).** Run these from the owner's repo, not from `$CLONE_PATH` (the state file is found from the working directory). `autopilot-state.sh plan <file> --fallback <the id from busy on, if any>` prints `<task-id><TAB>advanced|stalled<TAB><reason><TAB><source>` per task the report names. For each `advanced` line run `autopilot-state.sh advance <id>` (resets its counter). For each `stalled` line run `autopilot-state.sh visit <id> "<reason>"`, adding `--stuck` when the source is `stuck`: it prints `bottom <n>`, `park <n>` (`n` reached `max_visits`), `skip` (a run of `stuck` cycles looks like an outage, not like the task: nothing is done to the task) or `none`. A `WAITING` cycle names no task and counts no visit. A `STUCK:` line that names no task falls back to the id `top` printed before dispatch; an unparseable report or a failed dispatch has no `STUCK:` line, names nothing, and counts no visit (it was not the task's doing). The count of a `visit` stands even if the housekeeping below then fails: the task did stall, and the back-off bounds the retries.

**Housekeeping.** When any `visit` printed `bottom` or `park`, dispatch one small sub-agent (`general-purpose`, no `isolation`, `busy` still on) whose prompt is self-contained and starts every bash command with `cd "$CLONE_PATH" &&`. For each task it works in this order, one docs-only PR per task through the normal gates (`git -C "$CLONE_PATH" pull -q` first; green CI, independent review posted, `/address-pr <number>`, `gh pr merge --rebase`, never `--admin`):

- Release the claim only if this clone holds it and the status is `In Progress` or `Design`: `bash <skills-root>/_session/task_claim.sh read T<id>` shows `claimed_by` equal to `task_claim.sh claimant-id`, then `task_claim.sh release T<id> Open`. Never `release-others` (it would free a `Review` task with a live PR).
- `bottom`: run `/bottom` with the dependants first and the stalled task last in the list, so the stalled task is ahead of them: `/bottom T<dependant> ... T<id>` where the dependants are the tasks the stalled one `blocks:` (a split sub-task's original) and every open task whose status is `Blocked by T<id>` (sweep Phase 2 would otherwise move the blocker back ahead of them). No visit is counted for dependants. Include the released task file in the `land.sh` path list. `land.sh` exit 3 (already last, nothing to land) and a task that has already left `dev/TODO` (`bottom.sh` exit 1) are success.
- `park`: first check there is no open PR (`gh pr list --search "t<id-digits>"`) and no remote branch `t<id-digits>` for the task and no other open task with status `Blocked by T<id>` (sweep would auto-unblock it). If any exists, do a `bottom` instead and report why. Otherwise `bash <skills-root>/todo/scripts/todo-sweep.sh park T<id>:"<reason>; autopilot visited <n> times without progress"`, then `bash <skills-root>/_taskid/epic-links.sh sync` and `git add dev/EPICS`, one PR (stage `dev/TODO`, `dev/PARKING`, `dev/EPICS` and `queue.md`). This is the park the owner authorized (no approval step); nothing else may be parked this way.
- Report one line per task: `BOTTOMED: T<id> — PR #<n>[; park refused: <why>]`, `BOTTOMED: T<id> — no change (<why: already last, sole task, or already out of dev/TODO>)`, `PARKED: T<id> — PR #<n>`, or `HOUSEKEEPING-FAILED: T<id> — <reason>`.

Then, for each `PARKED:` line run `autopilot-state.sh parked <id> "<reason>"` and notify kind `parked`; for a `BOTTOMED:` line with `park refused` whose `visit` printed `park <n>` with `n` equal to `max_visits`, notify kind `attention` once ("T<id> reached <n> visits but cannot be parked: <why>"; later visits stay silent). If any task has no `BOTTOMED`/`PARKED` line, the agent failed, a line says `no change` or `park refused` (the task is still at the top, so the next cycle would pick it again), record the cycle as **stuck** (`bottom/park not landed for <id>`) instead of the classify outcome, keeping the merged count: `record stuck <merged-count> <task-id> "<reason>"`. The back-off ladder then stops a failed or pointless PR from causing a 60 s redispatch loop. Such cycles raise `stuck_count`, so three in a row also send the `stuck` notice and switch the `--stuck` visit skip on. Otherwise run `autopilot-state.sh record <outcome> <merged-count> <task-id> "<reason>"` with the `classify` fields (id `-`: pass `""`); it prints a notice kind or `none` and sets the next wake time.

**Notify** for each non-`none` kind returned: `autopilot-state.sh notify <kind> "<text>"`, one concise bullet list (kind `idle` names the tasks from `parked-list` and says retries are silent; `resumed` says work is flowing again; `stuck` names the task and reason; `waiting` names the PR; `capped` names the cap; `parked` names the task, its last reason and "autopilot visited <n> times without progress"). `notify` tries `/slack --channel dev` and, when the env vars are unset or the post fails, records the notice in the state file (shown by `status` and the HUD); it never errors, so never retry or escalate it.

Then `ScheduleWakeup(delaySeconds: <autopilot-state.sh delay <outcome>>, prompt: "/autopilot on", reason: "autopilot <outcome>")` and end the turn. Every wake carries the same prompt; the state file decides whether it dispatches (Phase 1).

### Phase 5: Final report (on `off`)

After `autopilot-state.sh off` (and before the clone is removed, see Phase 0.1), run `autopilot-state.sh final-report` (with `AUTOPILOT_REPO_ROOT=<clone-path>`) and post its output unchanged (it also serves as the `off` notice text for `notify`). Append to "Needs your attention" any open PR stuck beyond what a skill resolves (not derivable from state). The template it prints:

```
Autopilot run: <elapsed> elapsed — stopped: user-requested

Done:
- Merged T<id> (<slug>) — PR #<n>
(one bullet per merged task this run, from the `done` journal scan; "- No tasks merged this run" if none)

Needs your attention:
- <tasks parked by autopilot (from `parked-list`), stuck tasks, PRs stuck beyond any skill>
(or "- Nothing outstanding")
```

Every `T<id>`/`PR #<n>` carries a short slug (bare id if it cannot be recovered).

## Important Notes

- **Needs-your-attention filter**: only items no skill can resolve unattended. Exclude `Blocked by T{id}` (a dependency `/drive` recurses into) and an open PR with routine CI/review/rebase work (the next cycle's `/drive` Phase 0 drains it). Include `parked-list` entries (tasks parked after `max_visits` no-progress visits), `last_outcome == "stuck"`, and tasks whose `status:` names a human-only condition.
- **Never loop inside one turn.** One cycle is exactly one `ScheduleWakeup` boundary.
- **One run per repo, best-effort.** No lock beyond `busy_since`/`next_wake_at`; the dispatch clone path is deterministic per repo.
- **Idle is not a stop.** Going idle notifies once; retries are silent; new work (`/stage`, `/todo sweep`) is picked up on the next retry.
- **A detached `claude --bg` loop** is a possible later upgrade; v1 runs in the main session.
- **Not `/ccxp`.** `/ccxp` is the ritual-aware orchestrator; this is a plain on/off `/drive` loop.

## Cross-references

- `/drive` — does the selection/implementation/merge work, one cycle per dispatch (`/drive --auto-selected`)
- `/slack` — `notify` posts to `--channel dev` when configured
- `/todo` — `next --skip-gated` and `sweep` plan feed `pickable`; `todo-sweep.sh park` is the park; `/bottom` moves a stalled task to the back of the queue; `/address-pr` — drains and merges PRs
- `hud/` — `AP on/off` band reads `dev/.autopilot-state.json` (`hud/scripts/hud-lib.sh`)
