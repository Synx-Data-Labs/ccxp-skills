---
status: Coding
estimation: 1h
source: discovered while /address-pr-ing synxdb-team PR #666 (a /top queue reorder)
related: T20260718-160579, T20260922-324422, T20260918-404944
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260925-332662: `pr_task_id.sh` signal 3 (commit-message scan) false-positives on `/top`'s own commit message

## Problem

- `_session/pr_task_id.sh` / `task_claim.sh pr-owner` misattributed
  synxdb-team PR #666 to task `T20260806-147372` even though the PR **does
  not implement that task** — it's a pure `dev/TODO/queue.md` reorder
  produced by `/top 147372`.
- Root cause: signal 3 (PR commit `messageHeadline` scan) matched the
  literal string `T20260806-147372` inside the commit's own subject line —
  `docs(queue): move T20260806-147372 to the top`, exactly the commit
  message `/top`'s own SKILL.md prescribes (§4). The task ID appears here
  as **data** (which task got reordered), not as a "this commit
  implements/closes that task" signal the way branch-name or `Task:` link
  correlation intends.
- Consequence: `pr-owner` reported `owned:cdw:/tmp/T20260806-147372-claim-Og8E`
  (the real owner of the *actual* T20260806-147372 work) for a PR that has
  nothing to do with that session's in-flight work — `/address-pr` would
  have deferred a perfectly mergeable, unrelated bookkeeping PR, or worse,
  written Project-board/claim state against a task it wasn't touching if a
  future revision of the loop trusted `pr-owner` for writes without this
  read-only sanity check.
- Not unique to `/top` — any skill whose commit-message convention embeds a
  bare `T{id}` as *data* (referring to another task) rather than as "this
  PR's own task" will trip the same false positive. `/top`, `/bottom`, and
  `/stage --before` all do this by design (their commit messages name the
  task(s) being reordered).

## Context

- `_session/pr_task_id.sh` tries three signals in order: branch name → PR
  body `Task:` link → commit `messageHeadline` scan. Signal 3 is the
  weakest — it has no structural marker distinguishing "this task" from
  "a task mentioned in the message" the way a `Task:`-prefixed line does.
- Worked around manually this time: recognized the false positive, skipped
  the §1.5/§1.6 Project-board and claim writes for `T20260806-147372`,
  and drove PR #666 through `/address-pr`'s merge loop treating it as
  untracked (no task correlation), per the skill's own fail-safe guidance
  for suspect correlations.

## Possible fix

- Narrow signal 3 to only match a `T{id}` immediately following a
  recognized verb/prefix this repo's own commit conventions use for "this
  commit closes/implements task X" (e.g. `T{id}:` at the start of the
  subject, or inside parens at the end — `(T{id})`), rather than any bare
  `T{id}` substring anywhere in the message.
- Alternative: have `/top`/`/bottom`/`/stage --before` skip signal-3
  correlation entirely for their own commits (e.g. by never having their
  commit ever be the *sole* commit correlated — not obviously simpler than
  fixing the regex).

## Test plan

- [ ] Add a `session_pr_task_id.bats` case: a commit message of the shape
      `docs(queue): move T{other-id} to the top` must NOT resolve to
      `T{other-id}` via signal 3.
- [ ] Existing signal-3 true-positive cases (e.g. `fix(x): ... (T{id})`)
      still pass.
