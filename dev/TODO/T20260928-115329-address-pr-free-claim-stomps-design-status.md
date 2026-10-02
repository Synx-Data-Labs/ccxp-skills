---
status: Open
estimation: 1
source: this conversation, 2026-09-28 — independent review finding on PR #164
related: T20260610-248248
---

# T20260928-115329: `address-pr`'s "free" claim procedure stomps `status: Design` back to `In Progress`

## Problem

- **Type**: bug
- `_session/task_claim.sh`'s `_tc_acquire` (the `none`/unclaimed branch)
  unconditionally sets `status: In Progress` whenever `claimed_by` is
  empty — it never reads the task's current `status` first.
- `address-pr/SKILL.md` §1.6's `free` procedure (a PR whose task exists on
  `main` but is unclaimed) calls `task_claim.sh acquire <id>` directly,
  with no correction step afterward. So a task already sitting at
  `status: Design` (e.g. just recorded by `/incept`, no implementation
  done yet) gets silently flipped to `In Progress` the moment
  `/address-pr` claims it — misrepresenting the task as actively being
  coded.
- `/ipm` step 3.4 (formerly `ccxp/SKILL.md` Phase 2a.3 step 4) already hit
  this exact issue (T20260610-248248) and has the fix in place: `acquire`
  then `bash <skills-root>/_session/status.sh <task-id> Design` to correct
  the status back. `address-pr/SKILL.md` §1.6's `free` procedure has no
  equivalent step.
- Surfaced via an independent review on [PR #164](https://github.com/Synx-Data-Labs/ccxp-skills/pull/164) (`incept/SKILL.md`'s own
  Open→Design fix), which correctly noted that fix alone doesn't close
  the loop: it only helps when `/address-pr`'s claim step is skipped
  entirely (as it was, by explicit user choice, for [PR #163](https://github.com/Synx-Data-Labs/ccxp-skills/pull/163)) — a strict
  run of the documented `free` procedure still stomps the status.

## What to do

- In `address-pr/SKILL.md` §1.6's `free` procedure, after
  `task_claim.sh acquire <id>` succeeds, read the task's status as it was
  *before* the acquire call; if it was `Design` (or anything other than
  `Open`/empty), correct it back via `status.sh <id> <original-status>` —
  mirroring `/ipm` step 3.4's existing pattern.
- Consider whether `new` (T20260918-404944's claim-on-PR-branch
  procedure) has the same gap, since it also calls `acquire` directly.

## Done when

- [ ] `address-pr/SKILL.md` §1.6's `free` (and `new`, if applicable)
  procedure preserves a pre-existing `Design` status across the claim
  instead of overwriting it to `In Progress`
- [ ] Cross-referenced against `/ipm` step 3.4's existing correction
  pattern for consistency

## Out of scope

- Changing `_tc_acquire` itself to read/preserve status — the fix belongs
  in the caller (per `ccxp/SKILL.md`'s own precedent), not the shared
  primitive.
