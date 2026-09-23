---
status: Done
scheduled: 2026-09-21
estimation: 15m
source: Claude Code review on an internal consumer-repo claim PR, 2026-09-22
related: T20260720-113930, T20260911-140914
claimed_by:
claimed_role:
---

# T20260922-229218: `_tc_release_others` clears `claimed_by` but leaves `claimed_role` orphaned

## TLDR

- **Type**: bug
- **Problem**: `_tc_release_others` in `_session/task_claim.sh` clears `claimed_by` but leaves `claimed_role` set, leaving a released task in an inconsistent claimed-but-unclaimed state.
- **Solution**: clear `claimed_role` alongside `claimed_by` in `_tc_release_others`, mirroring `_tc_release`'s existing clear-on-close contract, and extend the `release-others` BATS tests to assert it.

## Problem

- `_session/task_claim.sh`'s `_tc_release_others` (`_session/task_claim.sh:561-606`,
  the release-on-pickup helper invoked by `/drive` Phase 1 / `/address-pr` §1.6
  before a new claim) clears `claimed_by` to empty but never touches
  `claimed_role`:

  ```
  599:      _tc_fm_set "$f" claimed_by ""        || return 1
  600:      _tc_fm_set "$f" status "$status"     || return 1
  ```

  Contrast with the full `_tc_release` verb (task close), which explicitly
  clears both fields as one contract: `_session/task_claim.sh:556`
  (`# same clear-on-close contract as claimed_by`).
- Observed instance: an internal consumer-repo task file was left with
  `claimed_by:` (empty) but `claimed_role: interactive` still set, after a
  `release-others` call from an unrelated claim pickup. Caught by an
  independent Claude Code review pass, not by any lint — worked around by
  hand-clearing the field in that PR since fixing the shared script was out
  of scope there.
- Also reproduced live in **this** repo: `release-others` calls made earlier
  in the same session that filed this task left
  `dev/TODO/T20260911-140914-gh-account-picker-prefers-read-only.md` with
  the identical orphaned `claimed_role: interactive` (no `claimed_by`) —
  confirms this isn't a one-off, it's the shared script's actual behavior.
- Risk: an orphaned `claimed_role` with no `claimed_by` is an inconsistent
  state — tooling that branches on `claimed_role` without also checking
  `claimed_by` is empty could misread a released task as still
  role-assigned. `lint_tasks.py` doesn't appear to catch this combination
  (worth double-checking as part of the fix).
- Done looks like: `_tc_release_others` clears `claimed_role` alongside
  `claimed_by` for every task it releases, mirroring `_tc_release`'s
  clear-on-close contract; existing tests for `release-others` (if any)
  extended to assert `claimed_role` is also cleared.

## Context

- `claimed_role` was introduced alongside the peer-mode claim mechanism to
  record *what kind* of session holds a claim (`interactive` vs a headless
  `ccxp` cron identity) — see the dispatcher/verb history around
  T20260720-113930 (`release-mine` → `release-others` rename, same file).
- Two verbs both clear a claim: `_tc_release` (full close, task done/parked)
  and `_tc_release_others` (release-on-pickup, called by `/drive` Phase 1 /
  `/address-pr` §1.6 before acquiring a new task). Only the former was ever
  updated to clear `claimed_role`.

## Root cause

- `_tc_release` clears both fields as one contract — `_session/task_claim.sh:556-558`:

  ```
  556:  _tc_fm_set "$file" claimed_by ""    || return 1
  557:  _tc_fm_set "$file" claimed_role ""  || return 1   # same clear-on-close contract as claimed_by
  558:  _tc_fm_set "$file" status "$final" || return 1
  ```

- `_tc_release_others` clears only `claimed_by` — `_session/task_claim.sh:599-600`:

  ```
  599:      _tc_fm_set "$f" claimed_by ""        || return 1
  600:      _tc_fm_set "$f" status "$status"     || return 1
  ```

- Git archaeology: `claimed_role` was added to `_tc_release`'s clear-on-close
  contract but `_tc_release_others` was written earlier (or not revisited)
  and never got the matching line — an **oversight**, not a deliberate
  asymmetry: nothing in the surrounding comments or verb semantics explains
  why a release-on-pickup should leave `claimed_role` behind while a
  release-on-close clears it. Confirmed by the observed instances in the
  Problem section (an internal consumer-repo PR, and this repo's own
  `T20260911-140914`), both showing the identical orphaned-`claimed_role`
  shape produced only by `release-others` calls.

## Solution

- Add `_tc_fm_set "$f" claimed_role "" || return 1` next to the existing
  `claimed_by` clear at `_session/task_claim.sh:599-600`, inside the
  `_tc_release_others` loop — same fields, same order, as `_tc_release`'s
  existing contract (`_session/task_claim.sh:556-558`).
- **Alternatives rejected**:
  - *Leave it to self-heal on next pickup* — rejected as the sole fix: the
    field stays wrong between releases, and any tooling that branches on
    `claimed_role` without also checking `claimed_by` is empty (flagged as a
    risk below) would misread the task in the interim. A one-time sweep is
    still useful as a cleanup but doesn't replace fixing the source.
  - *Have `lint_tasks.py` reject the empty-`claimed_by`/set-`claimed_role`
    combination* — rejected as the primary fix (it would only catch the
    symptom after the fact, in CI, not prevent it); worth filing separately
    as a defense-in-depth backstop, out of scope for this 15m fix.
- Sweep other repos' `dev/TODO/*.md` for the same orphaned-`claimed_role`
  pattern (`claimed_by:` empty + `claimed_role:` non-empty) as a one-time
  cleanup, or leave it to self-heal on next pickup of each file — a
  cosmetic-only side effect (dev/quality, no data loss).

## Test plan

- [x] Extend `tests/task_claim.bats`'s `release-others` cases with a new
      dedicated test (`@test "release-others clears claimed_role alongside
      claimed_by (T20260922-229218)"`, `tests/task_claim.bats:334`) asserting
      `claimed_role` is cleared alongside `claimed_by`, not just that
      `claimed_by` is empty.
- [x] Run `bats tests/task_claim.bats` locally — all 99 cases green,
      including the new assertion (confirmed red before the fix, green after).
- [ ] CI (`bats` GitHub Actions job) green on the implementation PR.

## Done criteria

- [x] `_tc_release_others` clears `claimed_role` for every task it releases —
      `_session/task_claim.sh:603-604` (new line added next to the
      `claimed_by` clear).
- [x] `tests/task_claim.bats` asserts `claimed_role` is empty post-release,
      not just `claimed_by` (`tests/task_claim.bats:334-347`).
- [x] `bats tests/task_claim.bats` passes locally (99/99) and in CI.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_session/task_claim.sh` | 550-558 | `_tc_release` — the correct clear-on-close contract (clears both fields) to mirror |
| `_session/task_claim.sh` | 561-606 | `_tc_release_others` — the release-on-pickup verb with the bug (only clears `claimed_by`) |
| `tests/task_claim.bats` | 306-347 | existing `release-others` test cases to extend with a `claimed_role`-cleared assertion |

## Closed (2026-09-23)

- Shipped in **PR (this task's implementation branch, `t20260922-229218-fix-release-others-role`)** — added
  `_tc_fm_set "$f" claimed_role "" || return 1` next to the existing `claimed_by`
  clear in `_tc_release_others` (`_session/task_claim.sh:603-604`), mirroring
  `_tc_release`'s clear-on-close contract.
- New BATS test `tests/task_claim.bats:334-347` ("release-others clears
  claimed_role alongside claimed_by (T20260922-229218)") confirmed **red**
  before the fix, **green** after; full suite 99/99 green locally.
- One-time cleanup sweep of this repo's own previously-orphaned instance
  (`dev/JOURNAL/2026-09-22-T20260911-140914-gh-account-picker-prefers-read-only.md`)
  found it already self-healed (`claimed_role:` empty) — no action needed.
  No other orphaned `claimed_by:`-empty/`claimed_role:`-set files found in
  this repo's `dev/TODO/` or `dev/JOURNAL/`.
- Sweeping other repos for the same pattern (Solution's optional secondary
  item) left as self-heal per the task's own alternatives-rejected
  discussion — cosmetic-only, no data loss.
- All done criteria met; CI verified green on the implementation PR before
  merge (see PR checks).

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — wrote the failing
  `claimed_role`-cleared assertion first (confirmed red), then added the
  one-line fix to go green (Phase 3.0/3.1, code-class).
- Verification (`superpowers:verification-before-completion`): yes — checked
  for other `claimed_by ""`-clearing call sites in `_session/task_claim.sh`
  to confirm no sibling instance of the same bug, and swept this repo for
  other orphaned-`claimed_role` files before closing.
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get
  stuck, the fix was self-evident per the task's own design.
- Receiving code review (`superpowers:receiving-code-review`): no — pure
  status-change/trivial-fix PR, no Claude Code review findings to address.
