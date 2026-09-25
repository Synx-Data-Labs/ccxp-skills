---
status: Done
estimation: 1h
source: discovered while /address-pr-ing synxdb-team PR #666 (a /top queue reorder)
related: T20260718-160579, T20260922-324422, T20260918-404944
claimed_by:
claimed_role:
scheduled: 2026-09-21
---

# T20260925-332662: `pr_task_id.sh` signal 3 (commit-message scan) false-positives on `/top`'s own commit message

## TLDR

- **Type**: bug
- **Problem**: `session_pr_task_id`'s signal 3 (commit `messageHeadline` scan,
  `_session/_lib.sh:304-308`) matched *any* bare `T<id>` substring, so a
  commit that names another task as **data** (e.g. `/top`'s own
  `docs(queue): move T<id> to the top`) got misattributed as "this PR
  implements/closes `T<id>`".
- **Solution**: narrow signal 3 to only match a `(T<id>)`-parenthesized or
  leading `T<id>:`-prefixed mention — the repo's actual "this commit
  closes/implements task X" convention — never a bare substring anywhere in
  the message.

## Problem

- `_session/pr_task_id.sh` / `task_claim.sh pr-owner` misattributed
  synxdb-team PR #666 to task `T20260806-147372`, even though the PR **does
  not implement that task** — it's a pure `dev/TODO/queue.md` reorder
  produced by `/top 147372`.
- Root cause: signal 3 (`_session/_lib.sh:304-308`, `grep -oE
  'T[0-9]{8}-[0-9]+'`) matched the literal string `T20260806-147372` inside
  the commit's own subject line — `docs(queue): move T20260806-147372 to the
  top` (exactly the commit message `top/SKILL.md:137` prescribes). The task
  ID appears here as **data** (which task got reordered), not as a "this
  commit implements/closes that task" signal the way branch-name or `Task:`
  link correlation intends.
- Consequence: `pr-owner` reported the real owner of the *actual*
  `T20260806-147372` work for a PR that has nothing to do with that
  session's in-flight work — `/address-pr` would have deferred a perfectly
  mergeable, unrelated bookkeeping PR, or worse, written Project-board/claim
  state against a task it wasn't touching, if a future revision of the loop
  trusted `pr-owner` for writes without a read-only sanity check.
- Not unique to `/top` — `bottom/SKILL.md` and `stage/SKILL.md --before` use
  the same "name the reordered task(s) in the commit subject" convention, so
  any of their commits trips the identical false positive.

## Context

- Design approved in-conversation 2026-09-25 — a self-evident regex fix with
  the root cause and fix already diagnosed at filing time; no separate
  design-PR checkpoint needed before implementation.
- `_session/pr_task_id.sh` (`session_pr_task_id`, `_session/_lib.sh:270-304`)
  tries three signals in order: PR body `Task:` link → branch name → commit
  `messageHeadline` scan. Signal 3 is the weakest — unlike signals 1/2, it
  had no structural marker distinguishing "this task" from "a task
  mentioned in the message."
- Git archaeology: signal 3's unguarded `grep -oE 'T[0-9]{8}-[0-9]+'` dates
  to this repo's initial public release (`890c1ce2`, 2026-09-13, squashed
  from the private history it was split from) — a deliberate fallback
  heuristic from day one, not a later regression; this task is the first
  time its bare-substring behavior was identified as a false-positive
  source.
- Worked around manually at the time: recognized the false positive,
  skipped the Project-board/claim writes for `T20260806-147372`, and drove
  PR #666 through `/address-pr`'s merge loop treating it as untracked, per
  the skill's own fail-safe guidance for suspect correlations.
- Real convention confirmed via `git log --format='%s' | grep -oE
  '\(T[0-9]{8}-[0-9]+\)'`: 20+ distinct commits in the last 300 use a
  trailing `(T<id>)` to mark "this commit closes/implements task X" — no
  existing commit uses a bare leading `T<id>:` form, but the task's own
  possible-fix note allows for it defensively.

## Solution

- Narrow signal 3's extraction in `_session/_lib.sh:304-308` to only match:
  - a trailing `(T<id>)` — the repo's actual, evidenced convention, or
  - a leading `T<id>:` at the very start of the subject line
  — via `grep -oE '\(T[0-9]{8}-[0-9]+\)|^T[0-9]{8}-[0-9]+:'`, then extract
  the bare ID from whichever matched. A bare `T<id>` substring anywhere else
  in the message no longer resolves.
- Leave signals 1 (body `Task:` link) and 2 (branch name) untouched — they
  already have structural anchors and are not implicated in this bug.

**Alternatives considered and rejected**:

- *Have `/top`/`/bottom`/`/stage --before` skip signal-3 correlation
  entirely for their own commits* — rejected: would require every
  queue-reorder skill to special-case its own commit shape (and any future
  skill with the same "name a task as data" pattern would need the same
  carve-out), vs. fixing the one shared, general-purpose regex in
  `_lib.sh` once.
- *Drop signal 3 entirely* — rejected: it's still a useful last-resort
  correlation for PRs whose branch was never renamed and whose body has no
  `Task:` link; the fix narrows its precision without removing its recall
  for the actual "this commit closes X" convention.

## Test plan

- [x] `tests/session_pr_task_id.bats`: a commit message of the shape
      `docs(queue): move T<other-id> to the top` must NOT resolve to
      `T<other-id>` via signal 3 (new case, T20260925-332662).
- [x] `tests/session_pr_task_id.bats`: existing signal-3 true-positive case
      updated to the real `fix(x): ... (T<id>)` convention and still passes.
- [x] `tests/session_pr_task_id.bats`: new case for the leading `T<id>:`
      subject-prefix form also resolves correctly.
- [x] Full `bats tests/session_pr_task_id.bats` run green (8/8).
- [ ] Full repo `bats tests/*.bats` run green (no regressions in unrelated
      suites).

## Done criteria

- [x] Signal 3 no longer matches a bare `T<id>` substring anywhere in a
      commit message — mapped to `tests/session_pr_task_id.bats::a bare
      T<id> mentioned as DATA in a commit subject does not false-positive
      via signal 3 (T20260925-332662)`.
- [x] Signal 3 still resolves the real `(T<id>)`-parenthesized
      "closes/implements" convention — mapped to
      `tests/session_pr_task_id.bats::falls back to commit messageHeadline
      scan when neither body nor branch match (parens form)`.
- [x] Fix lands in `_session/_lib.sh:304-308` (the `session_pr_task_id`
      signal-3 block), not duplicated per-skill.

## Root cause

- `_session/_lib.sh:299-302` (pre-fix location; the block is now at
  `304-308` after the added signal-3 doc comment): `grep -oE
  'T[0-9]{8}-[0-9]+'` over
  every commit's `messageHeadline`, unconditionally taking the first
  substring match. No positional/structural anchor distinguishes "this
  commit's own task" from "a task mentioned as data."
- Introduced at the repo's initial public release (`890c1ce2`,
  2026-09-13) as one of three deliberate fallback signals — a reasonable
  heuristic when the only commits scanned name their *own* task, but
  unsound once a skill's convention (here, `top/SKILL.md:137`'s
  `docs(queue): move T<id> ... to the top`) legitimately names *other*
  tasks in the subject.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_session/_lib.sh` | `270-304` | `session_pr_task_id` — the 3-signal PR→task correlator; signal 3 is the fix target |
| `_session/pr_task_id.sh` | `1-25` | thin CLI wrapper around `session_pr_task_id`, unchanged |
| `tests/session_pr_task_id.bats` | `1-101` | unit tests for the correlator; updated true-positive fixture + new false-positive/leading-colon cases |
| `top/SKILL.md` | `137` | source of the `docs(queue): move T<id> ... to the top` commit convention that triggers the false positive |

## Closed (2026-09-25)

- Shipped in **PR #150** (rebase-merged to `main` at `1204564`):
  https://github.com/Synx-Data-Labs/ccxp-skills/pull/150
- All done criteria met: signal 3 no longer matches a bare `T<id>`
  substring, still resolves the real `(T<id>)` convention, and the fix
  landed as a single narrow change in `_session/_lib.sh:304-308` (no
  per-skill duplication).
- CI green (bats, Markdown Lint, lint-tasks, sync-tasks), independent
  Claude Code review gave a clean bill (one non-blocking doc nit — a
  stale line reference in this file — fixed in a follow-up commit before
  merge), full repo `bats tests/*.bats` suite green, no regressions.
- No follow-up tasks filed — the fix is self-contained to the shared
  correlator; `top`/`bottom`/`stage --before`'s commit-message convention
  needed no changes since the fix is at the consuming regex, not the
  producing skills.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — wrote the
  false-positive/true-positive bats cases first, confirmed red (only the
  new false-positive case failing), then made the regex narrowing green.
- Verification (`superpowers:verification-before-completion`): yes —
  pre-PR (full bats suite, shellcheck, scope/doc-impact review) and
  pre-merge (mergeability, doc-impact re-check, caller survey for
  `session_pr_task_id`/`pr_task_id.sh` before relying on the green gate).
- Systematic debugging (`superpowers:systematic-debugging`): no — root
  cause was already diagnosed at filing time; no unexpected failures
  during implementation.
- Receiving code review (`superpowers:receiving-code-review`): yes — one
  independent-review finding (stale line reference in the task doc),
  accepted and fixed in a follow-up commit before merge; no pushback
  needed, the finding was correct.
