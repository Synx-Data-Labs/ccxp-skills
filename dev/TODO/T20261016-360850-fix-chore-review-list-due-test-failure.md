---
status: Open
estimation: 1
source: T20261016-316464 (discovered while verifying zero-behavior-change on the test_helper extraction)
---

# T20261016-360850: Fix pre-existing failure in `chore_review.bats` "list-due" test

## Problem

- **Type**: bug
- `tests/chore_review.bats::"list-due: selects a row >= 1 iteration old with a
  blank Outcome"` fails on `main` **before any test_helper-extraction change**
  — confirmed by reverting `tests/chore_review.bats` to its pre-T20261016-316464
  content and re-running: `bats tests/chore_review.bats` still fails the same
  test with the same assertion (`[[ "$output" == *"T20260601-111111"* ]]'
  failed`), so this is unrelated to that refactor.
- Fixture: a `dev/chore.md` row with `Started = 2026-06-01`, queried with
  `--today 2026-07-02` (31 days later, past the 7-day/1-iteration threshold
  per `retro/scripts/chore-review.sh:18`) — expected to appear in `list-due`
  output but `$output` does not contain the task ID at all.
- Not caught earlier because CI's `bats` job apparently still reports overall
  success (needs confirming whether this test is already red on `main` in CI,
  or whether CI's run differs by date/timezone — see Context).

## Context

- Found while verifying "zero change in test outcomes" for T20261016-316464
  (shared `tests/test_helper.bash` extraction) — that task's test plan
  requires an identical before/after pass/fail comparison, which surfaced
  this as already-failing on `main`, not introduced by that PR.
- `retro/scripts/chore-review.sh:52,71-72,94` compute `age_days` from
  `--today` minus the row's `Started` date via `date -u -d`/`date -u -j -f`
  epoch math — worth checking for a macOS/GNU `date` portability gap on this
  host, or a table-column-parsing issue specific to the fixture's markdown.

## Solution

- Root-cause the `list-due` date/column logic (or confirm it's a
  macOS-`date`-only reproduction and already passes in CI's Linux runner,
  in which case this is an environment-only flake to guard against rather
  than a logic bug).
- Alternatives rejected: fixing this inside T20261016-316464 — rejected
  per `/drive`'s "one PR = one scope" rule; this bug is unrelated to the
  test_helper extraction and predates it.

## Test plan

- [ ] `bats tests/chore_review.bats` passes in full, including the
  "selects a row >= 1 iteration old" test
- [ ] Confirm whether this also fails in CI today (check the most recent
  `bats` GitHub Actions run's full log, not just overall pass/fail, since a
  suite-level failure should already be visible if this test is red there
  too)

## Done criteria

- [ ] `tests/chore_review.bats` line 38's assertion passes —
  `bats tests/chore_review.bats`
- [ ] Root cause documented (date-math bug vs. OS-specific `date` flag
  gap vs. fixture issue)
