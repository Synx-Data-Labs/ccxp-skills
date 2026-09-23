---
status: Design
scheduled: 2026-08-17
estimation: 1h
source: Discovered while filing follow-up tasks from T20260515-128802 (2026-08-10)
related: T20260515-128802
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
---

# T20260810-632933: `_ipm/stamp-scheduled.sh` Tier 1 silently uses a stale IPM file

## TLDR

- **Type**: bug
- **Problem**: `stamp-scheduled.sh`'s Tier 1 trusts whatever `_ipm_current()` returns unconditionally, even when that IPM file is many weeks stale — silently stamping a past date onto a task's `scheduled:` field instead of falling through to Tier 2/3.
- **Solution**: add a staleness bound (~2 weeks) to Tier 1's *usage* inside `stamp-scheduled.sh` itself — not inside the shared `_ipm_current()` helper, whose other callers legitimately want "newest committed IPM regardless of age."

## Context

- `_ipm/current.sh`'s `_ipm_current()` (`_ipm/current.sh:33-47`) is shared by
  4+ callers (`/rca` Step 6, `/ccxp` Phase 1.1/2a.1.5/2a.5b — see its own
  docstring, `_ipm/current.sh:19-26`) that legitimately want "newest
  committed IPM, however old" — e.g. Phase 2a.1.5 runs before this week's
  IPM commits, so "newest committed" correctly means last week's file; a
  real IPM-cadence gap (a cron deadlock swallowing a Monday IPM, an
  observed recurring scenario) can also legitimately push this to
  multiple weeks old without it being wrong for those callers.
- `stamp-scheduled.sh` (`_ipm/stamp-scheduled.sh:35-40`) is the one caller
  where an old result is actually **wrong**, not just old: it's mapping a
  task to a **current/upcoming board iteration**, and a 13-week-stale
  Monday silently produces a `scheduled:` date in the past.

## Solution

- Add the staleness bound **only in `stamp-scheduled.sh`'s Tier 1 block**
  (`_ipm/stamp-scheduled.sh:35-40`), right after resolving `BASE` from
  `_ipm_current`'s result: if the resolved date is more than 14 days
  behind `$TODAY`, clear `BASE` back to empty — the existing `if [ -z
  "$BASE" ]` Tier-2 fallthrough (`_ipm/stamp-scheduled.sh:42`) then
  naturally takes over, no new control-flow needed.
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

- [ ] `tests/stamp_scheduled.bats` — new case: a stale (>14 days old) IPM file present, no token override → Tier 1 is skipped and Tier 3 (next-Monday) is used instead (`_ipm/stamp-scheduled.sh:35-42`)
- [ ] Existing cases (fresh IPM file, Project-API override, no-token fallback) still pass — full `bats tests/stamp_scheduled.bats` suite green

## Done criteria

- [ ] Fix shipped in `_ipm/stamp-scheduled.sh`'s Tier 1 block, staleness-bound test passing — `tests/stamp_scheduled.bats`
- [ ] Existing `tests/stamp_scheduled.bats` suite still green — no regressions in fresh-IPM/Project-API/no-token cases

## Migrated (2026-09-14)

- Migrated from `hub-repo/dev/TODO/` by T20260827-420045 — the task's
  `target-repo: your-org/private-skills-repo` field (set 2026-08-10, before
  the ccxp-skills split shipped) is stale: `_ipm/` is now ccxp-skills' own
  shared lib, so this is "work about ccxp-skills itself" per that repo's
  CLAUDE.md — landing here directly instead of `private-skills-repo`.
