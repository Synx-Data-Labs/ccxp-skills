---
status: In Progress
scheduled: 2026-10-05
estimation: 2
source: T20260809-355059's Phase A/B implementation (2026-09-25) — follow-up
  filed at close per that task's Done criteria and its dual-accept design.
related: T20260809-355059
blocked-by: T20260925-244717 — resolved, merged (see
  dev/JOURNAL/2026-10-06-T20260925-244717-reclaim-decide-status-exact-match-bug.md).
  Both tasks touched the identical `_tc_reclaim_decide` case-arm in
  `_session/task_claim.sh:297`; no reorder was needed since queue order already
  had 244717 ahead of this task.
claimed_by: cc1-50ac6891:ed6da7ef699fc33b
claimed_role: interactive
---

# T20260925-283679: Remove the legacy `Coding` status alias once external repos migrate

## TLDR

- **Type**: chore
- **Problem**: T20260809-355059 renamed the lifecycle status `Coding` →
  `In Progress` as a **dual-accept** transition — ~20 files across
  `_session/`, `_ipm/`, `ccxp/scripts/`, `repo-conventions/scripts/`,
  `actions/sync-tasks/`, and `tests/` still pattern-match the literal
  `Coding` as an equivalent alias.
- **Solution**: strip the `Coding` case-arms/fixtures from all of them,
  keeping the parallel `"In Progress"` coverage that T20260809-355059 already
  added, with a human-confirmed precondition (no external repo task file
  still at `status: Coding`) flagged prominently in the PR rather than
  blocking implementation on it.

## Problem

- T20260809-355059 renamed the lifecycle status `Coding` → `In Progress`, but
  landed it as a **dual-accept** transition rather than a hard cutover: every
  script/check that pattern-matches the status value (`_session/task_claim.sh`,
  `reclaim_sweep.sh`, `attribution.sh`, `claim_gap.sh`,
  `_ipm/ipm-iteration-drain-check.sh`, `ccxp/scripts/epic-status.sh`,
  `repo-conventions/scripts/lint_tasks.py`, `actions/sync-tasks/sync.py`) still
  recognizes the literal `Coding` as an equivalent legacy alias of
  `In Progress`.
- Verified footprint (2026-10-06):
  `grep -rln "Coding" _session _ipm ccxp/scripts repo-conventions/scripts actions/sync-tasks tests`
  hits 20 files, including case-arms (e.g. `_session/task_claim.sh:297`,
  `:632`; `ccxp/scripts/epic-status.sh:301`, `:317`, `:446`, `:475`) and test
  fixtures (`tests/task_claim.bats`, `tests/epic-status.bats`,
  `tests/attribution.bats`, `tests/claim_gap.bats`, `tests/reclaim_sweep.bats`,
  `tests/todo-next.bats`, `tests/eta.bats`, `tests/task-state.bats`,
  `tests/ipm_iteration_drain_check.bats`,
  `tests/fixtures/epics/task-coding.md`).
- This was necessary because `ccxp-skills` is a shared sibling repo other
  repos invoke live via `../_session/*.sh` — a hard cutover would have broken
  claim tracking for any task file anywhere still at the old value the moment
  it merged, including the (as of 2026-08-09, unverified-stale) 10 known
  active `dev/TODO/` tasks in `hub-repo`/`build-pipeline-repo`.
- The alias is intentional scaffolding, not tech debt to clean up
  reflexively — removing it before those external task files are actually
  migrated would reintroduce the exact breakage T20260809-355059's design
  was written to avoid.

## Context

- `ccxp-skills` is invoked live (not vendored/pinned) by sibling repos via
  `../_session/*.sh`, `../_ipm/*.sh`, etc. — any task file in those repos
  still carrying `status: Coding` depends on this repo continuing to accept
  it until that repo migrates.
- This task is a direct follow-up filed at T20260809-355059's close, per that
  task's own Done criteria.

## Solution

1. From a clone with access to `hub-repo` and `build-pipeline-repo` (this
   clone does not have it): confirm no `dev/TODO/*.md` file in either repo
   still carries `status: Coding` (bulk-edit any stragglers to
   `In Progress`, or confirm they've already flipped naturally via normal
   status transitions). **Precondition gating**: implement now, don't block
   the work on this external verification (unreachable from this clone
   either way) — the PR description flags the unverified
   hub-repo/build-pipeline-repo migration prominently, and merge is gated on
   a human confirming it, not on this implementation pass.
2. Remove the `Coding` case-arms from the full verified file list (see
   `## Repo file references` below) — not just the 8 originally named; the
   actual footprint is ~20 files once comment-only mentions, fixtures, and
   the three extra bats files (`tests/task-state.bats`, `tests/eta.bats`,
   `tests/todo-next.bats`) are included.
3. Remove or repurpose the now-obsolete bats/unittest cases that
   specifically assert the legacy alias still works (search each touched
   test file for `Coding` — most already have a parallel `"In Progress"`
   case added by T20260809-355059 that should be kept).
4. Update the doc mentions of "legacy `Coding` alias" in `lifecycle.md`,
   `_session/README.md`, `todo/SKILL.md`, `repo-conventions/SKILL.md` (all
   touched by T20260809-355059 Phase B) to drop the alias caveat.

**Alternatives considered and rejected:**

- **Hard cutover immediately, don't wait on external migration** — rejected:
  this is the exact breakage T20260809-355059's dual-accept design was built
  to avoid (any external task file still at `Coding` mid-flight would lose
  claim tracking the moment this merged).
- **Delete the obsolete alias tests outright instead of keeping an
  `"In Progress"` parallel** — rejected for the scheduled-guard tests in
  `test_lint_tasks.py` (`test_coding_without_scheduled_fails` and its three
  siblings): they have no existing parallel, so deleting them would drop
  real scheduled-guard coverage. Add the missing `In Progress` parallels
  instead.
- **Leave `epic-status.sh`'s internal `Coding` bucket key/display text
  alone, only remove the parsing case-arms** — rejected: the task's own
  title is "remove legacy Coding status alias"; leaving `/ccxp epic-status`
  printing "N Coding" in every summary would undercut that. Fully rename the
  `'Coding'` bucket key and output text to `In Progress`.

**Scope notes:**

- Also clean `_session/_lib.sh`, `_session/status.sh` (comment-only alias
  narration, no case-arms).
- Rewrite non-alias-specific uses of the literal `"Coding"` in
  `actions/sync-tasks/test_sync.py`'s prose-suffix parsing tests (and
  equivalent bats examples) to a neutral placeholder (`"In Progress"` or
  `"Review"`) — the literal value there was arbitrary to begin with, not
  testing alias-equivalence.
- Also rename `tests/fixtures/epics/task-coding.md` → `task-in-progress.md`
  with `status: In Progress`, consistent with the placeholder rule above.

### Open

- Exact count/state of `hub-repo`/`build-pipeline-repo` task files still at
  `status: Coding` — can't be checked from this clone (confirmed
  unreachable); left as a merge-time human check, not implementation work.

## Test plan

- [ ] `grep -rn "Coding" _session _ipm ccxp/scripts repo-conventions/scripts actions/sync-tasks tests` returns zero status-enum hits (Copilot Coding Agent / Cloudflare false positives excluded)
- [ ] Full bats suite green (`bats tests/`), including the updated `tests/epic-status.bats`, `tests/task-state.bats`, `tests/eta.bats`, `tests/todo-next.bats`, `tests/task_claim.bats`, `tests/attribution.bats`, `tests/claim_gap.bats`, `tests/reclaim_sweep.bats`, `tests/ipm_iteration_drain_check.bats`
- [ ] Both Python unittest suites green: `python3 -m unittest repo_conventions.scripts.test_lint_tasks` and `python3 -m unittest actions.sync_tasks.test_sync` (or repo-equivalent invocation), including the new `In Progress` scheduled-guard parallels in `test_lint_tasks.py`
- [ ] Post-merge (external, human-confirmed): no `dev/TODO/*.md` in `hub-repo`/`build-pipeline-repo` still carries `status: Coding`

## Done criteria

- [ ] No known task file anywhere (accessible repos) carries literal
  `status: Coding` — verified by the `grep` in Test plan item 1
- [ ] `grep -rn "Coding" _session _ipm ccxp/scripts repo-conventions/scripts
  actions/sync-tasks tests` returns zero status-enum hits (Copilot Coding
  Agent / Cloudflare false positives excluded) — same grep, Test plan item 1
- [ ] Full bats + both Python unittest suites still green after removal —
  `bats tests/*.bats` and the two `unittest` invocations in Test plan
  items 2-3

## Design

- **Sequencing with T20260925-244717**: resolved — see frontmatter
  `blocked-by:` note. Both tasks touched the identical `_tc_reclaim_decide`
  case-arm in `_session/task_claim.sh:297`; T20260925-244717 merged first
  (queue order already had it ahead), so this task's removal pass works
  against its already-landed prefix-match fix, not the pre-fix code.
- **`test_lint_tasks.py` correction**: the scheduled-guard tests —
  `test_coding_without_scheduled_fails`, `test_coding_with_valid_scheduled_passes`,
  `test_coding_with_invalid_scheduled_fails`,
  `test_prose_suffixed_coding_without_scheduled_fails` — have no existing
  `In Progress` parallel (unlike most other alias tests). Add the missing
  parallels rather than just deleting, so the scheduled-guard behavior stays
  covered.
- Estimation revised from 1h to 2h: actual footprint is ~20 files (vs. the 8
  originally named), plus `epic-status.sh`'s display-text rename touches
  format strings and a bats assertion, plus adding missing
  `lint_tasks.py` test parallels rather than pure deletion.

## Root cause

- The `Coding` alias is not a bug — it's deliberate scaffolding introduced by
  T20260809-355059's Phase A/B rename of the lifecycle status
  `Coding` → `In Progress`, landed as dual-accept rather than a hard cutover
  specifically because `ccxp-skills` is invoked live by sibling repos
  (`_session/task_claim.sh:15` documents this directly: "the legacy `Coding`
  value is still recognized as an equivalent alias everywhere this file
  matches on status, T20260809-355059").
- It's still present today because the precondition for removing it — every
  external repo's `dev/TODO/*.md` having moved off `status: Coding` — was
  never confirmed from this clone (no access to `hub-repo`/`build-pipeline-repo`);
  this task exists to do the removal once that's confirmed at merge time by a
  human, rather than leaving the scaffolding in indefinitely.
- T20260925-244717 (merged, see `dev/JOURNAL/2026-10-06-T20260925-244717-reclaim-decide-status-exact-match-bug.md`)
  touched the same `_tc_reclaim_decide` case-arm (`_session/task_claim.sh:297`)
  to fix a prefix-vs-exact-match bug in the alias handling — this task's
  removal pass must work against that fix, not reintroduce the bug it closed.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_session/task_claim.sh` | `15`, `259`, `297`, `614`, `632` | Case-arms + doc comments recognizing `Coding` as an `In Progress` alias in claim decisions |
| `_session/attribution.sh` | `209`, `220` | In-flight detection treats `Coding`/`In Progress`/`Review` identically |
| `_session/status.sh` | `4` | Comment-only alias narration (no case-arm) |
| `_session/_lib.sh` | `6`, `147`, `247` | Comment-only alias narration (no case-arm) |
| `_session/claim_gap.sh` | `6`, `21`, `56` | Gap detection case-arm for `Coding`/`In Progress` |
| `_session/reclaim_sweep.sh` | `9`, `80`, `82` | Reclaim-eligibility case-arm for `Coding`/`In Progress`/`Review` |
| `_session/README.md` | `17`, `25`, `123` | Docs narrating the legacy alias |
| `_ipm/ipm-iteration-drain-check.sh` | `11`, `29` | Drain-check in-flight status list includes the alias |
| `ccxp/scripts/epic-status.sh` | `294`, `299-301`, `317`, `446`, `475` | Bucket key/display text `Coding`, to be renamed to `In Progress` |
| `repo-conventions/scripts/lint_tasks.py` | `161-162` | Prose-suffix status check recognizes `Coding` |
| `repo-conventions/scripts/test_lint_tasks.py` | `51`, `254`, `326`, `349-366` | Tests asserting `Coding` lint behavior, incl. scheduled-guard tests with no `In Progress` parallel |
| `actions/sync-tasks/sync.py` | `521`, `542` | Prose-suffixed status parsing + doc comment |
| `actions/sync-tasks/test_sync.py` | `454-459`, `519-649`, `864-954` | Tests asserting `Coding` status mapping/parsing |
| `tests/claim_gap.bats` | multiple | Fixtures using `Coding` |
| `tests/epic-status.bats` | `311-341` | Fixtures/assertions using `Coding` bucket |
| `tests/attribution.bats` | `110-207` | Fixtures using `Coding` |
| `tests/todo-next.bats` | `147-181` | Fixtures using `Coding` |
| `tests/task_claim.bats` | multiple | Fixtures/assertions using `Coding` |
| `tests/reclaim_sweep.bats` | multiple | Fixtures using `Coding` |
| `tests/eta.bats` | `31` | Fixture using `Coding` |
| `tests/task-state.bats` | `51-194` | Fixtures using `Coding` |
| `tests/ipm_iteration_drain_check.bats` | multiple | Fixtures using `Coding` |
| `tests/fixtures/epics/task-coding.md` | whole file | Fixture to rename to `task-in-progress.md` |
| `lifecycle.md`, `todo/SKILL.md`, `repo-conventions/SKILL.md` | — | Doc mentions of the legacy alias to drop |

## Out of scope

- Renaming any other lifecycle status — same boundary T20260809-355059 set.
