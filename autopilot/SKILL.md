---
name: autopilot
description: Use when the user explicitly asks to turn the unattended background /drive loop on or off, pause or resume it, or check its status — "/autopilot on", "/autopilot off", "/autopilot pause", "/autopilot resume", "/autopilot status", "/autopilot config"
argument-hint: "on | off | pause | resume | status | config [show | set <key> <value> | reset [<key>]]"
---

While `on`, keep running `/drive` one task after another, using `ScheduleWakeup` to survive without one long turn, until `/autopilot off`. Nothing drivable → notify once, wait, try again. No standup/IPM/retro (that is `/ccxp`'s job). This skill owns the on/off/loop/pause bookkeeping, not selection, implementation or merging. Each cycle's `/drive` runs in a dispatched sub-agent, so context grows by one report per cycle. By default one cycle runs at a time; the owner can allow several at once with the `max_dop` setting (below).

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

## Argument

Exactly one of these (case-insensitive; `config` takes its own sub-arguments, nothing else is accepted). There is no duration argument and no resume token.

- `on` — start the loop, or (when already on) run the next cycle if one is due. See Phase 1.
- `off` — stop the loop and remove the dispatch clone. Phase 0.1.
- `pause` / `resume` — stop dispatching but keep the clone and state / continue. Phase 0.1.
- `status` — read-only report. Phase 0.
- `config [show]` / `config set <key> <value>` / `config reset [<key>]` — view or change the settings in the config file. Phase 0.2. It reads and writes only that file: it never starts, stops, pauses or dispatches the loop and never calls `ScheduleWakeup`.

Anything else (including a leftover pre-redesign wake such as `/autopilot until <ISO> stuck=<n>` or `/autopilot 6h`): run Phase 0's report, say the command is not supported, and do nothing else. A state file from the old design (no `"schema": 2`) reads as `off`.

## Helper and files

All state arithmetic lives in `<skills-root>/autopilot/scripts/autopilot-state.sh` (unit-tested in `tests/autopilot_state.bats`); call it instead of editing JSON by hand. Run it with `bash`, one command per call.

- `dev/.autopilot-state.json` (gitignored, schema 2) — the loop's source of truth. Fields: `status` on|paused|off, `started_at`, `paused_at`, counters (`cycle_count`, `merged_count`, `stuck_count`, `waiting_count`, `*_today`), `last_outcome`/`last_task`/`last_stuck_reason`, `next_wake_at`, `busy_since`, `current_task` (the task id the busy cycle drives; set by `busy on T<id>`, cleared by `busy off`/`record`; informational only, the HUD names the cycle by its ledger job instead (`running r<n>`); optional, 5.4.0 files without it work; with parallel cycles they mirror the oldest running slot), `slots` (`{"<n>": {task, since}}`, one entry per running cycle, slot numbers 1 to `max_dop`; a file without it and with `busy_since` reads as slot 1 running; a mark older than 3 h is a crashed cycle), `dispatch_clone_path` (slot 1) and `dispatch_clone_paths` (`{"<n>": path}` for slots 2 and up), `last_hold` (why the machine guard held a slot), notify-once flags, `notices`. Also `visits` (task id to its count of no-progress visits) and `parked` (the last 50 tasks the loop parked: `{id, at, reason, visits}`); both are local to this machine and carry over `off`/`start`, and a 5.9.0 file without them loads unchanged. Writes are atomic. There is **no skip list and nothing in any task file** that says why a task could not be finished: the queue order is the record of priority (Phase 3).
- `dev/.autopilot-history.jsonl` (gitignored, append-only) — one `{ts, outcome, merged, task}` line per `record` call (`task` is a task id or `""`; no free text, no secrets). Written by `record` itself (so nothing else logs a merge), plus one `{ts, outcome: visit|advance|park, merged: 0, task, visits}` line per visit, reset and park (`stats` ignores those); a write failure is swallowed and never breaks `record`. It survives `off`/`start`. The state file also keeps `lifetime_started_at`, `lifetime_cycles` and `lifetime_merged`, which `start` carries over (a state from before they existed is seeded from its run counters), so `off` then `start` never resets the lifetime baseline.
- `autopilot-state.sh stats [--json]` — progress over the rolling last 24 h (merged, cycles, stuck, waiting, idle; `capped` ticks are not cycles) and the lifetime average per 24 h (`lifetime_merged / max(1, days since lifetime_started_at)`), with a trend (`up`/`down`/`flat` for 24 h merged against the average at one decimal). The 24 h figures are exact when the log reaches back over the whole window, or when no cycle ran inside it; otherwise (`approx: true`) they are the larger of the log and the state's calendar-day counters, an estimate that can be off either way (the HUD marks it `~` and draws no arrow). Earlier work counts through the state counters, so the average is meaningful from day one. The HUD's AP band shows it as `last 24h: 8 merged ▲ / 26 loops · average 5.2/day`, green `▲` above the average, red `▼` below, no arrow when equal at one decimal (`hud/README.md`).
- `dev/.autopilot-config.json` (gitignored, optional) — `{"daily_cycle_cap": 64, "daily_merge_cap": 64, "idle_retry_minutes": 32, "max_visits": 4, "max_dop": 1}`. A missing file or key uses these defaults. `max_visits` is how many no-progress visits park a task. `max_dop` (1-16, default **1**) is the maximum degree of parallelism: how many `/drive` cycles run at the same time. The default keeps today's one-task-at-a-time loop; to allow more run `/autopilot config set max_dop 8`, back to one with `/autopilot config reset max_dop`. Change it with `/autopilot config` (Phase 0.2); the next cap check or wake reads it, no restart.
- This skill must run in the main session: only it can `ScheduleWakeup` and receive `pause`/`off`.

## Workflow

### Phase 0: Status (read-only)

For `status` (and for an unsupported argument): run `autopilot-state.sh report` and relay it. Then add, derived live and never from a cache:

- **Done**: `autopilot-state.sh done` (journal files added since `started_at`, one bullet each; prints "- No tasks merged this run" when empty).
- **Needs your attention**: `autopilot-state.sh parked-list` (tasks the loop parked since this run started: `parked by autopilot: T<id> — <reason>`), plus a task whose `status:` flags a human-only condition (`SUPERVISED`, a sign-off) and an open PR stuck in a way no skill resolves; apply the filter in Important Notes.

No Slack post, no `ScheduleWakeup`: this phase never touches the loop.

### Phase 0.2: config

The helper validates and writes atomically (mode 600, other keys kept); never edit the JSON by hand.

- `config` / `config show`: `config-show [--json]`, read-only: effective value, `default` or `override`, range, file path.
- `config set <key> <value>`: `config-set`. Keys `daily_cycle_cap`, `daily_merge_cap` (1-1000), `idle_retry_minutes` (30-60), `max_visits` (1-20), `max_dop` (1-16, default 1; e.g. `config set max_dop 8`); value a positive integer. Exit 2 = refused, nothing written: relay the message. On success relay `config-show`.
- `config reset [<key>]`: `config-reset [<key>]` drops that override or all five; unknown keys stay.
- Any other `config` form: show the usage, stop.

Touches neither the state file nor the schedule; a running loop reads the value at its next cap check or wake. Lowering `max_dop` while cycles run never stops one: the extra slots finish and are not refilled. No Slack post, no `ScheduleWakeup`.

### Phase 0.1: off / pause / resume

1. `ScheduleWakeup(stop: true)` first, always (for `off` and `pause`).
2. A sub-agent dispatched (mid-cycle, the cycle agents or the Phase 4 housekeeping agent)? `SendMessage` each to commit and push WIP (no PR needed, `/drive` resumes from a pushed branch) and report; wait up to 2 minutes, then `TaskStop`. When they have reported (or been stopped), run `autopilot-state.sh busy off` (bare: clears every slot).
3. `off`: `autopilot-state.sh off` prints `off <clone-path>` (slot 1) and, with `max_dop` above 1, one `clone <path>` line per extra slot clone. Capture the final report **before** removing the clone, from the clone's fresh `main` (the bottom and park PRs land there first): `git -C <clone-path> pull -q`, then `AUTOPILOT_REPO_ROOT=<clone-path> autopilot-state.sh final-report > <tmp file>` (Phase 5). Then remove each clone directory with `rm -rf` of the literal path (they are under `/tmp`, which the rm-guard hook allows) and post the saved report to the user. `noop` (already off, or nothing to pause): report the current state and stop.
4. `pause`: `autopilot-state.sh pause` (`noop` if not on: report the state); keep the clone and state; report.
5. `resume`: `autopilot-state.sh resume` prints `dispatch` (go to Phase 2, the cap check, then one cycle now) or `busy` (the interrupted cycle is still finishing: do nothing, its Phase 4 re-reads `on` and arms the next wake) or `noop` (not paused: report).

### Phase 1: on

Run `autopilot-state.sh start`:

- `started` — fresh run; go to Phase 2.
- `dispatch` — already on, a slot is free and the wake is due (the wake fired); go to Phase 2.
- `already-on` — a typed `on` before the next wake is due, or every slot (`max_dop`) is running a cycle: report `already on, next cycle at <next_wake_at>` and stop. Never dispatch, never schedule.
- `busy` — a previous run's cycle is still finishing: report it and do nothing; that cycle's Phase 4 arms the next wake.
- `paused` — report "paused; use /autopilot resume" and stop.

### Phase 2: Cap check

`autopilot-state.sh cap` prints `ok` or `capped:cycles|merges`. On `capped:*`: `autopilot-state.sh record capped`, send its notice kind if not `none` (Phase 4 Notify), then `ScheduleWakeup(<delay capped>, "/autopilot on")` and end the turn. The loop stays on; it re-checks hourly and resumes after the daily rollover.

### Phase 3: Run one cycle

**Slots (`max_dop`).** `max_dop` (default 1) is how many cycles may run at once; slot numbers are 1 to `max_dop`. With `max_dop` 1 everything below is exactly the one-cycle flow, with slot 1 only. With more, one wake may dispatch several cycles (see **Dispatch**). Free slots = slot numbers up to `max_dop` that `autopilot-state.sh slots` does not list as running.

**Dispatch clone** (once per run per slot, reused every cycle). Read `dispatch_clone_path` (slot 1; slot N from `dispatch_clone_paths`); if `null` or missing, create it and record the path in the state file:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
CLONE_PATH="$(bash <skills-root>/autopilot/scripts/autopilot-state.sh clone-path "$REPO_ROOT" --slot <N>)"   # slot 1 when max_dop is 1
[ -d "$CLONE_PATH" ] || git clone --recurse-submodules "$(git -C "$REPO_ROOT" remote get-url origin)" "$CLONE_PATH"
bash <skills-root>/autopilot/scripts/autopilot-state.sh set-clone <N> "$CLONE_PATH"
```

`clone-path` prints `/tmp/autopilot-clone-<repo-name>-<8 hex of sha256(repo root)>` for slot 1 and the same with `-s<N>` appended for slot N (2 and up): distinct working trees and distinct `claimant_id`s per slot, so a task one slot claimed reads as claimed by a peer to the others.

A dirty or mid-rebase leftover: remove the directory and re-run the block. Full clone, never a worktree or shallow; the same path every cycle keeps the same `claimant_id` (`_session/claimant-id.sh`).

**No pick in the dispatcher.** The dispatcher does not walk the queue or keep a skip list; `/drive` takes the top eligible task of `queue.md`. `git -C "$CLONE_PATH" checkout main -q && git -C "$CLONE_PATH" pull -q`, then `autopilot-state.sh prune "$CLONE_PATH"` (drops visit counters of tasks that left `dev/TODO`) and `autopilot-state.sh pickable "$CLONE_PATH"` (a cheap read, no agent; tasks in flight in another slot, and tasks `Blocked by` one, do not count) prints:

- `pick`: `todo-next.sh --skip-gated` finds a task `/drive` may take. Dispatch.
- `drift` (only while no slot is running a cycle): nothing pickable, but `todo-sweep.sh plan` has mechanical findings (untracked task file, stale queue entry, closed-but-queued task); `/drive`'s own Phase 1 sweep fixes them. Dispatch. A drift dispatch that merges nothing ends `idle`/`stuck` and waits out its back-off, so permanent drift costs at most one agent per interval.
- `none`: queue empty, or every queued task gated or parked. Go to Phase 4 `idle` without dispatching.

**Priority is the queue; task files stay clean.**

- Nothing is written to a task file to say why a cycle could not finish it.
- A cycle that ends `NEEDS-ATTENTION` or `STUCK` without advancing the task is a **no-progress visit**: Phase 4 has the task `/bottom`ed (the next cycle takes the next task) and bumps its counter.
- After `max_visits` (default 4) such visits the task is **parked** (`dev/PARKING/`, a `## Parked` section with the last reason); the owner revives it by hand. An advancing visit (merged, split, design PR merged, a claim that led to work) resets the counter.
- `Blocked by T<id>`, `SUPERVISED`, `BLOCKED`, `needs manual` and `sign-off` statuses are still skipped by auto-pick. Task size is never a reason to stall (see **Big tasks**).

**Dispatch.** With `max_dop` 1 (the default): `/drive --auto-selected` (no id: auto-pick, Phase 0 PR drain still runs) via the `Agent` tool (`subagent_type: general-purpose`, no `isolation`) after `autopilot-state.sh busy on "$(autopilot-state.sh top "$CLONE_PATH")"` (the task `/drive` is about to pick; an empty id is ignored); note the `agentId`. The cycle's ledger start line must pass `--flags autopilot` (e.g. `ledger.sh start <n> "autopilot cycle" --flags autopilot`) so the HUD shows `running r<n>` while it runs. Never start a second cycle while one is busy.

**Several slots (`max_dop` above 1).** For each free slot in turn, all in the same reply (one `Agent` call per slot, issued together so they run side by side):

1. Slots beyond the first running cycle need the machine guard: `autopilot-state.sh guard` prints `ok` or `hold <reason>` (free memory under 20 % of the total, or 1-minute load per CPU over 1.5, or a probe that cannot be read). On `hold`: dispatch no more slots this wake, tell the user why (`slot <N> held: <reason>`), run `autopilot-state.sh hold 300 "<reason>"` and end with the Phase 4 `ScheduleWakeup(300, ...)` unless a cycle is about to be dispatched. **One extra slot per wake**: after starting a slot beyond the first, stop filling; if slots are still free, run `autopilot-state.sh hold 120 ramp` and `ScheduleWakeup(120, "/autopilot on")`, so the next guard read includes the new cycle's load. Slot 1 with nothing running is never held.
2. `ID=$(autopilot-state.sh top "$CLONE_PATH")`: the first eligible task that is not in flight in another slot (`top --nth N` = the Nth). An empty id (a `drift` or `none` pickable) means no extra cycle: skip this and every later slot. Never dispatch two slots on one task.
3. `autopilot-state.sh busy on "$ID" --slot <N>` (exit 3 = the task is already in another slot: skip it), then `ledger.sh start <n> "autopilot cycle s<N>" --flags autopilot`, then the `Agent` call for `/drive T<id> --auto-selected` (an explicit id, so no two cycles auto-pick the same task) with that slot's `$CLONE_PATH` in the prompt.

The cycles are independent: each has its own clone, claim, ledger row and report. Counters, daily caps (`cap` counts running cycles, so parallel dispatch cannot overshoot the cycle cap; the merge cap can be exceeded by at most `max_dop` - 1 merges) and the wake timer stay global. The prompt is self-contained: name `$CLONE_PATH`, require `/drive` to run to completion, give Phase 4's classification rules, and add the guardrail and the big-task rule below. A `/todo sweep` park ask (Step B) needs a human: the sub-agent reports it as `STUCK`. **Every bash command for the whole `/drive` run begins `cd "$CLONE_PATH" &&`** (a sub-agent's Bash does not keep `cd` between calls).

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

Wait for the completion notifications; don't poll. Housekeeping (Phase 4) runs as a second small sub-agent after a cycle reports, never in parallel with another housekeeping agent. A failed dispatch or an unparseable report is **Stuck** ("dispatch failed or report unparseable"). An `off`/`pause` arriving during the wait takes priority (Phase 0.1).

### Phase 4: Classify, notify, reschedule

This phase runs once per finished cycle, with that cycle's slot `<N>` (always 1 when `max_dop` is 1). With several cycles finishing close together, handle one completely (classify, visits, housekeeping, `record`) before starting the next; state writes are locked, housekeeping agents run one at a time. First re-read `autopilot-state.sh status`: not `on` means off/pause won while the cycle ran; run `busy off --slot <N>`, record nothing further and schedule nothing.

Write the sub-agent's final message to a temp file and run `autopilot-state.sh classify <file>`: it prints `<outcome> <merged-count> <task-id|-> <reason>` (exit 2 = unparseable, printed as a stuck line). The rules `classify` applies, in this order:

- **progress**: something merged, or a task was `ADVANCED`, and nothing Stuck. Wake in 60 s.
- **waiting**: nothing merged, `WAITING:` reported. Back-off ladder 5, 10, 20, 30 min (capped), using `waiting_count`.
- **stuck**: `/drive` errored, merged and advanced nothing, hit its own Escalation Rules, or its `/address-pr` stopped without merging. Same ladder, using `stuck_count`.
- **bottomed**: the only lines are `NEEDS-ATTENTION`. The stalled task is about to leave the top of the queue, so wake in 60 s; it touches neither `stuck_count`, `waiting_count` nor a notice flag.
- **idle**: no eligible task (Phase 3 `pickable` found none, or `/drive` reported none). Retry every `idle_retry_minutes` (default 32, valid range 30-60).

**Visits (before `record`).** Run these from the owner's repo, not `$CLONE_PATH` (the state file is found from the working directory).

- `autopilot-state.sh plan <file> --fallback <id from busy on>` prints `<task-id><TAB>advanced|stalled<TAB><reason><TAB><source>` per task the report names.
- `advanced`: run `autopilot-state.sh advance <id>` (resets the counter).
- `stalled`: run `autopilot-state.sh visit <id> "<reason>"`, adding `--stuck` when the source is `stuck`. It prints `bottom <n>`, `park <n>` (`n` reached `max_visits`), `skip` (a run of stuck cycles looks like an outage) or `none`.
- Counted: only tasks a report names. A `WAITING` cycle, an unparseable report and a failed dispatch name none; a `STUCK:` line without a task falls back to the `top` id. The count stands even if housekeeping then fails (the task did stall).

**Housekeeping.** When a `visit` printed `bottom` or `park`, dispatch one small sub-agent (`general-purpose`, `busy` still on); its self-contained prompt starts every bash command with `cd "$CLONE_PATH" &&`. Per task, one docs-only PR through the normal gates (pull first; green CI, independent review, `/address-pr <number>`, `gh pr merge --rebase`, never `--admin`):

- Release the claim only if this clone holds it and the status is `In Progress` or `Design` (`task_claim.sh read` shows `claimed_by` equal to `task_claim.sh claimant-id`): `task_claim.sh release T<id> Open`. Never `release-others` (it would free a `Review` task with a live PR).
- `bottom`: `/bottom T<dependant> ... T<id>`, the stalled task last so it stays ahead of its dependants: the tasks it `blocks:` and every open task `Blocked by T<id>` (else sweep Phase 2 moves it back). No visit is counted for them. Add the released task file to the `land.sh` paths. `land.sh` exit 3 or a task already out of `dev/TODO` is success.
- `park`: refuse (do a `bottom`, say why) if an open PR (`gh pr list --search "t<id-digits>"`), a remote branch `t<id-digits>` or an open task `Blocked by T<id>` exists. Else `todo-sweep.sh park T<id>:"<reason>; autopilot visited <n> times without progress"`, `_taskid/epic-links.sh sync`, `git add dev/EPICS`; stage `dev/TODO`, `dev/PARKING`, `dev/EPICS`, `queue.md`. The owner authorized this park; nothing else is parked this way.
- Report per task: `BOTTOMED: T<id> — PR #<n>[; park refused: <why>]`, `BOTTOMED: T<id> — no change (<why>)`, `PARKED: T<id> — PR #<n>` or `HOUSEKEEPING-FAILED: T<id> — <reason>`.

Then:

- `PARKED:` line: run `autopilot-state.sh parked <id> "<reason>"` and notify kind `parked`. A `park refused` line whose `visit` printed `park <n>` with `n` equal to `max_visits`: notify kind `attention` once (later visits stay silent).
- A missing line, a failed agent, `no change` or `park refused` (the task is still on top): record the cycle **stuck** (`bottom/park not landed for <id>`) with `record stuck <merged-count> <task-id> "<reason>"`, so the back-off ladder prevents a 60 s loop. Three such cycles in a row send the `stuck` notice and switch the `--stuck` visit skip on.
- Otherwise run `autopilot-state.sh record <outcome> <merged-count> <task-id> "<reason>"` with the `classify` fields (id `-`: pass `""`); it prints a notice kind or `none` and sets the next wake time. Every `record` takes `--slot <N>` (`record <outcome> <merged> <task> "<reason>" --slot <N>`): it frees that slot only. The wake timer is one global value and the latest write wins, so free slots wait for it.

**Notify** for each non-`none` kind returned: `autopilot-state.sh notify <kind> "<text>"`, one concise bullet list (kind `idle` names the tasks from `parked-list` and says retries are silent; `resumed` says work is flowing again; `stuck` names the task and reason; `waiting` names the PR; `capped` names the cap; `parked` names the task, its last reason and "autopilot visited <n> times without progress"). `notify` tries `/slack --channel dev` and, when the env vars are unset or the post fails, records the notice in the state file (shown by `status` and the HUD); it never errors, so never retry or escalate it.

Then `ScheduleWakeup(delaySeconds: <autopilot-state.sh delay <outcome>>, prompt: "/autopilot on", reason: "autopilot <outcome>")` and end the turn (another slot may still be running: its own Phase 4 runs when it reports). Every wake carries the same prompt; the state file decides whether it dispatches (Phase 1).

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
- **Never loop inside one turn.** One wake dispatches at most the free slots once; the next dispatch is behind a `ScheduleWakeup` boundary.
- **One run per repo, best-effort.** No lock beyond the state file's own write lock, the busy slots and `next_wake_at`; the dispatch clone paths are deterministic per repo and slot. The dispatcher is the only writer of slots.
- **Parallel cycles are opt-in** (`max_dop`, default 1). Each extra slot needs the machine guard; a held slot is retried on the next wake.
- **Idle is not a stop.** Going idle notifies once; retries are silent; new work (`/stage`, `/todo sweep`) is picked up on the next retry.
- **Not `/ccxp`.** `/ccxp` is the ritual-aware orchestrator; this is a plain on/off `/drive` loop.

## Cross-references

- `/drive` — does the selection/implementation/merge work, one cycle per dispatch (`/drive --auto-selected`)
- `/slack` — `notify` posts to `--channel dev` when configured
- `/todo` — `next --skip-gated` and `sweep` plan feed `pickable`; `todo-sweep.sh park` is the park; `/bottom` moves a stalled task to the back of the queue; `/address-pr` — drains and merges PRs
- `hud/` — `AP on/off` band reads `dev/.autopilot-state.json` (`hud/scripts/hud-lib.sh`); with parallel cycles the AP line shows `running r596,r597`
