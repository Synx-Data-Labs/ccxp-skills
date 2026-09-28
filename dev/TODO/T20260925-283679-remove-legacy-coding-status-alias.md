---
status: Open
scheduled: 2026-10-05
estimation: 1h
source: T20260809-355059's Phase A/B implementation (2026-09-25) — follow-up
  filed at close per that task's Done criteria and its dual-accept design.
related: T20260809-355059
blocked-by: none — informational: depends on the external migrations below,
  not another ccxp-skills task
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
   table for the exact line numbers, since they will have drifted).
3. Remove or repurpose the now-obsolete bats/unittest cases that
   specifically assert the legacy alias still works (search each touched
   test file for `Coding` — most already have a parallel `"In Progress"`
   case added by T20260809-355059 that should be kept).
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

## Out of scope

- Renaming any other lifecycle status — same boundary T20260809-355059 set.
