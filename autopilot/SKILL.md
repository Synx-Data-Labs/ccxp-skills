---
name: autopilot
description: Use when the user explicitly asks to turn the unattended background /drive loop on or off, pause or resume it, or check its status — "/autopilot on", "/autopilot off", "/autopilot pause", "/autopilot resume", "/autopilot status", "/autopilot config"
argument-hint: "on | off | pause | resume | status | config [show | set <key> <value> | reset [<key>]]"
---

While `on`, keep running `/drive` one task after another, using `ScheduleWakeup` to survive without one long turn, until `/autopilot off`. Nothing drivable → notify once, wait, try again. No standup/IPM/retro (that is `/ccxp`'s job). This skill owns the on/off/loop/pause bookkeeping, not selection, implementation or merging. Each cycle's `/drive` runs in a dispatched sub-agent, so context grows by one report per cycle.

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

All state arithmetic lives in `<skills-root>/autopilot/scripts/autopilot-state.sh` (unit-tested in `tests/autopilot_state.bats`); call it instead of editing JSON by hand. One command per call.

- `dev/.autopilot-state.json` (gitignored, schema 2) — the loop's source of truth. Fields: `status` on|paused|off, `started_at`, `paused_at`, counters (`cycle_count`, `merged_count`, `stuck_count`, `waiting_count`, `*_today`), `last_outcome`/`last_task`/`last_stuck_reason`, `next_wake_at`, `busy_since`, `current_task` (the busy cycle's task id, informational; with parallel cycles both mirror the oldest running slot), `slots`, `dispatch_clone_paths`, `last_hold`, notify-once flags, `notices`. Also `holds` and `cursors` (below), local to this machine and carried over `off`/`start`. There is **no skip list and nothing in any task file** that says why a task could not be finished: the queue order is the record of priority (Phase 3).
- Holds (state `holds`, kept over `off`/`start`): `hold-add <T-id> waiting|needs-human|stalled <condition> "<reason>"`, `holds`, `release <T-id>`, `holds-check`. Condition: `until <time>`, `run:<id>`, `pr:<n>`, `file-changed <path>`, `task-left-todo <T-id>`; no hold without both (d152).
- Tier cursors (state `cursors`): `top` picks in the highest tier (`tier:` 1-4, default 3) with a free, not-held task, the last-dispatched task of a tier last; `top --urgent`: tiers 1-2.
- `dev/.autopilot-history.jsonl` (gitignored, append-only) — one `{ts, outcome, merged, task}` line per `record` call (`task` is a task id or `""`; no free text, no secrets). Written by `record` itself (so nothing else logs a merge), a write failure is swallowed and never breaks `record`. It survives `off`/`start`. The state file also keeps `lifetime_started_at`, `lifetime_cycles` and `lifetime_merged`, which `start` carries over (a state from before they existed is seeded from its run counters), so `off` then `start` never resets the lifetime baseline.
- `autopilot-state.sh stats [--json]` — progress over the rolling last 24 h (merged, cycles, stuck, waiting, idle; `capped` ticks are not cycles) and the lifetime average per 24 h (`lifetime_merged / max(1, days since lifetime_started_at)`), with a trend (`up`/`down`/`flat`). The 24 h figures are exact when the log reaches back over the whole window, or when no cycle ran inside it; otherwise (`approx: true`) an estimate: the larger of the log and the state's calendar-day counters (HUD: `~`). The HUD's AP band shows it (`hud/README.md`).
- `dev/.autopilot-config.json` (gitignored, optional) — `{"daily_cycle_cap": 64, "daily_merge_cap": 64, "idle_retry_minutes": 32, "max_dop": 3, "reserved_slots": 2}`. Missing keys use these defaults. `max_dop` (3-16, default **3**): `/drive` cycles at once, `reserved_slots` (0-8, default 2) kept for urgent work.
- This skill must run in the main session: only it can `ScheduleWakeup` and receive `pause`/`off`.

## Workflow

### Phase 0: Status (read-only)

For `status` (and for an unsupported argument): run `autopilot-state.sh report` and relay it. Then add, derived live and never from a cache:

- **Done**: `autopilot-state.sh done` (journal files added since `started_at`, one bullet each; prints "- No tasks merged this run" when empty).
- **Needs your attention**: `autopilot-state.sh holds` (each held task with its kind, reason and release condition), plus a task whose `status:` flags a human-only condition (`SUPERVISED`, a sign-off) and an open PR stuck in a way no skill resolves; apply the filter in Important Notes.

No Slack post, no `ScheduleWakeup`: this phase never touches the loop.

### Phase 0.2: config

The helper validates and writes atomically (mode 600, other keys kept); never edit the JSON by hand.

- `config` / `config show`: `config-show [--json]`, read-only: effective value, `default` or `override`, range, file path.
- `config set <key> <value>`: `config-set`. Keys `daily_cycle_cap`, `daily_merge_cap` (1-1000), `idle_retry_minutes` (30-60), `max_dop` (3-16, default 3), `reserved_slots` (0-8, default 2); a non-negative integer. Exit 2 = refused, nothing written: relay the message. On success relay `config-show`.
- `config reset [<key>]`: `config-reset [<key>]` drops that override or all; unknown keys stay.
- Any other `config` form: show the usage, stop.

Touches neither the state file nor the schedule; a running loop reads the value at its next cap check or wake. No Slack post, no `ScheduleWakeup`.

### Phase 0.1: off / pause / resume

1. `ScheduleWakeup(stop: true)` first, always (for `off` and `pause`).
2. A sub-agent dispatched (mid-cycle: the cycle agents)? `SendMessage` each to commit and push WIP (no PR needed, `/drive` resumes from a pushed branch) and report; wait up to 2 minutes, then `TaskStop`. When they have reported (or been stopped), run `autopilot-state.sh busy off`.
3. `off`: `autopilot-state.sh off` prints `off <clone-path>` (plus a `clone <path>` line per extra slot clone). Capture the final report **before** removing the clone, from the clone's fresh `main`: `git -C <clone-path> pull -q`, then `AUTOPILOT_REPO_ROOT=<clone-path> autopilot-state.sh final-report > <tmp file>` (Phase 5). Then remove each clone directory with `rm -rf` of the literal path (they are under `/tmp`, which the rm-guard hook allows) and post the saved report to the user. `noop` (already off, or nothing to pause): report the current state and stop.
4. `pause`: `autopilot-state.sh pause` (`noop` if not on: report the state); keep the clone and state; report.
5. `resume`: `autopilot-state.sh resume` prints `dispatch` (go to Phase 2, the cap check, then one cycle now) or `busy` (the interrupted cycle is still finishing: do nothing, its Phase 4 re-reads `on` and arms the next wake) or `noop` (not paused: report).

### Phase 1: on

Run `autopilot-state.sh start`:

- `started` — fresh run; go to Phase 2.
- `dispatch` — already on, a slot is free and the wake is due (the wake fired); go to Phase 2.
- `already-on` — a typed `on` before the next wake is due, or every slot is busy: report `already on, next cycle at <next_wake_at>` and stop. Never dispatch. A fired wake with every slot busy re-arms with `wake <seconds> "slots busy"` plus the `ScheduleWakeup`; a typed `on` arms nothing.
- `busy` — a previous run's cycle is still finishing: report it and do nothing; that cycle's Phase 4 arms the next wake. A re-armed wake is recorded first (`wake <seconds> busy`).
- `paused` — report "paused; use /autopilot resume" and stop.

### Phase 2: Cap check

`autopilot-state.sh cap` prints `ok` or `capped:cycles|merges`. On `capped:*`: `autopilot-state.sh record capped`, send its notice kind if not `none` (Phase 4 Notify), then `ScheduleWakeup(<delay capped>, "/autopilot on")` and end the turn. The loop stays on; it re-checks hourly and resumes after the daily rollover.

### Phase 3: Run one cycle

**Dispatch clone** (once per run, reused every cycle; one per slot). Read `dispatch_clone_path`; if `null` or missing, create it and record the path in the state file:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
CLONE_PATH="$(bash <skills-root>/autopilot/scripts/autopilot-state.sh clone-path "$REPO_ROOT")"
[ -d "$CLONE_PATH" ] || git clone --recurse-submodules "$(git -C "$REPO_ROOT" remote get-url origin)" "$CLONE_PATH"
```

`clone-path` prints `/tmp/autopilot-clone-<repo-name>-<8 hex of sha256(repo root)>`.

A dirty or mid-rebase leftover: remove the directory and re-run the block. Full clone, never a worktree or shallow; the same path every cycle keeps the same `claimant_id` (`_session/claimant-id.sh`).

**No pick in the dispatcher.** The dispatcher does not walk the queue or keep a skip list; `autopilot-state.sh top` names the task (tier, cursor, holds) and `/drive` is given its id. `git -C "$CLONE_PATH" checkout main -q && git -C "$CLONE_PATH" pull -q`, then `autopilot-state.sh holds-check "$CLONE_PATH"` (releases the holds whose condition is met), `autopilot-state.sh prune "$CLONE_PATH"` (drops counters and holds of tasks that left `dev/TODO`) and `autopilot-state.sh pickable "$CLONE_PATH"` (a cheap read, no agent) prints:

- `pick`: `todo-next.sh --skip-gated` finds a task `/drive` may take. Dispatch.
- `drift`: nothing pickable, but `todo-sweep.sh plan` has mechanical findings (untracked task file, stale queue entry, closed-but-queued task); `/drive`'s own Phase 1 sweep fixes them. Dispatch. A drift dispatch that merges nothing ends `idle`/`stuck` and waits out its back-off, so permanent drift costs at most one agent per interval.
- `none`: queue empty, or every queued task gated or held. Go to Phase 4 `idle` without dispatching.

**Priority is the queue; task files stay clean.**

- Nothing is written to a task file to say why a cycle could not finish it, and `queue.md` is never reordered by the loop.
- A cycle that ends `NEEDS-ATTENTION`, `STUCK` or `WAITING` creates a recorded **hold** (Phase 4): a kind, a reason and one release condition (d152). `top` and `pickable` pass over held tasks until `holds-check` releases them; the tier cursor (Helper and files) moves on to the next task. No PR is opened for a hold.
- `Blocked by T<id>`, `SUPERVISED`, `BLOCKED`, `needs manual` and `sign-off` statuses are still skipped by auto-pick. Task size is never a reason to stall (see **Big tasks**).

**Dispatch** `/drive T<id> --auto-selected` via the `Agent` tool (`subagent_type: general-purpose`, no `isolation`), where `ID=$(autopilot-state.sh top "$CLONE_PATH")` (tiers, cursor and holds decide it; an empty id on a `drift` pickable means bare `/drive --auto-selected`, whose Phase 0 PR drain and sweep still run) after `autopilot-state.sh busy on "$ID"`; note the `agentId`. Its ledger start line passes `--flags autopilot` (HUD `running r<n>`). Never start a second cycle while one is busy. The prompt is self-contained: name `$CLONE_PATH`, require `/drive` to run to completion, give Phase 4's classification rules, and add the guardrail and the big-task rule below. A `/todo sweep` park ask (Step B) needs a human: the sub-agent reports it as `STUCK`. **Every bash command for the whole `/drive` run begins `cd "$CLONE_PATH" &&`** (a sub-agent's Bash does not keep `cd` between calls).

**Parallel or urgent:** `<skills-root>/autopilot/parallel.md`.

**Eligibility guardrail (in the prompt).** Before claiming anything, `/drive` reads the design. Build, implementation and release-engineering work is eligible and runs end to end through the normal `/drive` gates, **including real runs**: dispatching real build workflows, pushing images or packages to the team's registries or artifact stores, uploading artifacts, tagging release candidates. Real runs follow the task's own done-criteria and the repo's runbooks. If the design calls for any of the following, it must stop and answer `NEEDS-ATTENTION: T<id> — <reason>`: (a) a customer-visible post or announcement, or a message sent to a third party; (b) an action or contact toward HashData or any upstream project; (c) spending money or signing up for a paid service; (d) installing software that changes the owner's machine state outside the repo/clone; (e) access to an owner account or credentials the sub-agent does not have; (f) an open owner decision the task text leaves unresolved; (g) deleting registry artifacts (the owner approves the exact list first); (h) final customer-facing release promotion or app-store submission (a push to a registry or repo that customers consume counts as (h); a tag is allowed only when the workflow it triggers stays inside the permitted runs). Task size, estimation or being an umbrella is not on this list. For (f), a sub-task may be filed for the open question, but the agent must not guess the answer. **Stopping.** On any of (a) to (h) answer `NEEDS-ATTENTION: T<id> — <reason>`: write nothing to the task file to say why (the dispatcher holds the task). If a design PR, a split, a pushed branch, an open PR or real work landed before the stop, also report `ADVANCED:` for it (see the format below); `ADVANCED` is only for work that landed in this run, never for work from an earlier run. When `/drive` recursed into a `Blocked by` blocker (Phase 6) and that blocker stalls, report `NEEDS-ATTENTION: T<blocker>`; the goal keeps its `Blocked by` status. Existing merge gates stay: green CI with all required checks finished, independent review posted on the PR, `gh pr merge --rebase`, never `--admin` or a bypass.

**Big tasks (in the prompt).** There is no size limit. If the task is too big to finish in one run (e.g. estimation 5, or an umbrella), the sub-agent does not stop or skip: it breaks the task into small sub-tasks (estimation 1-2 each, a bounded number per cycle, about 5; a sub-task that is itself too big may split again only once), files them with the repo's normal task flow (`/new-task`, or the template plus `_taskid/new.sh`), enqueues them right before the original (give each sub-task `blocks: T<original-id>` in its frontmatter and run `/stage <sub-id>`, which inserts it immediately before the queued original; or, for one already queued, `/top <sub-id> --before <original-id>`; queue order is enough, so leave the original's `status:` alone, because a `Blocked by` status makes `eligible` refuse it), lands the split as one small docs-only PR through the normal gates, then `/drive`s the first sub-task end to end in the same run. It reports the split (sub-task ids and titles) before the MERGED/STUCK lines. A task claimed by another live session is still not taken over.

End the sub-agent's final message in exactly this format:

```
MERGED: T<id> (<slug>) — PR #<n>[; runs: <run/registry URLs>]      (one line per merged task; omit if none; list any real build/publish/push run URLs)
STUCK: <short reason> — last task T<id> (<slug>)[; runs: <URLs>]   (list anything already published; only if it stopped without merging or hit its own Escalation Rules)
ADVANCED: T<id> — <what moved>        (a task moved forward without being finished: a design PR merged, a split landed, a branch pushed or a PR opened, work that continues next cycle; never for a claim alone; omit if none)
NEEDS-ATTENTION: T<id> — <reason>     (only per the guardrail above)
WAITING: <what is pending>            (only address-pr's wait-for-approval tier, a human's formal approval; CI-in-progress is never this)
```

Wait for the completion notification; don't poll. A failed dispatch or an unparseable report is **Stuck** ("dispatch failed or report unparseable"). An `off`/`pause` arriving during the wait takes priority (Phase 0.1).

### Phase 4: Classify, notify, reschedule

Once per finished cycle (`autopilot/parallel.md`). First re-read `autopilot-state.sh status`: not `on` means off/pause won while the cycle ran; run `busy off`, record nothing further and schedule nothing.

Write the sub-agent's final message to a temp file and run `autopilot-state.sh classify <file>`: it prints `<outcome> <merged-count> <task-id|-> <reason>` (exit 2 = unparseable, printed as a stuck line). The rules `classify` applies, in this order:

- **progress**: something merged, or a task was `ADVANCED`, and nothing Stuck. Wake in 60 s.
- **waiting**: nothing merged, `WAITING:` reported. Back-off ladder 5, 10, 20, 30 min (capped), using `waiting_count`.
- **stuck**: `/drive` errored, merged and advanced nothing, hit its own Escalation Rules, or its `/address-pr` stopped without merging. Same ladder, using `stuck_count`.
- **bottomed** (the outcome name stays; the cycle ends in a hold): the only lines are `NEEDS-ATTENTION`. The held task is out of the pick, so wake in 60 s; it touches neither `stuck_count`, `waiting_count` nor a notice flag.
- **idle**: no eligible task (Phase 3 `pickable` found none, or `/drive` reported none). Retry every `idle_retry_minutes` (30-60).

**Holds (before `record`).** Run from the owner's repo, not `$CLONE_PATH` (the state file is found from the working directory): `autopilot-state.sh hold-report <file> --fallback <id from busy on> --repo "$CLONE_PATH"` turns the report into holds and prints `held <id> <kind>` per hold or `skip <id>`.

- `NEEDS-ATTENTION` gives `needs-human` (released when the task file changes, else after 24 h), `STUCK` gives `stalled` (after 2 h), a `WAITING` report gives `waiting` on the `busy on` task (after 1 h); `skip` is a run of stuck cycles (`stuck_count` 3 or more, likely an outage, not the task).
- An advanced task (merged, split, design PR merged, a claim that led to work) gets no hold. A report naming no task, an unparseable report and a failed dispatch hold nothing.
- No `/bottom`, no `queue.md` edit, no housekeeping agent or PR. The owner or `/todo sweep` still reorder the queue; `autopilot-state.sh holds` lists the holds and `release <id>` frees one by hand. The held task's claim stays until this clone's next claim runs `release-others` (it returns to `Open` there).
- Then run `autopilot-state.sh record <outcome> <merged-count> <task-id> "<reason>"` with the `classify` fields (id `-`: pass `""`); it prints a notice kind or `none` and sets the next wake time.

**Notify** for each non-`none` kind returned: `autopilot-state.sh notify <kind> "<text>"`, one concise bullet list (kind `idle` names the held tasks from `holds` and says retries are silent; `resumed` says work is flowing again; `stuck` names the task and reason; `waiting` names the PR; `capped` names the cap). `notify` tries `/slack --channel dev` and, when the env vars are unset or the post fails, records the notice in the state file (shown by `status` and the HUD); it never errors, so never retry or escalate it.

Then `ScheduleWakeup(delaySeconds: <autopilot-state.sh delay <outcome>>, prompt: "/autopilot on", reason: "autopilot <outcome>")` and end the turn. Every wake carries the same prompt; the state file decides whether it dispatches (Phase 1).

**Never arm a wake without recording it.** Each `ScheduleWakeup` follows, in the same step, a state write: `record` (Phases 2 and 4), `hold <s> <reason>` (guard hold, ramp) or `wake <s> [reason]` (an idle or busy re-arm). Otherwise `next_wake_at` goes stale and the HUD reports a stall.

### Phase 5: Final report (on `off`)

After `autopilot-state.sh off` (and before the clone is removed, see Phase 0.1), run `autopilot-state.sh final-report` (with `AUTOPILOT_REPO_ROOT=<clone-path>`) and post its output unchanged (it also serves as the `off` notice text for `notify`). Append to "Needs your attention" any open PR stuck beyond what a skill resolves (not derivable from state). The template it prints:

```
Autopilot run: <elapsed> elapsed — stopped: user-requested

Done:
- Merged T<id> (<slug>) — PR #<n>
(one bullet per merged task this run, from the `done` journal scan; "- No tasks merged this run" if none)

Needs your attention:
- <held tasks (from `holds`), stuck tasks, PRs stuck beyond any skill>
(or "- Nothing outstanding")
```

Every `T<id>`/`PR #<n>` carries a short slug (bare id if it cannot be recovered).

## Important Notes

- **Needs-your-attention filter**: only items no skill can resolve unattended. Exclude `Blocked by T{id}` and an open PR with routine CI/review/rebase work (drained by the next `/drive` Phase 0). Include `holds` entries (`needs-human` and `stalled`), `last_outcome == "stuck"`, and tasks whose `status:` names a human-only condition.
- **Never loop inside one turn.** One cycle (per slot) is exactly one `ScheduleWakeup` boundary.
- **One run per repo, best-effort.** No lock beyond the state file's write lock, the busy marks and `next_wake_at`.
- **Idle is not a stop.** Going idle notifies once; retries are silent; new work (`/stage`, `/todo sweep`) is picked up on the next retry.

## Cross-references

- `/drive` — does the selection/implementation/merge work, one cycle per dispatch (`/drive T<id> --auto-selected`)
- `/slack` — `notify` posts to `--channel dev`
- `/todo` — `next --skip-gated` and `sweep` plan feed `pickable`; `/address-pr` — drains and merges PRs
- `hud/` — `AP on/off` band reads `dev/.autopilot-state.json` (`hud/scripts/hud-lib.sh`)
