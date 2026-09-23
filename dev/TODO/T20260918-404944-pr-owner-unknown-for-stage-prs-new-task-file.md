---
status: Coding
estimation: 1h
source: this conversation, 2026-09-18
related: T20260718-160579, T20260922-324422
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260918-404944: `task_claim.sh pr-owner` always returns `unknown` for `/stage` PRs that introduce a brand-new task file

## Problem

- **Type**: bug (tooling gap in `_session/task_claim.sh`, discovered while running `/address-pr`
  on PR #39, a `/stage` PR staging task `T20260918-214522`)
- `_tc_pr_owner` → `_tc_resolve_task_location` resolves the same-repo case by listing
  `dev/TODO` **on `main`** via the GitHub contents API (`_session/task_claim.sh:668`,
  `?ref=main`) and looking for a file whose name starts with the task id.
- `/stage`'s own documented design (`stage/SKILL.md` step 3) is to commit the queue.md
  append **plus the new task file itself** (when it's the first time that task is being
  staged) in the *same* PR, and then hand that PR to `/address-pr` to merge — i.e. the task
  file legitimately does not exist on `main` yet at the moment `/address-pr` is asked to
  drive the PR that will put it there.
- Result: `pr-owner` can never resolve the file → `_tc_resolve_task_location` returns 1 →
  `pr-owner` prints `unknown` → `/address-pr`'s §1.6 fail-safe says defer, never merge.
  Taken literally, `/address-pr` can never merge a `/stage` PR for a task that didn't
  already exist on `main` — contradicting `/stage`'s own instruction to drive such PRs
  through `/address-pr`.
- This is a **different** root cause from T20260718-160579 (stale branch-name-vs-body
  `Task:` link mismatch on a *rescoped* PR): here the file is simply not on `main` yet by
  design, not mislinked.
- Worked around manually this run by: confirming the PR body's staged task id matches the
  one new file in the diff exactly, confirming the new task file carries no `claimed_by`
  (freshly authored, nothing to race), and proceeding since `/stage` PRs are pure
  lifecycle bookkeeping with no implementation to steal — then filing this task per
  `/address-pr`'s own escape-hatch instructions for an `unknown` verdict.
- Done looks like:
  - `_tc_pr_owner` (or its caller in `/address-pr` §1.6) recognizes "this PR's diff adds
    the task file that `_tc_resolve_task_location` failed to find on `main`" as a distinct
    case — e.g. `untracked`/`free`-like, not `unknown` — so `/stage` PRs (and `/new-task`
    PRs that immediately `/stage`) resolve without a manual override.
  - Add a unit-test case alongside the existing `_tc_resolve_task_location` /
    `_tc_pr_owner` tests for "task file present in the PR diff but absent on `main`".
