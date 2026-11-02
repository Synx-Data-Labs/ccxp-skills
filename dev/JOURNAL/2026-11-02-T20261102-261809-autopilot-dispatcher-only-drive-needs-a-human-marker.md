---
status: Done
estimation: 1
source: conversation 2026-11-02 (owner approved the redesign proposal, "n83 yes")
related: [T20261102-902081, T20261028-151063, T20260922-195629, T20261006-391349, T20260930-132964]
description: autopilot only calls /drive each cycle; owner-gated tasks carry a "needs a human" marker in their own file instead of a per-clone skip list
claimed_by:
claimed_role:
scheduled: 2026-11-02
---

# T20261102-261809: autopilot: dispatcher only calls /drive; owner-gated tasks carry a "needs a human" marker in the task file (no skip list)

## TLDR

- **Type**: feature
- **Problem**: autopilot gates owner-only tasks with a per-clone, daily-wiped `skip_ids` list, so every rollover re-dispatches a ~50k-token `/drive` agent per gated task (`autopilot/scripts/autopilot-state.sh:195`, `autopilot/SKILL.md` Phase 3).
- **Solution**: the gate moves into the task file as a status suffix, em dash then `needs a human [<kind>]: <reason>`; `todo-next.sh --skip-needs-human` and `eligible` share one parser; the dispatcher only runs `/drive --auto-selected`; HUD and "needs attention" are derived from task files.
- **Scope**: one implementation PR (about 10 files, mostly docs and bats); not split (estimation stays 1 because every slice is a few lines of shell).

## Problem

- **Evidence (verified 2026-11-02)**:
  - `_ap_roll_day` wipes the list at each day change: `autopilot/scripts/autopilot-state.sh:195` (`.skip_ids = []`).
  - `ap-off` wipes it too: `autopilot-state.sh:178`.
  - The list lives in the gitignored `dev/.autopilot-state.json`, so no other session or clone sees it; `todo-next.sh:48-50` skips only `Done|Revisit|Parked`, so a bare `/drive` re-picks the same gated #1 forever.
  - The dispatcher walks the queue itself each cycle (`autopilot/SKILL.md` Phase 3, "Resolve the pick").
- **Impact**: after each rollover about 50 owner-gated tasks in the owner's pointer repo would each get a full sub-agent that ends `NEEDS-ATTENTION` again.

## Context

- `autopilot-state.sh eligible` (`:348-354`) already refuses the substring "needs a human"; `hud-lib.sh:437` already buckets it as `decision`; so the substring is the established signal, only its durability and its structure are missing.
- The owner's pointer repo already carries the grammar on its ~47 gated tasks (pointer PR #284, merged), so the grammar below is fixed, not up for redesign.
- `lint_tasks.py:68-116` takes only the leading token of `status:` (hand-rolled parser, not a YAML library), so the suffix passes the lint (verified in the test plan).

## Solution

- **Marker grammar (fixed)**: `status: <leading status token(s)> — needs a human [<kind>]: <reason>`, kind one of `blocked|decision|external`.
  - The leading token is kept (`Open`, `Design`, ...), so lint, `sync-tasks` and `task_claim.sh` keep working.
  - Legacy free text containing "needs a human" with no brackets still counts as marked, kind `decision` (matches `hud-lib.sh:437`).
  - "Gated" (not auto-pickable) is the full existing `eligible` set, `SUPERVISED|BLOCKED|needs a human|needs manual|sign-off` (case-insensitive, `autopilot-state.sh:352`), so no previously refused task becomes pickable. Because the match is case-insensitive, `Blocked by T<id>` statuses are gated too, so a task blocked by a marked task is never picked either.
- **One shared parser**: `todo/scripts/_lib.sh` gets `todo-needs-human-kind <status>` (prints the kind of a bracketed or legacy "needs a human" marker, exit 1 when unmarked) and `todo-gated <status>` (the full gated set above). `eligible`, `todo-next.sh` and `needs-human.sh` all call them.
  - `todo/scripts/needs-human.sh` is the CLI around it: `kind <file>`, `mark <file> <kind> <reason>`, `clear <file>`, `list [repo-root]` (id, kind, reason per marked task in `dev/TODO`).
  - `mark` replaces the `status:` line (and folded continuation lines, same rule as `_tc_fm_set`) with `<old leading text> — needs a human [<kind>]: <reason>`, replacing an older marker; `clear` strips the suffix. `mark --release` also runs `task_claim.sh release <id> <new status>` so a task claimed by this clone does not stay held after it is gated (the Phase 6 and mid-design cases; a never-claimed task needs no release).
- **`todo-next.sh --skip-needs-human`** (settles the open point): gated tasks (`todo-gated`) are skipped like Done/Parked; `--check` prints nothing and exits 0 when at least one task is pickable, 1 when none.
  - Wider than "marked" on purpose: auto-pick (including a human's bare `/drive`) now skips the whole gated set, i.e. also `Blocked by`, `SUPERVISED`, `BLOCKED`, `sign-off`, `needs manual`. That is what `eligible` already refused for the autopilot; the case-insensitive substring match (so "UNBLOCKED" also gates) is kept unchanged, not fixed here.
  - Default output is unchanged, so `/todo next` for a human still shows gated tasks (their status line says why).
  - `/drive` auto-pick (bare, or `--auto-selected`) passes `--skip-needs-human`; an explicit task id is never filtered (a human's deliberate request).
- **Driver writes the marker**: `/drive`'s escalation path and the autopilot prompt tell the sub-agent that ends `NEEDS-ATTENTION` to run `needs-human.sh mark` and land it as a docs-only status PR (same tier as the claim PR). The owner un-gates with `needs-human.sh clear` or by hand.
- **Dispatcher**: Phase 3 drops the sweep and queue walk: pull the clone, `todo-next.sh --skip-needs-human --check` (idle without a dispatch when none), then dispatch `/drive --auto-selected` (no id).
  - **Idle precheck still sees drift**: nothing pickable by `--check` AND `todo-sweep.sh plan` printing no mechanical drift (only `ADD`, `REMOVE`, `UNBLOCK`, `CLOSE_DONE`, `ORDER_VIOLATION` lines count; `SUPERSEDE_CANDIDATE` never does, `apply` will not close it unconfirmed) means `idle` with no dispatch.
    - Any counted line means dispatch anyway: `/drive` Phase 1 runs `/todo sweep` and lands the fix; a sweep park ask still counts as Stuck (the prompt keeps that rule).
    - `plan` exit 4 (malformed queue, duplicate id) is not a dispatch trigger: it records `idle`, and the owner sees it in `/todo sweep`.
    - Loop bound: a drift dispatch that merges nothing is classified `idle`/`stuck` and then waits 45 min or the 5-30 min ladder, so a permanent drift costs at most one agent per back-off, never a 60 s loop.
  - **Marker verified, not trusted**: after a `NEEDS-ATTENTION: T<id>` report, Phase 4 pulls the clone and runs `needs-human.sh kind` on that task. Marked: send the `attention` notice (once per task by construction, the task is never re-picked). Not marked (agent crashed, ignored the prompt, marker PR not merged): record `stuck` ("marker not landed"), which uses the existing 5/10/20/30 min back-off, so a missing marker cannot cause a 60 s redispatch loop.
  - **Blocker recursion**: `/drive` Phase 6 does not recurse into a blocker that carries the marker; the goal task is itself marked `blocked` and the run ends `NEEDS-ATTENTION`.
- **State file**: stays `schema: 2`. `skip`/`unskip` and the `skip_ids`/`needs_attention` fields go away; `attention-list` (via `needs-human.sh list`) feeds `report`, `final-report` and the HUD from task files.
  - Migration: `start`/`record` delete legacy `skip_ids`/`needs_attention` from an existing file and add one `migrated` notice naming the ids and reasons dropped (so the owner can mark them); old files still load.
  - Accepted cost: in a repo whose gated tasks are not yet marked, each previously skipped task is dispatched once more, then its driver marks it. The old list was already wiped every day, so nothing durable is lost.
- **HUD**: `sl-queue-json` buckets a task with a bracketed marker by its kind first, and no longer reads `skip_ids`/`needs_attention` (it still reads `dispatch_clone_path`). Legacy unbracketed statuses keep today's bucket order (`hud-lib.sh:434-439`, e.g. `SUPERVISED (needs a human ...)` stays `blocked`); the state-file `epic` kind goes away (the frontmatter and title epic signals stay).
- **Alternatives rejected**:
  - Keep `skip_ids` but stop wiping it: still per-clone and invisible to other sessions and the owner.
  - Dispatcher writes the marker: it would need to parse sub-agent prose and edit task files; the driver has the reason and the claim already.
  - A new frontmatter key (e.g. `needs_human:`): needs a `lint_tasks.py` allowlist change and breaks the pointer repo's already-merged grammar.
  - Make `todo-next.sh` skip marked tasks by default: hides gated work from the owner's own `/todo next`.

## Test plan

- [x] Unit (bats): parser kinds incl. legacy, unmarked, `Blocked by` untouched; `mark`/`clear` round trip incl. folded status; `list`.
- [x] Unit (bats): `todo-next.sh` default output unchanged; `--skip-needs-human` skips marked; `--check` exit codes.
- [x] Unit (bats): `eligible` refuses the marker and still refuses legacy markers; `skip`/`unskip` removed; legacy state with `skip_ids` loads, is migrated once, day rollover causes no list state.
- [x] Unit (bats): HUD buckets by marker kind and ignores state-file lists; `report`/`final-report` list marked tasks from files.
- [x] Docs: SKILL.md bats cases for autopilot (`tests/autopilot_state.bats` SKILL.md case); drive/todo SKILL.md checked by the skill-quality ratchet and `lint-docs.sh`.
- [x] Lint: `lint_tasks.py` accepts a marked status (run on a sample file).

## Done criteria

- [x] A day rollover leaves no gating state and dispatches nothing extra: `tests/autopilot_state.bats` (rollover test).
- [x] A marked task is never picked by auto-pick until the marker is removed: `tests/todo-next.bats` (`--skip-needs-human`), `drive/SKILL.md` Phase 1.
- [x] The owner sees why from the task file: `needs-human.sh list`, `tests/needs_human.bats`.
- [x] HUD counts come from task files: `tests/hud_lib.bats` (marker bucket test).
- [x] Tests green: CI `bats` job.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `autopilot/scripts/autopilot-state.sh` | 2-52, 112, 178, 195, 348-397, 419, 582-583, 600 | usage text, fresh state, wipes, `eligible`, `skip`/`unskip`, `report`, `final-report`, dispatch table |
| `autopilot/SKILL.md` | 26, 39, 79-85, 102-104, 110, 126, 134 | dispatcher, state fields, classify rules, notices, important notes |
| `todo/scripts/todo-next.sh` | 47-50 | add `--skip-needs-human`, `--check` |
| `todo/scripts/_lib.sh` | 22-31 | add the shared parser |
| `todo/scripts/needs-human.sh` (new) | n/a | `kind`, `mark`, `clear`, `list` |
| `hud/scripts/hud-lib.sh`, `hud/README.md` | 367-441, 112-121 | queue buckets and docs |
| `drive/SKILL.md` | Phase 1, Phase 3 escalation, Phase 6 | auto-pick filter, marking step, no recursion into a marked blocker |
| `todo/SKILL.md` | 60, 78 | status grammar, `next` flags |
| `tests/autopilot_state.bats`, `tests/hud_lib.bats`, `tests/todo-next.bats`, `tests/needs_human.bats` (new) | 117, 279-288, 476, 563-601 / 462-503 | rewire and add cases |

## Related

- Owner's words (2026-11-02): autopilot should not scan every task each time; each cycle it should just call `/drive`. The state exists to explain why autopilot could not finish a task, not to skip tasks before choosing.
- The owner's pointer repo already marks its gated tasks with this grammar (pointer PR #284); that job is not part of this task's code.
- T20261102-902081: HUD `next loop due` fix (shipped in #541; a dead loop shows as stalled).
- T20261028-151063: /autopilot on/off redesign (journal).
- T20260922-195629: autopilot waiting-outcome ambiguity (journal).
- T20261006-391349: autopilot pause/resume/stop (journal).
- T20260930-132964: autopilot dispatches from its own clone (journal).

## Closed (2026-11-02)

- Shipped in **PR #547** (implementation), claim PR #545, design PR #546. CI on #547 green (bats, lint-tasks, skill-quality, sync-tasks, Markdown Lint) and an independent review (two rounds) posted on each PR.
- What landed:
  - `todo/scripts/_lib.sh` (`todo-needs-human-kind`, `todo-gated`) and `todo/scripts/needs-human.sh` (`kind`, `mark [--release]`, `clear`, `list`).
  - `todo-next.sh --skip-needs-human` and `--check`; `/drive` auto-pick uses them, an explicit id is never filtered.
  - `autopilot-state.sh`: `skip`/`unskip` and the state's `skip_ids`/`needs_attention` removed (one-time `migrated` notice), `pickable`, `attention-list`, `marked`, `eligible` on the shared parser, report/final-report derived from the dispatch clone's task files.
  - HUD queue buckets by marker kind and ignores state-file lists; `sync.py` lenient fallback also recovers `blocked-by`.
  - `autopilot`, `drive`, `todo` SKILL.md and `hud/README.md` updated.
- Deviations from the design, both from independent review:
  - `todo-gated` matches `supervised`/`blocked` as whole words, so `UNBLOCKED` (a real status convention) is not gated; the design had kept the old substring wart.
  - `mark` writes backslashes safely and `clear` is case-insensitive.
- Not verified here: a live `/autopilot` cycle against a real repo (the dispatcher text is prose; its scripts are unit-tested). The pointer repo's own marking is already done (pointer PR #284).
- Known, untouched: `todo-next.sh` on an empty `queue.md` errors under bash 3.2 (`lines[@]` unbound); `pickable` is unaffected.
- Follow-up tasks filed: none.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no (skill not installed in this session; tests written alongside the code, bats red/green run per slice) — Phase 3.0, code-class
- Verification (`superpowers:verification-before-completion`): no (skill not installed here; covered by two independent review rounds, the local bats/pytest/skill-quality runs and the /address-pr pre-merge gate)
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck
- Receiving code review (`superpowers:receiving-code-review`): no (skill not installed here); 5 + 7 + 3 review findings on #547/#546 each fixed or answered in the design
