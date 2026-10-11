---
status: Done
scheduled: 2026-10-05
estimation: 2
source: 2026-10-10 fact-check pass for a companion ccxp-skills blog deep-dive on /ipm (sibling repo synxdata.com); maintainer (Shine) decision recorded inline below
related: ipm/SKILL.md (steps 4, 5), retro/SKILL.md:213 (generic drift grading, untouched), T20260924-232855 (estimation → story points), dev/JOURNAL/2026-10-01-T20260924-232855-estimation-to-story-points.md:35-41, T20261005-554581, T20261005-639913
claimed_by:
claimed_role:
description: Drop /ipm's never-run 20h/3-line hour budget and the unused day-by-day execution-order template; replace with queue-order + human judgment
---

# T20261010-665166: Drop the `/ipm` 20h/3-line budget split; simplify `ipm-weekly.md`'s output shape

## Problem

- **Type**: chore
- `ipm/SKILL.md` step 4 computes a 20h weekly budget split into three
  explicit lines (~12h product, ~4h infra/tooling, ~4h slack) and step 5's
  template renders a `Line` column, a "Cut line at Xh product" math note, a
  full "Recommended execution order" section (day-by-day Mon–Fri tables, a
  "Parallelism that makes the budget fit" table, "Critical-path
  checkpoints"), and a hard-cap-vs-slack-reserve rule for mid-week additions.
- **None of this has ever run.** Zero `dev/JOURNAL/*-ipm-weekly.md` files
  exist in this repo's history (`ls dev/JOURNAL/*-ipm-weekly.md` → no
  match). `dev/JOURNAL/2026-10-01-T20260924-232855-estimation-to-story-points.md:35-41`
  already flags this and explicitly scoped the redesign out at the time.
- `T20260924-232855` (commit `308f601`) replaced `estimation:` duration
  buckets (`2h`/`1d`/`30m`) with a bare Fibonacci point enum (`{1,2,3,5,8}`)
  repo-wide, but deliberately left `ipm/SKILL.md`'s hour-based budget
  language untouched — task files no longer even carry hour estimates to
  sum against an "~20h" ceiling, so the skill is now internally
  inconsistent with the rest of the repo.
- Done looks like: step 4's computed/enforced hour split is gone; carry-over
  stays automatic and unconditional; new picks are queue-order + the
  developer's own judgment (optionally informed by point totals), with no
  computed or enforced split, no categorical Product/Infra-tooling lines,
  and no numeric ceiling the skill itself enforces. `ipm-weekly.md`'s step 5
  template drops the `Line` column/categorization, the budget-cut math, and
  the entire "Recommended execution order" section; it keeps one committed
  list (Task/Status/Est/Deadline/Why — no `Line`), "Carry-over candidates,"
  "Mid-week additions" (plain running list, no budget-cap rule), "Considered
  but cut," and "Notes."

## Context

- This task is deliberately scoped together with `T20261005-554581` (drain
  gate reads a retired board) and `T20261005-639913` (remove
  `ROADMAP_TARGET_REPO`) in one PR — all three touch `ipm/SKILL.md`'s step
  4/5/5a/5b and would leave it internally inconsistent if done separately.
- Infra/tooling work doesn't lose visibility — when picked, it's still named
  with a plain "why this now" annotation in the committed list's `Why`
  column; it just isn't a protected quota line anymore.
- `retro/SKILL.md:213` grades drift generically off whatever task IDs appear
  in `ipm-weekly.md`, not a specific column schema — no change needed there.
- Example rows in `ipm/SKILL.md`'s template that use old duration notation
  (`2h`, `1d`, `30m`) get updated to the point scale (`{1,2,3,5,8}`) as part
  of this same edit.

## Done criteria

- [x] `ipm/SKILL.md` step 4 has no computed/enforced hour budget — carry-over
      unconditional, new picks = queue order + judgment
- [x] `ipm/SKILL.md` step 5 template drops `Line`, the cut-line math, and the
      full "Recommended execution order" section; mid-week additions drop
      the hard-cap-vs-slack-reserve rule
- [x] Remaining template rows use `{1,2,3,5,8}` point notation, not
      `2h`/`1d`/`30m`
- [x] `retro/SKILL.md` untouched (out of scope, confirmed generic)

## Closed (2026-10-10)

- Scoped together with T20261005-554581 (file-only drain gate) and
  T20261005-639913 (remove `ROADMAP_TARGET_REPO`) in one PR — all three
  touch `ipm/SKILL.md` steps 4/5/5a/5b and would leave it internally
  inconsistent done separately.
- Step 4 renamed "Budget cut" → "Commit new picks": carry-over is
  unconditional (unchanged); new picks walk `queue.md`'s existing order
  top-down by judgment, optionally informed by `estimation` point totals,
  with no computed/enforced split and no numeric ceiling. Infra/tooling
  picks get a one-line "why this now" in the committed table's `Why`
  column instead of a protected quota line.
- Step 5's template dropped: the `Line` column and Product/Infra-tooling
  categorization, the "Cut line at Xh product" math note, the whole
  "Recommended execution order" section (day-by-day Mon–Fri tables, the
  "Parallelism" table, "Critical-path checkpoints"), and mid-week
  additions' hard-cap-vs-slack-reserve rule. Kept: one committed-list table
  (Task/Status/Est/Deadline/Why — dropped `Line` and `Cumulative`, per the
  task's "your judgment on which columns still earn their place" framing —
  `Cumulative` only made sense against a budget total to run against),
  "Carry-over candidates," "Mid-week additions" (now a plain running list),
  "Considered but cut," "Notes." Example rows updated to `{1,2,3,5,8}` point
  notation.
- Step 6's Slack template dropped its `Budget: 20h, committed: {N}h` line
  (replaced with a plain `Committed: {N} tasks` count) — same reasoning,
  no budget total left to report against.
- `retro/SKILL.md` confirmed untouched and unaffected: its drift grading
  (line 213) keys off task IDs appearing in `ipm-weekly.md`, not a specific
  column schema.
- Verification: `bats tests/*.bats _docs/*.bats _slack/*.bats` green (7
  pre-existing unrelated failures, confirmed present on `main` before this
  branch); `lint_paragraphs.py`/`lint_refs.py`/`lint-docs.sh` clean on
  `ipm/SKILL.md`; `skill_score.py --check` passes (50 skills at or above
  baseline — `ipm`'s own score needed two paragraphs trimmed under 60 words
  and task-ID citations pulled out of the prose to clear the ratchet after
  this edit, a direct instance of "history belongs in dev/JOURNAL, not
  skill prose").

## Skills invoked

- Verification (`superpowers:verification-before-completion`): yes — full
  bats suite + doc/task lints + the skill-quality ratchet, before PR
