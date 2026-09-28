---
status: Open
scheduled: 2026-10-05
estimation: 2h
source: T20260809-355059's Phase A/B implementation (2026-09-25) — follow-up
  filed at close per that task's Done criteria and its dual-accept design.
related: T20260809-355059
blocked-by: T20260925-244717 — both touch the identical `_tc_reclaim_decide`
  case-arm in `_session/task_claim.sh`; also depends informationally on the
  external hub-repo/build-pipeline-repo migration (see Problem/Design)
---

# T20260925-283679: Remove the legacy `Coding` status alias once external repos migrate

## Problem

- T20260809-355059 renamed the lifecycle status `Coding` → `In Progress`, but
  landed it as a **dual-accept** transition rather than a hard cutover: every
  script/check that pattern-matches the status value (`_session/task_claim.sh`,
  `reclaim_sweep.sh`, `attribution.sh`, `claim_gap.sh`,
  `_ipm/ipm-iteration-drain-check.sh`, `ccxp/scripts/epic-status.sh`,
  `repo-conventions/scripts/lint_tasks.py`, `actions/sync-tasks/sync.py`) still
  recognizes the literal `Coding` as an equivalent legacy alias of
  `In Progress`.
- This was necessary because `ccxp-skills` is a shared sibling repo other
  repos invoke live via `../_session/*.sh` — a hard cutover would have broken
  claim tracking for any task file anywhere still at the old value the moment
  it merged, including the (as of 2026-08-09, unverified-stale) 10 known
  active `dev/TODO/` tasks in `hub-repo`/`build-pipeline-repo`.
- The alias is intentional scaffolding, not tech debt to clean up
  reflexively — removing it before those external task files are actually
  migrated would reintroduce the exact breakage T20260809-355059's design
  was written to avoid.

## What to do

1. From a clone with access to `hub-repo` and `build-pipeline-repo` (this
   clone does not have it): confirm no `dev/TODO/*.md` file in either repo
   still carries `status: Coding` (bulk-edit any stragglers to
   `In Progress`, or confirm they've already flipped naturally via normal
   status transitions).
2. Remove the `Coding` case-arms from the 8 files listed in the Problem
   section above (mirror T20260809-355059's own "Repo file references"
   table for the exact line numbers, since they will have drifted). In
   `_session/task_claim.sh`'s `_tc_reclaim_decide`, strip whatever
   `Coding`/`Coding\ *` shape T20260925-244717 actually leaves behind (it
   adds prose-suffix matching to this same case-arm) — not just the bare
   literal token this Problem section describes.
3. Remove or repurpose the now-obsolete bats/unittest cases that
   specifically assert the legacy alias still works (search each touched
   test file for `Coding` — most already have a parallel `"In Progress"`
   case added by T20260809-355059 that should be kept). See Design for the
   two known exceptions where no parallel exists yet.
4. Update the doc mentions of "legacy `Coding` alias" in `lifecycle.md`,
   `_session/README.md`, `todo/SKILL.md`, `repo-conventions/SKILL.md` (all
   touched by T20260809-355059 Phase B) to drop the alias caveat.

## Done when

- [ ] No known task file anywhere (accessible repos) carries literal
  `status: Coding`
- [ ] `grep -rn "Coding" _session _ipm ccxp/scripts repo-conventions/scripts
  actions/sync-tasks` returns zero status-enum hits (Copilot Coding Agent /
  Cloudflare false positives excluded)
- [ ] Full bats + both Python unittest suites still green after removal

## Design

- **Precondition gating**: implement now, don't block the work on external
  verification (unreachable from this clone either way). PR description
  flags the unverified hub-repo/build-pipeline-repo migration prominently;
  merge is gated on a human confirming it, not on this implementation pass.
- **Scope beyond the named 8 files**: also clean `_session/_lib.sh`,
  `_session/status.sh` (comment-only alias narration, no case-arms) and
  three more bats files not in the original list — `tests/task-state.bats`,
  `tests/eta.bats`, `tests/todo-next.bats` — which use literal `Coding`
  fixtures. Needed so the Done criterion's grep actually returns zero (it
  doesn't exclude comments).
- **Generic-example test literals**: rewrite non-alias-specific uses of the
  literal `"Coding"` (in `actions/sync-tasks/test_sync.py`'s prose-suffix
  parsing tests, and equivalent bats examples) to a neutral placeholder
  (`"In Progress"` or `"Review"`) — the literal value there was arbitrary
  to begin with, not testing alias-equivalence.
- **`test_lint_tasks.py` correction**: step 3's assumption ("most already
  have an In Progress parallel") is false for the scheduled-guard tests —
  `test_coding_without_scheduled_fails`, `test_coding_with_valid_scheduled_passes`,
  `test_coding_with_invalid_scheduled_fails`,
  `test_prose_suffixed_coding_without_scheduled_fails` have no parallel.
  Add the missing `In Progress` parallels rather than just deleting, so the
  scheduled-guard behavior stays covered.
- **`epic-status.sh`'s internal bucket/display name**: fully rename the
  `'Coding'` bucket key and output text to `In Progress` (the `counts[Coding]`
  array key, the `%d Coding` format strings, the `C` short-line marker, and
  `tests/epic-status.bats`'s matching output assertion) — the task's own
  title is "remove legacy Coding status alias"; leaving `/ccxp epic-status`
  printing "N Coding" in every summary would undercut that. Also rename
  `tests/fixtures/epics/task-coding.md` → `task-in-progress.md` with
  `status: In Progress`, consistent with the placeholder rule above.
- **Sequencing with T20260925-244717**: recorded as `blocked-by:` in this
  file's frontmatter — both tasks touch the identical `_tc_reclaim_decide`
  case-arm in `_session/task_claim.sh`. Queue order already has 244717
  immediately before this task; no reorder needed.

### Open

- Exact count/state of `hub-repo`/`build-pipeline-repo` task files still at
  `status: Coding` — can't be checked from this clone (confirmed
  unreachable); left as a merge-time human check, not implementation work.

### Test Plan

- `grep -rn "Coding" _session _ipm ccxp/scripts repo-conventions/scripts
  actions/sync-tasks tests` returns zero status-enum hits (Copilot Coding
  Agent / Cloudflare false positives excluded).
- Full bats suite green, including the updated `epic-status.bats`,
  `task-state.bats`, `eta.bats`, `todo-next.bats`.
- Both Python unittest suites green
  (`repo-conventions/scripts/test_lint_tasks.py`,
  `actions/sync-tasks/test_sync.py`), including the new `In Progress`
  scheduled-guard parallels.

Estimation revised from 1h to 2h: actual footprint is ~15 files (vs. the 8
named), plus `epic-status.sh`'s display-text rename touches format strings
and a bats assertion, plus adding missing `lint_tasks.py` test parallels
rather than pure deletion.

## Out of scope

- Renaming any other lifecycle status — same boundary T20260809-355059 set.
