### E3 — Dependency chain replaces `Blocked by`

Goal: a task that discovers a dependency keeps its real status and records the dependency; the system shows the dependency chain (and the first open leaf to work next), and no task is ever shown as blocked
Done when: every member below is closed (in `dev/JOURNAL/`), `status: Blocked by` is gone from the allowed values after the migration window, and the open questions below are answered in their owning member

Owner rule d159 (2026-11-24): when a dependency chain is detected, `queue.md` must be reordered to follow the chain (blockers ahead of dependants), via `/todo sweep`; it is a requirement of sub-task (e) and spec item 7.

Owner's words (2026-11-24, decision d158): "I don't like to show a job is in 'blocked', but I want to see we discover a 'dependency', and the job is still in progress. this will help us avoid stalling a task. So, where do we capture the status of a given task? I want to remove 'blocked', and replace by its dependency chain."

This epic is a spec for the owner to review; nothing in it is implemented yet. Sub-task (a) turns the schema part into code first.

## Where status lives today (corrected from the code)

- Canonical status: the task file's frontmatter `status:` (`Open`, `Design`, `In Progress`, `Review`, `Blocked by T{id}`, `Parked`, `Done`; `todo/SKILL.md` "Task metadata", `lifecycle.md`). Free text after the leading token is allowed.
- Gate words: auto-pick (`todo-next.sh --skip-gated`, `todo-gated` in `todo/scripts/_lib.sh`) skips `Blocked by`, `SUPERVISED`, `BLOCKED`, `needs manual`, `sign-off` (case-insensitive). The HUD uses a stricter, case-sensitive subset and counts a `Blocked by T<id>` as held only while that task is still in `dev/TODO/`.
- Typed non-task waits: `status: Blocked by person:<alias>` and `Blocked by ext:<text>` (lint checks the alias; `task-query.sh --waiting-on` reads them; sweep ignores them).
- `queue.md` holds order only. `claimed_by:` (runtime, `/drive` via `_session/task_claim.sh`) records the driver. `blocks:` lists dependants; a legacy free-text `blocked-by:` key is still in the lint allowlist.
- Per-machine autopilot visit counters live in `dev/.autopilot-state.json`; the HUD derives claimed, revisited and auto-parked counts from them and from the task files.
- Behaviours keyed on `Blocked by T{id}` today: auto-pick skip; `/todo sweep` Phase 2 (clears a stale blocker to `Design` or `Open`, orders blockers before dependants); `/top` blocker-chain expansion (`lifecycle.md`); `/drive` Phase 6 (parks the goal as `Blocked by T{B}`, recurses into the blocker, mirrors `status.sh <id> Blocked`); autopilot `bottom` and `park` guards; lint (`Blocked by` must point at an open task); HUD held count; `migrate-task`, `cleanup-branch`, `epic.sh`, `task_claim.sh` and `task-state.sh` mention or read it. The persona asset does not name `Blocked by` (checked), so it needs no change.

## Spec (to review)

1. **Schema.** New frontmatter field `depends_on: [T{id}, ...]`, the inverse of `blocks:`. A task that discovers a dependency adds it there, keeps its real status (`In Progress`, `Design` or `Open`) and files the dependency as its own task. No status value says blocked. Both sides stay maintained (`blocks:` on the dependency), as today.
2. **Derived view.** `todo/scripts/todo-deps.sh chain T<id>` and `todo-deps.sh tree`. `chain` prints `T<goal> <- T<dep1> <- T<dep2>`, each node with its status and claimant, cycle detection (named, never a hang), a depth cap (10, as `/top` has today), and the first open LEAF (the dependency to work next). `tree` prints every task that has open dependencies. Nothing is stored; it is computed from `depends_on:` and the files in `dev/TODO/`.
3. **Autopilot and `/drive`.** No skipping (d152). When the top task has open dependencies, the cycle works the first open leaf of its chain (recursion is already `/drive` Phase 6) and the goal stays `In Progress`. A leaf claimed by a live peer shows in the chain as in progress by that peer, never as blocked. If every leaf is held by live peers or a human, the cycle reports it and moves on without writing anything to the goal.
4. **HUD.** Replace the held count with a chain display for the task being driven (for example `T1 -> T2 -> T3`, with depth) and a count named `waiting on deps` for tasks that have open dependencies. Human-only conditions are counted under their own name (item 5), not as deps.
5. **Human-only conditions.** `SUPERVISED`, `needs manual`, `sign-off`, VPN and owner decisions are not dependencies. Proposed: a separate field `needs: [human|vpn|owner-decision|...]`, free of the word blocked, read by auto-pick, the HUD and the ccxp pre-flight gate in place of today's substring greps. It feeds the future hold kinds (needs-human) of the cursor and holds design, a separate task, [T20261124-989194](../TODO/T20261124-989194-autopilot-cursor-and-holds.md). Typed waits on a person or external party (`Blocked by person:` / `ext:`) become `needs: person:<alias>` / `ext:<text>`. Free-text `SUPERVISED` and friends keep working during the window.
6. **Migration.** `todo/scripts/todo-deps.sh migrate [--dry-run]` converts each `status: Blocked by T..` into `depends_on: [T..]` plus a real status (`Design` if the task has a `## Design` section, else `Open`, the same rule as sweep Phase 2 for stale blockers; trailing notes kept), adds the missing `blocks:` on the other side, and converts the typed `person:` / `ext:` forms to `needs:`. A one-time compat reader treats a legacy `Blocked by T..` status as `depends_on` plus a warning, so mixed old and new files work while several repos run different plugin versions. Dry run reports counts and the files that cannot convert (unknown id, cycle, multiple blockers with prose that needs a human to place).
7. **Sweep Phase 2 (owner rule d159: when a dependency chain is detected, `queue.md` is reordered to follow the chain, blockers ahead of dependants, via `/todo sweep`).** Becomes: order dependencies before dependants, computed from the whole dependency graph (`depends_on:` and `blocks:` on both sides, plus legacy `Blocked by` through the compat reader), not only from `Blocked by` status (a goal and its dependency stay adjacent in chain order, using the existing `/top --before` move, never to the absolute front); and drop a `depends_on` entry when that dependency leaves `dev/TODO/` (strike the `## Dependencies` line as today). It never rewrites status.
8. **Lint, docs, tests.** `repo-conventions` lint: `depends_on` and `needs` join the key allowlist; `Blocked by` is accepted with a deprecation warning during the window, then removed; `depends_on` entries must exist and must not cycle. Docs: `lifecycle.md`, `todo`, `drive`, `autopilot`, `repo-conventions` (templates `task.md`, `guidelines.md`), `hud/README.md`. Bats and python tests for each script and rule.

## Rollout order

- (a) schema, lint, compat reader: nothing changes for users; old files keep working.
- (b) `todo-deps.sh chain/tree`: read-only view.
- (c) migration script and a read-only dry-run report on the real synxdb-build-pipeline queue; no consumer file is changed by this epic.
- (d) `/drive` Phase 6 and autopilot pick behavior (also makes auto-pick and the ccxp pre-flight gate read `needs:`); runs after (c) so the migrated repos are not left on a gate that ignores `Blocked by`; removes `Blocked by` from the auto-pick gate once the compat reader is in.
- (e) HUD chain display and sweep Phase 2; then a deprecation window of one minor release, then drop the compat reader and the `Blocked by` status.

## Open questions

- Q1: field name `depends_on` vs reusing `blocked-by:` (already in the allowlist, free text). Proposed `depends_on` (clear inverse of `blocks:`, and the old key stays a legacy alias read by the compat reader).
- Q2: `needs:` value vocabulary and whether it replaces the `SUPERVISED` / `needs manual` / `sign-off` substrings outright or only alongside them (the ccxp pre-flight gate in consumer repos greps them).
- Q3: cross-repo dependencies (a task in another repo): `depends_on: [owner/repo#T..]`, or typed `ext:` only? Proposed `needs: ext:<text>` until the multi-repo cursor work lands. Answered in (a)'s Closed section.
- Q4: when every open leaf of a chain is held by live peers, does the cycle take the next queue task (lateral) or wait? Proposed: take the next queue task; the goal is not stalled because it is still `In Progress` and its leaf is being worked.
- Q5: deprecation window length for `Blocked by` (proposed one minor release after (e)); answered in (e)'s Closed section.
- Q6: the `/drive` Phase 6 Project-board mirror (`_session/status.sh <id> Blocked`) is vestigial since the board was retired; drop it in (d).

## Follow-ups outside this epic

- Consumer repo task files (for example synxdb-build-pipeline) are migrated by their owners with the (c) script after the release; this epic never edits them.

- [T20261124-320024](../JOURNAL/2026-11-24-T20261124-320024-depends-on-schema-lint-and-compat-reader.md) — (a) spec, `depends_on` schema, lint, compat reader
- [T20261124-419462](../TODO/T20261124-419462-todo-deps-chain-and-tree.md) — (b) `todo-deps.sh chain` and `tree`
- [T20261124-177980](../TODO/T20261124-177980-blocked-by-migration-script-and-dry-run-report.md) — (c) migration script with dry run, plus dry-run report on synxdb-build-pipeline
- [T20261124-112157](../TODO/T20261124-112157-drive-and-autopilot-work-first-open-leaf.md) — (d) `/drive` Phase 6 and autopilot pick: work the first open leaf
- [T20261124-158321](../TODO/T20261124-158321-hud-chain-display-and-sweep-phase-2.md) — (e) HUD chain display and sweep Phase 2
