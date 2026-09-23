---
status: Done
scheduled: 2026-08-17
estimation: 1h
source: Discovered while filing follow-up tasks from T20260515-128802 (2026-08-10)
related: T20260515-128802
claimed_by:
claimed_role:
---

# T20260810-632933: `_ipm/stamp-scheduled.sh` Tier 1 silently uses a stale IPM file

## TLDR

- **Type**: bug
- **Problem**: `stamp-scheduled.sh`'s Tier 1 trusts whatever `_ipm_current()` returns unconditionally, even when that IPM file is many weeks stale — silently stamping a past date onto a task's `scheduled:` field instead of falling through to Tier 2/3.
- **Solution**: add a staleness bound (~2 weeks) to Tier 1's *usage* inside `stamp-scheduled.sh` itself — not inside the shared `_ipm_current()` helper, whose other callers legitimately want "newest committed IPM regardless of age."

## Context

- `_ipm/current.sh`'s `_ipm_current()` (`_ipm/current.sh:34-48`) is shared by
  4+ callers (`/rca` Step 6, `/ccxp` Phase 1.1/2a.1.5/2a.5b — see its own
  docstring, `_ipm/current.sh:16-24`) that legitimately want "newest
  committed IPM, however old" — e.g. Phase 2a.1.5 runs before this week's
  IPM commits, so "newest committed" correctly means last week's file; a
  real IPM-cadence gap (a cron deadlock swallowing a Monday IPM, an
  observed recurring scenario) can also legitimately push this to
  multiple weeks old without it being wrong for those callers.
- `stamp-scheduled.sh` (`_ipm/stamp-scheduled.sh:38-49`) is the one caller
  where an old result is actually **wrong**, not just old: it's mapping a
  task to a **current/upcoming board iteration**, and a 13-week-stale
  Monday silently produces a `scheduled:` date in the past.

## Solution

- Add the staleness bound **only in `stamp-scheduled.sh`'s Tier 1 block**
  (`_ipm/stamp-scheduled.sh:38-49`), right after resolving `BASE` from
  `_ipm_current`'s result: if the resolved date is more than 14 days
  behind `$TODAY`, clear `BASE` back to empty — the existing `if [ -z
  "$BASE" ]` Tier-2 fallthrough (`_ipm/stamp-scheduled.sh:52`) then
  naturally takes over, no new control-flow needed.
- Date-diff arithmetic: reuse this repo's established GNU/BSD dual-date
  fallback idiom (`_session/task_claim.sh:347-349`'s `_tc_iso_to_epoch` —
  GNU `date -d ... +%s` first, BSD `date -j -f ... +%s` second) to convert
  both `BASE` and `$TODAY` to epoch seconds, then compare
  `(today_epoch - base_epoch) / 86400 > 14`. This is already the repo's
  portable pattern for date math (also used at `ccxp/scripts/epic-status.sh:111`
  and `ccxp/SKILL.md:568,697`) — not a new idiom to invent.
- **Alternatives rejected**:
  - *Add the staleness bound inside `_ipm_current()` itself* — rejected:
    that function is shared by 4+ callers whose own docstring explicitly
    documents "newest committed, however old" as correct behavior for
    them (e.g. Phase 2a.1.5's seed-from-last-week case). Bounding it
    there would silently change behavior for callers that never had this
    bug.
  - *Log a warning instead of falling through* — rejected (the task's own
    "alternative" sketch): a warning makes the wrong date *visible* but
    still writes it — `stamp-scheduled.sh`'s whole job is producing a
    correct `scheduled:` value for the board-iteration mirror, and a
    silently-wrong-but-logged date is still a functional bug, not merely
    a diagnostics gap.

## Problem

- `_ipm/stamp-scheduled.sh` resolves the base Monday via a 3-tier hybrid: (1) newest committed `*-ipm-weekly.md`, (2) Project API, (3) next-Monday computed from today.
- Tier 1 is tried first and, if it finds ANY IPM file, is used unconditionally — even if that file is many weeks stale. `_ipm/current.sh` correctly excludes `2026-06-29`/`2026-06-22`/`2026-06-15-ipm-weekly.md` as `**Status**: Pre-IPM staging` stubs (verified: `bash ~/.claude/skills/_ipm/current.sh dev/JOURNAL` in this repo resolves `dev/JOURNAL/2026-05-11-ipm-weekly.md`), so the actual file Tier 1 trusts is **~13 weeks stale** as of 2026-08-10, not the ~6 weeks a naive `ls -t` would suggest. `stamp-scheduled.sh <file> next` returned `2026-05-18` (`2026-05-11` + 7 days) — a date in the past relative to today, instead of the correct `2026-08-17`.
- Other tasks in this repo correctly show `scheduled: 2026-08-10`/`2026-08-03` — presumably stamped via Tier 2 (Project API, token-gated) in sessions that had a PAT, or hand-corrected. A session without a token silently gets the wrong, stale answer from Tier 1 with no warning.
- **Note as of migration (2026-09-14)**: `_ipm/` now lives in `ccxp-skills`
  (post T20260827-280088 split) — re-verify the file's exact behavior/line
  numbers at pickup against this repo's copy, not the historical
  `hub-repo`-relative description above.

## Test plan

- [x] `tests/stamp_scheduled.bats` — new cases: a >14-day-stale IPM file falls through to Tier 3, an exactly-14-day-stale file is still trusted (boundary), a 15-day-stale file falls through — all 3 written test-first (RED verified), now green
- [x] Existing cases (fresh IPM file, Project-API override, no-token fallback) still pass — full repo BATS suite (689 tests, `tests/*.bats _docs/*.bats`) green, 0 failures
- [x] Original bug scenario reproduced and verified fixed: `IPM_TODAY=2026-08-10` against a `2026-05-11`-dated IPM file, `next` mode — before the fix: `2026-05-18` (the reported bug); after: `2026-08-24` (Tier 3 correctly takes over; differs from the task's own rough "2026-08-17" note, which didn't account for `next` mode's already-established +7-on-top-of-Tier-3 doubling — see `## Closed` below)

## Done criteria

- [x] Fix shipped in `_ipm/stamp-scheduled.sh`'s Tier 1 block, staleness-bound test passing — `tests/stamp_scheduled.bats`, `_ipm/stamp-scheduled.sh:55-70`
- [x] Existing `tests/stamp_scheduled.bats` suite still green — no regressions in fresh-IPM/Project-API/no-token cases; full repo suite also green

## Migrated (2026-09-14)

- Migrated from `hub-repo/dev/TODO/` by T20260827-420045 — the task's
  `target-repo: your-org/private-skills-repo` field (set 2026-08-10, before
  the ccxp-skills split shipped) is stale: `_ipm/` is now ccxp-skills' own
  shared lib, so this is "work about ccxp-skills itself" per that repo's
  CLAUDE.md — landing here directly instead of `private-skills-repo`.

## Closed (2026-09-23)

- Shipped in **PR #81** (`t20260810-632933-impl`) — this task's own
  design PR (#80) merged first, implementation followed in this PR.
- Both Done criteria met: `_ipm/stamp-scheduled.sh:55-70` adds the
  14-day staleness bound to Tier 1's usage, scoped to that one caller
  (not the shared `_ipm_current()` helper); `tests/stamp_scheduled.bats`
  gained 3 new test-first cases (>14 days stale, exactly-14-day
  boundary, 15 days stale) plus the full 18-test file and the repo's
  full 689-test suite both green.
- The original bug scenario was reproduced (via `git stash`, running the
  pre-fix code against the exact `IPM_TODAY=2026-08-10` /
  `2026-05-11`-dated-IPM scenario from this task's own Problem section)
  and confirmed fixed. One discrepancy from the task's own note: it
  expected the corrected value to be `2026-08-17`, but the actual
  corrected value (with the bug fixed, Tier 3 taking over) is
  `2026-08-24` — the task's rough note didn't account for `next` mode's
  already-established, separately-tested +7-on-top-of-Tier-3-current
  doubling (see `tests/stamp_scheduled.bats`'s pre-existing "tier3 next"
  test, unchanged by this task). Not a discrepancy in the fix; a
  discrepancy in the original bug report's hand-computed expectation.
- No follow-up tasks filed — scope stayed within the 1h estimate.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — all 3 new staleness
  test cases written test-first, RED verified (2 failing for the
  not-yet-implemented skip, 1 passing at the boundary confirming
  unchanged behavior) before implementing the fix
- Verification (`superpowers:verification-before-completion`): yes —
  design-score gate (79/100), full 689-test repo suite green,
  shellcheck clean, and the original bug scenario reproduced
  before/after via `git stash` to confirm the fix actually closes the
  reported gap
- Systematic debugging (`superpowers:systematic-debugging`): no —
  didn't get stuck
- Receiving code review (`superpowers:receiving-code-review`): pending —
  addressed as part of this implementation PR's `/address-pr` loop
