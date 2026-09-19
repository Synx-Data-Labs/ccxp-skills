---
status: Open
scheduled: 2026-08-17
estimation: 1h
source: Discovered while filing follow-up tasks from T20260515-128802 (2026-08-10)
related: T20260515-128802
---

# T20260810-632933: `_ipm/stamp-scheduled.sh` Tier 1 silently uses a stale IPM file

## Problem

- `_ipm/stamp-scheduled.sh` resolves the base Monday via a 3-tier hybrid: (1) newest committed `*-ipm-weekly.md`, (2) Project API, (3) next-Monday computed from today.
- Tier 1 is tried first and, if it finds ANY IPM file, is used unconditionally — even if that file is many weeks stale. `_ipm/current.sh` correctly excludes `2026-06-29`/`2026-06-22`/`2026-06-15-ipm-weekly.md` as `**Status**: Pre-IPM staging` stubs (verified: `bash ~/.claude/skills/_ipm/current.sh dev/JOURNAL` in this repo resolves `dev/JOURNAL/2026-05-11-ipm-weekly.md`), so the actual file Tier 1 trusts is **~13 weeks stale** as of 2026-08-10, not the ~6 weeks a naive `ls -t` would suggest. `stamp-scheduled.sh <file> next` returned `2026-05-18` (`2026-05-11` + 7 days) — a date in the past relative to today, instead of the correct `2026-08-17`.
- Other tasks in this repo correctly show `scheduled: 2026-08-10`/`2026-08-03` — presumably stamped via Tier 2 (Project API, token-gated) in sessions that had a PAT, or hand-corrected. A session without a token silently gets the wrong, stale answer from Tier 1 with no warning.
- **Note as of migration (2026-09-14)**: `_ipm/` now lives in `ccxp-skills`
  (post T20260827-280088 split) — re-verify the file's exact behavior/line
  numbers at pickup against this repo's copy, not the historical
  `hub-repo`-relative description above.

## Solution (not yet designed — sketch only)

- Add a staleness bound to Tier 1: if the newest committed IPM file's date is more than ~2 weeks behind `$TODAY`, skip it and fall through to Tier 2/3 instead of trusting it.
- Alternative: keep Tier 1 but log a warning (to stderr, non-blocking) when it returns a Monday more than N days in the past, so a caller can at least notice.

## Test plan

- [ ] `tests/stamp_scheduled.bats` — new case: a stale (>2 weeks old) IPM file present, no token — verify Tier 1 is skipped and Tier 3 (next-Monday) is used instead
- [ ] Existing cases (fresh IPM file, Project-API override, no-token fallback) still pass

## Done criteria

- [ ] Fix shipped in `ccxp-skills`, staleness-bound test passing
- [ ] Existing `tests/stamp_scheduled.bats` suite still green

## Migrated (2026-09-14)

- Migrated from `hub-repo/dev/TODO/` by T20260827-420045 — the task's
  `target-repo: your-org/private-skills-repo` field (set 2026-08-10, before
  the ccxp-skills split shipped) is stale: `_ipm/` is now ccxp-skills' own
  shared lib, so this is "work about ccxp-skills itself" per that repo's
  CLAUDE.md — landing here directly instead of `private-skills-repo`.
