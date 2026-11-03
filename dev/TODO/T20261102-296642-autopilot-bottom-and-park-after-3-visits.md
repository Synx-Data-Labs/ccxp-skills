---
status: Design
estimation: 3
source: conversation 2026-11-02 (owner's redesign of the 5.9.0 autopilot, T20261102-261809)
related: T20261102-261809
description: autopilot drives from the top of queue.md; a task it cannot advance is /bottom'ed and parked after 3 visits; no status marker in task files
claimed_by: cc1-ecc09c93:350ac6fa233273b6
claimed_role: interactive
scheduled: 2026-11-02
---

# T20261102-296642: autopilot: drive from the top of queue.md; a no-progress task is /bottom'ed and parked after 3 visits (no status marker in task files)

## TLDR

- **Type**: feature
- **Problem**: the 5.9.0 autopilot records "why blocked" as a `needs a human` suffix inside each task's `status:` line, so task files carry loop bookkeeping and the loop needs a marker parser, a writer CLI and a pick filter.
- **Solution**: the autopilot always drives the top eligible task of `queue.md`; when a cycle ends `NEEDS-ATTENTION` or `STUCK` without advancing that task, the dispatcher `/bottom`s it and bumps a local visit counter; the third no-progress visit parks it. Task files are never edited to record a reason.
- **Scope**: two implementation PRs after this design (A: scripts, tests and skill text; B: HUD), both docs-heavy, no release or version bump.

## Problem

- Owner's words (2026-11-02), verbatim:
  > here is my design, don't put that status in the task file. I want the autopilot to be able to drive the task as much as possible. Since queue.md is the record of priority, if a task indeed blocked (by human or not), then /bottom the task, and continue move to the next. We can record how many times the /autopilot visited the task, and if we already visited 3 times, and still cannot push the task forward, we can park them. I don't worry high priority tasks, since if it's high priority, I will ping you more often, and will drive them personally.
- Evidence (verified 2026-11-02 on `main` at `f1194c0`) of what 5.9.0 (T20261102-261809, PRs #545 to #548) put in place and this task retires:
  - Marker grammar and gate: `todo/scripts/_lib.sh` `todo-needs-human-kind` (lines 42-55) and `todo-gated` (61-63); writer CLI `todo/scripts/needs-human.sh` (126 lines, `kind|mark|clear|list`).
  - Pick filter: `todo/scripts/todo-next.sh` `--skip-needs-human` (lines 11-17, 33, 69).
  - Dispatcher helpers: `autopilot-state.sh` `pickable` (412-418), `marked` (405-409), `attention-list` (400-402), the `needs a human` lines in `report` (441-444) and `final-report` (602-607), and the one-time `_ap_migrate` (151-165).
  - Skill text: `autopilot/SKILL.md` Phase 3 "The `needs a human` marker" and the guardrail's "Marking" paragraph, Phase 4 NEEDS-ATTENTION rule; `drive/SKILL.md` "Gated tasks" (lines 30-36), Phase 1 step 2 (line 71), Phase 6 step 3 (line 473) and "Marking an owner-gated task" (lines 638-645); `todo/SKILL.md` lines 60 and 78; `hud/README.md` lines 112-121 and `hud/scripts/hud-lib.sh` lines 367-441.
- Impact: every blocked task needs a docs PR that edits the owner's task file, the task files of the owner's pointer repo carry about 47 such suffixes, and a task blocked by a marked task is never recursed into. The owner wants none of it.

## Context

- Priority is a task's position in `dev/TODO/queue.md` (`lifecycle.md`); `/bottom` (`bottom/scripts/bottom.sh`, via `_queue/queue-op.sh`) moves a task to the back and lands a docs-only PR through the normal gates. No other state is needed to deprioritize.
- Parking already exists as `todo/scripts/todo-sweep.sh park ID:REASON` (`todo-sweep.sh:327-362`): sets `status: Parked`, appends `## Parked (date)` with the reason, `git mv`s to `dev/PARKING/`, drops the queue line; `/todo` Step B (`todo/SKILL.md:183`) wraps it with an approval step that this design replaces, for the autopilot only, by the owner's standing words above.
- The autopilot already keeps local, gitignored loop state in `dev/.autopilot-state.json` (schema 2) plus an append-only `dev/.autopilot-history.jsonl` (`autopilot-state.sh:64-66`) and daily caps `daily_cycle_cap` 24, `daily_merge_cap` 12 (`:231-232`). The visit counter belongs there, next to the other loop bookkeeping.
- Statuses that exist for other reasons stay as they are before 5.9.0: `Blocked by T<id>` (which `/drive` recurses into), `SUPERVISED`, `BLOCKED`, `needs manual`, `sign-off`. `todo-gated` already matches exactly these plus the marker.

## Solution

- **Cycle** (the dispatcher is `autopilot/SKILL.md` Phase 3 and 4; the scripts are unit-tested):
  1. Pull the dispatch clone, `autopilot-state.sh pickable` (`pick|drift|none`, unchanged contract), dispatch `/drive --auto-selected`, which takes the top eligible task of `queue.md`.
  2. Phase 4 writes the sub-agent's report to a file and runs the new `autopilot-state.sh plan <file>`, which prints one `<task-id><TAB>advanced|stalled<TAB><reason>` line per task the report names.
  3. `advanced` runs `autopilot-state.sh advance T<id>` (counter reset to 0). `stalled` runs `autopilot-state.sh visit T<id> "<reason>"`, which increments the counter, appends a history line and prints `bottom <n>` or `park <n>` (`park` when `n >= max_visits`).
  4. The dispatcher dispatches one small housekeeping sub-agent (the dispatcher itself must not carry the PR loop in its context) that runs `/bottom T<id>` for each `bottom` task and the park procedure below for each `park` task, each as its own docs-only PR through the normal gates (green CI, independent review, `gh pr merge --rebase`, never `--admin`). Then `autopilot-state.sh parked T<id> "<reason>"` records the park.
  5. Next cycle picks the next task. Idle only when `pickable` says `none` (queue empty, or every queued task gated or parked).
- **What counts as progress** (assumption (owner can change); it is the sub-agent's self-report, backed by two deterministic safety nets below):
  - A task is `advanced` when the report names it on a `MERGED:` line (implemented and merged) or on the new `ADVANCED: T<id> — <what moved>` line (design PR merged, split into sub-tasks, a claim that led to real work, **or a branch pushed / PR opened for it**). The sub-agent writes `ADVANCED` for anything that moved the task forward without finishing it, so a long task is not parked while it makes progress.
  - A task is `stalled` when it is named on a `NEEDS-ATTENTION:` line, or as the `last task` of a `STUCK:` line, and is not also `advanced`.
  - A `STUCK` stall only counts while fewer than 3 cycles in a row ended `stuck` (`stuck_count < 3`): a red `main` or a CI outage ends many cycles `STUCK` on different tasks, and counting those would bottom and park healthy tasks in bulk. From the third consecutive `stuck` the visit is skipped (`visit --stuck` prints `skip`), nothing is bottomed, and the existing `stuck` notice and 5/10/20/30 minute back-off tell the owner. `NEEDS-ATTENTION` stalls always count (the sub-agent says a task needs a human or something else it cannot do).
  - A `STUCK` without a `last task` names the task the dispatcher recorded before dispatch (`busy on T<id>` from `autopilot-state.sh top`, the first task `todo-next.sh --skip-gated` lists); an unparseable report or a failed dispatch counts for no task (it is not the task's fault) and stays on the back-off ladder.
  - Not counted as a visit: a `WAITING:` cycle (a human approval on a PR is pending).
  - A blocker recursion (`/drive` Phase 6) that stalls reports `NEEDS-ATTENTION: T<blocker>` (the task it recursed into); the goal keeps its `Blocked by T<blocker>` status, which auto-pick already skips, so the blocker is the task that is bottomed and counted. Sweep Phase 2 moves a blocker back ahead of the task it blocks (`todo-sweep.sh:141-154`), so a bottomed blocker can sit near the top again: it is still counted on each visit and parked at the limit.
- **Visit counter** (assumption (owner can change): local and gitignored, per the owner's "record how many times"):
  - `dev/.autopilot-state.json` gains `visits` (map task id to count) and `parked` (list of `{id, at, reason, visits}`, last 50). Counters of tasks that were closed or parked by someone else are never read again (the HUD counts only queued ids) and are dropped when the task is parked or advances. A 5.9.0 state file without them loads unchanged (`// {}` defaults, nothing printed). `start` after `off` carries both over: they describe tasks, not a run.
  - Each increment, reset and park also appends one line to `dev/.autopilot-history.jsonl` (`{ts, outcome: "visit"|"advance"|"park", merged: 0, task, visits}`); `stats` ignores those outcomes so cycle and merged counts do not change.
  - `max_visits` is read from `dev/.autopilot-config.json` (default 3, same positive-integer rule as the other keys).
  - Nothing is written to any task file for a visit. A park necessarily edits the parked task (see below), which is the one allowed exception.
- **Bottom** (assumption (owner can change)): `/bottom T<id>` in the dispatch clone, one docs-only PR per task. The same PR also (1) releases the stalled task's claim when this clone holds it and it is `In Progress`/`Design` (`task_claim.sh release T<id> Open`, never `release-others`, so a `Review` task with a live PR keeps its claim), so a bottomed task is not left `claimed_by` the dispatch clone, and the PR path list passed to `land.sh` therefore includes the task file; and (2) bottoms the tasks the stalled one `blocks:` (a split sub-task's original), without counting a visit for them, because queue order alone put the sub-task ahead of its original and the original must not become the top pick the moment the sub-task is bottomed. No reason text goes into any file. `land.sh` exit 3 (task already last, nothing to land) counts as success.
- **Park** (assumption (owner can change): no human approval step, the owner's words authorize it): `todo-sweep.sh park T<id>:"<last reason>; autopilot visited <n> times without progress"` (after the claim release above, since `park` keeps `claimed_by`), then `_taskid/epic-links.sh sync` and `git add dev/EPICS`, one docs-only PR. **Refused, and bottomed instead, when** (a) an open PR or a remote branch `t<id-digits>` exists for the task (in-flight work), or (b) another open task has status `Blocked by T<id>` (sweep Phase 2 would auto-unblock it once the blocker leaves `dev/TODO`). The refused case reports `BOTTOMED` with the reason and records no park. A parked task is listed as `parked by autopilot: T<id> (<slug>) — <reason>` in the next `report`, `idle` notice and `final-report`, so the owner sees it. Reviving is the owner's manual move back (`git mv`, status `Open`, `/stage`), as today; its counter was dropped at park time, so it starts from 0. The `parked` entries stay in the state file for the report and the HUD.
- **Retired** (assumption (owner can change): the old `needs a human` text is no longer a gate. Nothing writes, parses or honors it; the five pre-5.9.0 words `Blocked by`, `SUPERVISED`, `BLOCKED`, `needs manual`, `sign-off` stay gated exactly as before. Until the owner's separate cleanup removes the old suffixes from his pointer repo, those tasks are ordinary tasks to the autopilot and are visited like any other):
  - Deleted: `todo/scripts/needs-human.sh`, `tests/needs_human.bats`, `todo-needs-human-kind`, `autopilot-state.sh` `marked`, `attention-list`, `_ap_migrate`.
  - Renamed: `todo-next.sh --skip-needs-human` becomes `--skip-gated` (same semantics, the gate is the pre-5.9.0 status words); `/drive` auto-pick and `pickable` use it.
  - Text removed: autopilot Phase 3 marker paragraph and guardrail "Marking", Phase 4 marker verification; drive "Marking an owner-gated task" (replaced by "report `NEEDS-ATTENTION`, write nothing") and the Phase 6 "never recurses into a marked blocker" clause (Phase 6 recurses into a `Blocked by` blocker again; a blocker that then stalls ends the run `NEEDS-ATTENTION: T<goal>`); todo `status` marker text.
- **Cycle outcomes** (`classify`, `record`): a report that only has `NEEDS-ATTENTION` lines is the new outcome `bottomed` (a cycle that counts toward the daily cap, wakes in 60 s because the stalled task just left the top, and touches neither `stuck_count`, `waiting_count` nor any notified flag, so it neither fakes progress, fires `resumed`, nor resets the stuck back-off); `STUCK` keeps its back-off ladder and `stuck` notice; a report with `ADVANCED` and no `STUCK` is `progress`. If the housekeeping agent fails, the cycle is recorded `stuck` ("bottom/park not landed for T<id>") so a failed PR cannot cause a 60 s loop; the counter still bounds it.
- **Notices**: `attention` per cycle is dropped (47 tasks would be 47 posts). A park posts one `parked` notice. `visit`, `advance`, `plan`, `parked` run in the owner's repo (the state file is found from the working directory); only the housekeeping agent works in the dispatch clone. `/autopilot off` and `pause` stop the housekeeping agent like the cycle agent (Phase 0.1 step 2). `idle` text names the tasks parked by autopilot.
- **HUD** (PR B): `sl-queue-json` stops deriving `decision` and `external` and no longer reads markers. New shape `{total, ready, held, epic, claimed, revisited, autoparked}`: `held` = a status the autopilot skips (the `todo-gated` words, or `Blocked by` an open task), `revisited` = state `visits` entries that are still queued, `autoparked` = state `parked` entries since this run's `started_at` (named so it cannot be read as the job ledger's `parked N`) (state read only while `on`/`paused`, as today). Band: `queue 44 = 30r 6h 3x` with `Nc`, `Nv`, `Na` (claimed, revisited, auto-parked) appended only when above 0; details: `queue 44 = 30 ready | 6 held | 3 epics` plus `| 2 claimed | 12 revisited | 2 auto-parked` only when above 0. `revisited` counts a visit entry with a count above 0 whose task is still queued. Both stay one line and inside the existing row limits (details already cut with an ellipsis at the terminal width).
- **Worst case** (a cost estimate, bounded by the visit limit and spread by the caps): each task is visited at most `max_visits` times, so N blocked tasks cost up to `3 x N` no-progress cycles, each with a small bottom PR (a park adds one PR). The owner's pointer repo has about 47 such tasks, about 140 visits at worst. The existing daily caps (24 cycles, 12 merges per day, `autopilot-state.sh:231-232`) spread that over about 6 days, but they are shared with productive cycles: a day full of stalls starves real work until the stalled tasks reach the bottom or are parked, and the owner can raise `daily_cycle_cap`. High-priority tasks are not special-cased: the owner pings and drives those personally.
- **Alternatives rejected**:
  - Keep the marker but add a counter: rejected by the owner ("don't put that status in the task file").
  - Counter in the task file frontmatter: it would put loop bookkeeping back into task files and needs a `lint_tasks.py` allowlist change.
  - The sub-agent bottoms and counts: the owner says "the dispatcher", and a crashed sub-agent would then leave the task on top forever.
  - Park without a PR (move the file locally): invisible to other clones, breaks `queue.md` sync.
  - A global `visits` shared via git: the counter is a loop detail, local state is enough and survives no merge conflicts.

## Test plan

- [ ] Unit (bats, `tests/autopilot_state.bats`): `visit` increments, prints `bottom`/`park` at the limit, honors `max_visits` from config (default 3, invalid value falls back), appends history; `advance` resets; `parked` moves the entry; `plan` on reports with MERGED/ADVANCED/STUCK/NEEDS-ATTENTION/WAITING combinations and a report with no task id; 5.9.0 state (no `visits`) loads silently; `start` after `off` carries `visits`/`parked`; `stats` ignores visit lines; `report`/`final-report` list parked entries; `pickable` still `pick|drift|none`; `classify` attention-only is `bottomed`, `record bottomed` leaves `stuck_count` and notices alone; `visit --stuck` skips from `stuck_count >= 3`; `plan` with a STUCK that has no task id, malformed ids, ADVANCED plus STUCK on one task; `top` names the first pickable task.
- [ ] Unit (bats, `tests/todo-next.bats`): `--skip-gated` skips the legacy status words and `Blocked by`, default output unchanged, `--skip-needs-human` is a usage error.
- [ ] Unit (bats, `tests/hud_lib.bats`): new queue buckets, `revisited` ignores state ids that are not queued, `parked` counts only this run, state ignored when off.
- [ ] Unit (`hud/pure.test.ts`): parse clamps, band and details strings, singular/plural, widths. Runs under the host's `claude-code/testing` runner, which this repo's CI does not have, so it cannot be run here.
- [ ] Housekeeping (the bottom and park PRs, the park refusals, `land.sh` exit 3) is prose run by a sub-agent and is not unit-testable: the SKILL.md text case pins its wording, and a live `/autopilot` run is the post-merge check below.
- [ ] Docs: `tests/autopilot_state.bats` SKILL.md case, skill-quality ratchets, `lint-docs.sh`, `lint_tasks.py`, full `bats tests/*.bats` locally.
- [ ] Post-merge, not verifiable here: a live `/autopilot` cycle against a real repo (the dispatcher text is prose, its scripts are unit-tested).

## Done criteria

- [ ] No script writes, parses or gates on the `needs a human` marker and no skill text tells anyone to: `todo/scripts/needs-human.sh` and `tests/needs_human.bats` are gone, `grep` over `autopilot/`, `drive/`, `todo/` and `hud/` finds the text only in retirement notes; `tests/autopilot_state.bats` ("retired commands", "no script writes a marker"). Unrelated uses of the phrase in other tests (parser robustness in `actions/sync-tasks/test_sync.py`, `repo-conventions/scripts/test_lint_tasks.py`, claim fixtures) stay.
- [ ] A cycle that ends `NEEDS-ATTENTION`/`STUCK` without advancing yields `bottom` then, at the third visit, `park`: `tests/autopilot_state.bats` (`visit` cases).
- [ ] An advancing cycle resets the counter: `tests/autopilot_state.bats` (`advance`, `plan` cases).
- [ ] The visit limit is configurable and defaults to 3: `tests/autopilot_state.bats` (`max_visits`).
- [ ] No task file records why a task was not finished: nothing in `autopilot/scripts` writes a task file; the only task-file edits are the claim release (`task_claim.sh release`) and the park (`todo-sweep.sh park`, status `Parked` plus the `## Parked` section): `autopilot/SKILL.md` Phase 3/4 text and `tests/autopilot_state.bats` (SKILL.md case).
- [ ] Parked tasks are reported: `tests/autopilot_state.bats` (`report`, `final-report`).
- [ ] The HUD shows ready and revisited/auto-parked counts without markers: `tests/hud_lib.bats` (run in CI); `hud/pure.test.ts` is updated but needs the host's `claude-code/testing` runner, which this repo's CI lacks, so it is checked locally with a shim or reported as not run.
- [ ] Tests green in CI (`bats`, `lint-tasks`, `skill-quality`, `sync-tasks`, Markdown Lint).

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `autopilot/scripts/autopilot-state.sh` | 2-56, 104-121, 146-165, 335-374, 400-418, 434-449, 462-508, 583-630 | usage, fresh state, migration, `record`, marker helpers, `report`, `classify`, `final-report`, dispatch table |
| `autopilot/SKILL.md` | 26-29, 36-39, 79-91, 93-116, 120-140 | state fields, status, Phase 3/4/5, notes |
| `todo/scripts/_lib.sh`, `todo/scripts/todo-next.sh` | 31-62, 11-14 / 33-38 / 66 | drop the marker parser, rename the flag |
| `todo/scripts/needs-human.sh`, `tests/needs_human.bats` | all | deleted |
| `drive/SKILL.md` | 28-36, 71, 473, 636-645 | gated text, auto-pick flag, Phase 6, escalation |
| `todo/SKILL.md` | 60, 78 | status grammar and `next` flags |
| `hud/scripts/hud-lib.sh`, `hud/model.ts`, `types/index.d.ts`, `hud/README.md` | 367-441 / 109-116, 480-500 / 81 / 112-121, 168-171 | queue buckets, band and details, docs |
| `tests/autopilot_state.bats`, `tests/todo-next.bats`, `tests/hud_lib.bats`, `hud/pure.test.ts` | per case | rewire and add cases |
| `_session/task_claim.sh`, `actions/sync-tasks/test_sync.py`, `repo-conventions/scripts/test_lint_tasks.py`, `tests/task_claim.bats` | 166 / 484, 615-624 / 71 / 97-160 | only mention the phrase in fixtures; left alone |
