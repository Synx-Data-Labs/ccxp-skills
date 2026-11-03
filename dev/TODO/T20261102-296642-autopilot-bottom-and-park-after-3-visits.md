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
  - Marker grammar and gate: `todo/scripts/_lib.sh` `todo-needs-human-kind` (lines 38-52) and `todo-gated` (line 59); writer CLI `todo/scripts/needs-human.sh` (126 lines, `kind|mark|clear|list`).
  - Pick filter: `todo/scripts/todo-next.sh` `--skip-needs-human` (lines 11-14, 33-38, 66).
  - Dispatcher helpers: `autopilot-state.sh` `pickable` (412-418), `marked` (405-409), `attention-list` (400-402), the `needs a human` lines in `report` (441-444) and `final-report` (602-607), and the one-time `_ap_migrate` (151-165).
  - Skill text: `autopilot/SKILL.md` Phase 3 "The `needs a human` marker" and the guardrail's "Marking" paragraph, Phase 4 NEEDS-ATTENTION rule; `drive/SKILL.md` "Gated tasks" (lines 28-36), Phase 1 step 2 (line 71), Phase 6 step 3 (line 473) and "Marking an owner-gated task" (lines 636-645); `todo/SKILL.md` lines 60 and 78; `hud/README.md` lines 112-121 and `hud/scripts/hud-lib.sh` lines 367-441.
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
- **What counts as progress** (assumption (owner can change)):
  - A task is `advanced` when the report names it on a `MERGED:` line (implemented and merged) or on the new `ADVANCED: T<id> — <what moved>` line (design PR merged, split into sub-tasks, a claim that led to real work). The sub-agent writes `ADVANCED` for anything that moved the task forward without finishing it, so a long task is never parked while it is making progress.
  - A task is `stalled` when it is named on a `NEEDS-ATTENTION:` line, or as the `last task` of a `STUCK:` line, and is not also `advanced`.
  - Not counted as a visit: a `WAITING:` cycle (a human approval on a PR is pending), a report with no task id, a dispatch failure or an unparseable report (these stay on the existing 5/10/20/30 minute back-off, so the loop cannot spin).
- **Visit counter** (assumption (owner can change): local and gitignored, per the owner's "record how many times"):
  - `dev/.autopilot-state.json` gains `visits` (map task id to count) and `parked` (list of `{id, at, reason, visits}`, last 50). A 5.9.0 state file without them loads unchanged (`// {}` defaults, nothing printed). `start` after `off` carries both over: they describe tasks, not a run.
  - Each increment, reset and park also appends one line to `dev/.autopilot-history.jsonl` (`{ts, outcome: "visit"|"advance"|"park", merged: 0, task, visits}`); `stats` ignores those outcomes so cycle and merged counts do not change.
  - `max_visits` is read from `dev/.autopilot-config.json` (default 3, same positive-integer rule as the other keys).
  - Nothing is written to any task file for a visit. A park necessarily edits the parked task (see below), which is the one allowed exception.
- **Bottom** (assumption (owner can change): the stalled task's claim is released in the same PR). The sub-agent claimed the task, so a bottomed task would stay `claimed_by` the dispatch clone. The housekeeping agent therefore runs `task_claim.sh release-others` (keeps nothing, `In Progress`/`Design` back to `Open`, `Blocked by` and `Review` kept) before landing the PR with `queue.md`. No reason text goes into the task.
- **Park** (assumption (owner can change): no human approval step, the owner's words authorize it): `todo-sweep.sh park T<id>:"<last reason>; autopilot visited <n> times without progress"` then `_taskid/epic-links.sh sync` and `git add dev/EPICS`, one docs-only PR. A task parked this way is listed as `parked by autopilot: T<id> (<slug>) — <reason>` in the next `report`, `idle` notice and `final-report`, so the owner sees it. Reviving is the owner's manual move back (`git mv`, status `Open`, `/stage`), as today. The `parked` entries stay in the state file for the report and the HUD.
- **Retired** (assumption (owner can change): the legacy `needs a human` text in an existing status is still honored by `todo-gated` so the autopilot does not re-visit a task the owner's other job has not cleaned yet; nothing writes, parses or counts it any more):
  - Deleted: `todo/scripts/needs-human.sh`, `tests/needs_human.bats`, `todo-needs-human-kind`, `autopilot-state.sh` `marked`, `attention-list`, `_ap_migrate`.
  - Renamed: `todo-next.sh --skip-needs-human` becomes `--skip-gated` (same semantics, the gate is the pre-5.9.0 status words); `/drive` auto-pick and `pickable` use it.
  - Text removed: autopilot Phase 3 marker paragraph and guardrail "Marking", Phase 4 marker verification; drive "Marking an owner-gated task" (replaced by "report `NEEDS-ATTENTION`, write nothing") and the Phase 6 "never recurses into a marked blocker" clause (Phase 6 recurses into a `Blocked by` blocker again; a blocker that then stalls ends the run `NEEDS-ATTENTION: T<goal>`); todo `status` marker text.
- **Cycle outcomes** (`classify`): a report that only has `NEEDS-ATTENTION` lines is now `progress` with 0 merged (wake in 60 s; the stalled task just left the top of the queue); `STUCK` keeps its back-off ladder and its `stuck` notice, because a stuck cycle may be an outage rather than a task problem; a report with `ADVANCED` and no `STUCK` is `progress`. If the housekeeping agent fails, the cycle is recorded `stuck` ("bottom/park not landed for T<id>") so a failed PR cannot cause a 60 s loop; the counter still bounds it.
- **Notices**: `attention` per cycle is dropped (47 tasks would be 47 posts). A park posts one `parked` notice. `idle` text names the tasks parked by autopilot.
- **HUD** (PR B): `sl-queue-json` stops deriving `decision` and `external` and no longer reads markers. New shape `{total, ready, held, epic, claimed, revisited, parked}`: `held` = a status the autopilot skips (the `todo-gated` words, or `Blocked by` an open task), `revisited` = state `visits` entries that are still queued, `parked` = state `parked` entries since this run's `started_at` (state read only while `on`/`paused`, as today). Band: `queue 44 = 30r 6h 3x` with `Nc`, `Nv`, `Np` appended only when above 0; details: `queue 44 = 30 ready | 6 held | 3 epics` plus `| 2 claimed | 12 revisited | 2 parked` only when above 0. Both stay one line and inside the existing row limits (details already cut with an ellipsis at the terminal width).
- **Worst case** (bounded, not unbounded): each task visited at most `max_visits` times, so N blocked tasks cost up to `3 x N` no-progress cycles. The owner's pointer repo has about 47 such tasks, about 140 no-progress visits at worst. The existing daily caps (24 cycles, 12 merges per day, `autopilot-state.sh:231-232`) spread that over about 6 days; each cycle also lands one small PR. High-priority tasks are not special-cased: the owner pings and drives those personally.
- **Alternatives rejected**:
  - Keep the marker but add a counter: rejected by the owner ("don't put that status in the task file").
  - Counter in the task file frontmatter: it would put loop bookkeeping back into task files and needs a `lint_tasks.py` allowlist change.
  - The sub-agent bottoms and counts: the owner says "the dispatcher", and a crashed sub-agent would then leave the task on top forever.
  - Park without a PR (move the file locally): invisible to other clones, breaks `queue.md` sync.
  - A global `visits` shared via git: the counter is a loop detail, local state is enough and survives no merge conflicts.

## Test plan

- [ ] Unit (bats, `tests/autopilot_state.bats`): `visit` increments, prints `bottom`/`park` at the limit, honors `max_visits` from config (default 3, invalid value falls back), appends history; `advance` resets; `parked` moves the entry; `plan` on reports with MERGED/ADVANCED/STUCK/NEEDS-ATTENTION/WAITING combinations and a report with no task id; 5.9.0 state (no `visits`) loads silently; `start` after `off` carries `visits`/`parked`; `stats` ignores visit lines; `report`/`final-report` list parked entries; `pickable` still `pick|drift|none`; `classify` attention-only is `progress`.
- [ ] Unit (bats, `tests/todo-next.bats`): `--skip-gated` skips the legacy status words and `Blocked by`, default output unchanged, `--skip-needs-human` is a usage error.
- [ ] Unit (bats, `tests/hud_lib.bats`): new queue buckets, `revisited` ignores state ids that are not queued, `parked` counts only this run, state ignored when off.
- [ ] Unit (`hud/pure.test.ts`): parse clamps, band and details strings, singular/plural, widths. Runs under the host's `claude-code/testing` runner, which this repo's CI does not have, so it cannot be run here.
- [ ] Docs: `tests/autopilot_state.bats` SKILL.md case, skill-quality ratchets, `lint-docs.sh`, `lint_tasks.py`, full `bats tests/*.bats` locally.
- [ ] Post-merge, not verifiable here: a live `/autopilot` cycle against a real repo (the dispatcher text is prose, its scripts are unit-tested).

## Done criteria

- [ ] No `needs-human.sh`, `--skip-needs-human`, `marked`, `attention-list` or marker text remains outside journals: `grep` in the implementation PR, and `tests/autopilot_state.bats` ("retired commands").
- [ ] A cycle that ends `NEEDS-ATTENTION`/`STUCK` without advancing yields `bottom` then, at the third visit, `park`: `tests/autopilot_state.bats` (`visit` cases).
- [ ] An advancing cycle resets the counter: `tests/autopilot_state.bats` (`advance`, `plan` cases).
- [ ] The visit limit is configurable and defaults to 3: `tests/autopilot_state.bats` (`max_visits`).
- [ ] No task file is edited to record a reason: `autopilot/SKILL.md` Phase 3/4 text, and no script in `autopilot/scripts` or `todo/scripts` writes a task file except `todo-sweep.sh park`.
- [ ] Parked tasks are reported: `tests/autopilot_state.bats` (`report`, `final-report`).
- [ ] The HUD shows ready and revisited/parked counts without markers: `tests/hud_lib.bats`, `hud/pure.test.ts`.
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
