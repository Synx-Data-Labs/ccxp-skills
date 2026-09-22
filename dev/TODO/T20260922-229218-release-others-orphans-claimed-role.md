---
status: Open
scheduled: 2026-10-05
estimation: 15m
source: Claude Code review on synxdb-team#576 (claim PR for T20260922-539293), 2026-09-22
---

# T20260922-229218: `_tc_release_others` clears `claimed_by` but leaves `claimed_role` orphaned

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
- Observed instance: `synxdb-team` `dev/TODO/T20260914-126541-*.md` was left
  with `claimed_by:` (empty) but `claimed_role: interactive` still set, after
  a `release-others` call from an unrelated claim pickup
  (synxdb-team PR #576). Caught by an independent Claude Code review pass,
  not by any lint — worked around by hand-clearing the field in that PR since
  fixing the shared script was out of scope there.
- Risk: an orphaned `claimed_role` with no `claimed_by` is an inconsistent
  state — tooling that branches on `claimed_role` without also checking
  `claimed_by` is empty could misread a released task as still
  role-assigned. `lint_tasks.py` doesn't appear to catch this combination
  (worth double-checking as part of the fix).
- Done looks like: `_tc_release_others` clears `claimed_role` alongside
  `claimed_by` for every task it releases, mirroring `_tc_release`'s
  clear-on-close contract; existing tests for `release-others` (if any)
  extended to assert `claimed_role` is also cleared.

## Solution

- Add `_tc_fm_set "$f" claimed_role "" || return 1` next to the existing
  `claimed_by` clear at `_session/task_claim.sh:599-600`.
- Sweep other repos' `dev/TODO/*.md` for the same orphaned-`claimed_role`
  pattern (`claimed_by:` empty + `claimed_role:` non-empty) as a one-time
  cleanup, or leave it to self-heal on next pickup of each file — a
  cosmetic-only side effect (dev/quality, no data loss).
