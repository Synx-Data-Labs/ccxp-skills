---
status: Done
estimation: 1
source: 2026-09-25 conversation — surfaced live while taking over a stale
  claim on T20260914-175513 in build-pipeline-repo
related: T20260925-383305 (same file, `_tc_fm_set` — a different bug in the
  same function-neighborhood; this one is in `_tc_reclaim_decide`)
claimed_by:
claimed_role:
scheduled: 2026-10-05
---

# T20260925-244717: `_tc_reclaim_decide` exact-matches `status` against `Coding`/`Review`, so any narrated status always reads `live`

## TLDR

- **Type**: bug
- **Problem**: `_tc_reclaim_decide` (`_session/task_claim.sh:292`) exact-matches `status` against `Coding`/`"In Progress"`/`Review`; any documented-convention narrated status (e.g. `Review — implementation complete, PR #3416 open`) misses the match and returns `live` unconditionally, before the staleness-window logic ever runs.
- **Solution**: match on the leading status token (prefix check), not the whole string, so a narrated status still enters the staleness window. Add a BATS case covering narrated-vs-bare parity.

## Problem

- **Type**: bug
- `_session/task_claim.sh:267-269` (`_tc_reclaim_decide`):

  ```
  case "$status" in
    Coding|Review) : ;;
    *) printf 'live'; return 0 ;;
  esac
  ```

  This is an exact string match. But the `/todo` skill's own documented
  frontmatter convention says `status` "is free-text after its leading
  token, so a `BLOCKED` or `SUPERVISED` substring can be appended to
  narrate why" — e.g. `status: Coding — SUPERVISED (needs VPN)` or
  `status: Review — implementation complete, PR #3416 open (...)`. Any
  task using that documented, expected convention has a `status` that is
  never exactly `"Coding"` or `"Review"`, so it always falls to the `*)`
  arm and returns `live` immediately — before the function ever reads
  `commit_days`/`pr_days`/`live_signal`. The entire staleness-window
  computation is dead code for every narrated status.
- Reproduced live: `T20260914-175513` in `build-pipeline-repo` has
  `status: Review — implementation complete, PR #3416 open (...)`.
  `task_claim.sh reclaimable T20260914-175513` returned `live` even though
  its real activity signals were stale: 3 days since the last commit
  mentioning the task id (`_tc_days_since_last_commit`, stale threshold is
  2 days), PR #3416 untouched for 8 days, and no in-progress CI run.
- Isolated with a direct call, holding every other input constant:

  ```
  _tc_reclaim_decide "Review — implementation complete, PR #3416 open" \
    "cc1-9a4074da:6c43e8c778f8967b" 3 99999 2 ""
  # -> live
  _tc_reclaim_decide "Review" \
    "cc1-9a4074da:6c43e8c778f8967b" 3 99999 2 ""
  # -> reclaimable
  ```

  Identical `commit_days`/`pr_days`/`stale`/`live_signal` — only the
  `status` string differs, and the verdict flips. This is conclusive: the
  bug is the exact-match case statement, not the activity signals.
- Impact: this silently defeats the reclaim sweep's safety net for any
  task in `Coding`/`Review` that has ever been given a narrated status —
  which, per the documented convention, is common (`SUPERVISED`,
  `BLOCKED`, or any free-form note appended to explain the state). Those
  tasks' claims can never be identified as stale/abandoned by
  `task_claim.sh reclaimable` or by `reclaim_sweep.sh` (same function),
  regardless of how long they've actually been dead.
- What "done" looks like: `_tc_reclaim_decide`'s status check matches on
  the leading token, not the whole string — e.g. `case "$status" in
  Coding|Coding\ *|Review|Review\ *) : ;; *) printf 'live'; return 0 ;;
  esac` (or equivalent parameter-expansion prefix check) — so a narrated
  status still enters the staleness-window logic. Add a BATS case
  mirroring the isolation above: same `commit_days`/`pr_days`/`stale`,
  narrated vs. bare status, asserting both return the same verdict.

## Context

- `_tc_reclaim_decide` is the pure decision core behind `task_claim.sh reclaimable`
  and `reclaim_sweep.sh`'s stale-claim sweep — the safety net that frees a
  peer-mode claim when the owning session has gone dark (`_session/README.md`).
- The `/todo` skill's frontmatter convention (`todo/SKILL.md` §Task metadata)
  explicitly documents narrated statuses (`SUPERVISED`, `BLOCKED`, or any
  free-form note) as expected, common usage — not an edge case.
- No existing tests exercise a *narrated* `Coding`/`In Progress`/`Review` status
  through `_tc_reclaim_decide` — `tests/task_claim.bats:200-244` only use bare
  tokens.

## Root cause

- `_session/task_claim.sh:291-293`:

  ```bash
  case "$status" in
    Coding|"In Progress"|Review) : ;;
    *) printf 'live'; return 0 ;;
  esac
  ```

  A `case` pattern here is an exact (glob) match against the full `$status`
  string, not a prefix test — so `"Review — implementation complete, PR #3416
  open"` doesn't match the `Review` arm and falls straight to `*)`.
- Git archaeology: this exact-match form predates this repo's own history —
  `ccxp-skills` begins at `5051a9e` ("Initial public release", 2026-09-28), a
  squashed import from a private source repo, and the `Coding|Review`
  exact-match pattern (later extended to include `"In Progress"` per
  T20260809-355059, also pre-squash) is already present at that first commit.
  *Verified*: no narrower origin commit exists in this repo's own history.
  *Assumed*: whether the original author deliberately chose exact-match or
  simply didn't anticipate narrated statuses — unrecoverable from the
  squashed history, but the documented frontmatter convention (narrated
  statuses are expected, common usage) existing independently of this
  function makes "oversight" the more likely read.
- Why it went unnoticed: `tests/task_claim.bats`'s existing `_tc_reclaim_decide`
  cases all pass bare status tokens (`Coding`, `Review`, `"In Progress"`), so
  the exact-match bug has no failing test to surface it — it was only caught
  live, via the `T20260914-175513` reproduction in the Problem section above.

## Solution

- Replace the exact-match `case` arms with prefix-aware patterns — glob
  patterns that match either the bare token or the token followed by a space
  (the universal separator for narration, per the `/todo` convention's
  `status: Coding — SUPERVISED (needs VPN)` example):

  ```bash
  case "$status" in
    Coding|Coding\ *|"In Progress"|"In Progress "*|Review|Review\ *) : ;;
    *) printf 'live'; return 0 ;;
  esac
  ```

- **Alternatives considered and rejected**:
  - *Regex/parameter-expansion prefix check* (e.g. `[[ "$status" == Coding* ]]`)
    — functionally equivalent, but the codebase's own `status_head()` helper
    (`repo-conventions/scripts/lint_tasks.py`) already establishes `case`-glob
    as the idiomatic pattern for this exact problem in this repo; switching to
    `[[ ]]` here would be a gratuitous style departure for no behavioral gain.
  - *Split on first whitespace, then exact-match the token* — correct, but
    adds a variable and a second step for no benefit over inline glob
    alternation; the one-line fix is simpler to review and test.
  - *Loosen to a bare prefix glob (e.g. `Coding*`)* — rejected: `Coding` is
    itself a prefix of nothing else in the active-status vocabulary, but
    `Review*` would also match a hypothetical future status literally named
    `Reviewed` (not a current status, but the explicit `Review|Review\ *`
    form stays correct even if one is added later, at zero extra cost).

## Test plan

- [x] BATS: narrated vs. bare status, identical `commit_days`/`pr_days`/`stale`,
      assert identical verdict — mirrors the task's own reproduction
      (`tests/task_claim.bats`, new case near the existing
      `_tc_reclaim_decide: "In Progress" status is recognized...` test at
      line 221).
  - [x] `Review — implementation complete, PR #3416 open` + stale signals → `reclaimable`
  - [x] `Coding — SUPERVISED (needs VPN)` + stale signals → `reclaimable`
  - [x] `In Progress — design PR skipped (...)` + stale signals → `reclaimable`
- [x] `bats tests/task_claim.bats` passes locally, full suite — 110/110, no regressions
      in the existing bare-status cases.
- [ ] CI `bats` check green on the PR. (post-merge item — verified by `/address-pr` before merge)

## Done criteria

- [x] `_session/task_claim.sh:291-293` returns `reclaimable` for a narrated status with stale signals, matching its bare-token counterpart — verified by the new BATS case(s) in `tests/task_claim.bats`.
- [x] No existing case in `tests/task_claim.bats` regresses — full `bats` run, all green (110/110).

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_session/task_claim.sh` | 291–293 | `_tc_reclaim_decide` — the buggy exact-match `case`, fixed here |
| `tests/task_claim.bats` | ~221–225 | existing `"In Progress"` bare-status coverage; new narrated-status case added alongside |
| `todo/SKILL.md` | frontmatter §Task metadata | documents the narrated-status convention this bug silently defeats |

## Closed (2026-10-06)

- Shipped in **PR #267** (`t20260925-244717-impl`,
  `https://github.com/Synx-Data-Labs/ccxp-skills/pull/267`) — a one-line
  `case` pattern fix in `_session/task_claim.sh:291-293` (prefix match
  instead of exact match), plus a new BATS case in `tests/task_claim.bats`
  covering narrated-vs-bare parity.
- **Met**: full `tests/task_claim.bats` suite (110/110, no regressions);
  `design-score` gate 92/100; `quality-probe` shellcheck clean.
- **External/unverified at write time**: CI `bats` check on PR #267 — left
  unchecked in Test plan above, to be verified/ticked by `/address-pr`
  before merge.
- **Claim PR**: #265 (merged as `eca4999`) — also fixed an incidental,
  independent-review-caught issue: an unquoted `": "` inside the claim
  commit's `status:` frontmatter value broke strict YAML parsing (tooling
  fallback masked it in CI); reworded to avoid the colon.
- **No follow-up tasks filed by this session** for the bug itself. (A
  separate, pre-existing open item, T20261006-105476 — `/address-pr` §2.d's
  review-agent dispatch prompt doesn't forbid write actions — surfaced in
  the shared clone during this session's work but was filed by another
  process, not this one; see this session's own report for details.)

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — Phase 3.0, code-class. Wrote the narrated-status BATS case first, watched it fail (`not ok` against the pre-fix exact-match `case`), then made the minimal one-line `case`-pattern fix, then verified green (110/110).
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6 pre-PR (full suite run) + this Phase 7.0 pass.
- Systematic debugging (`superpowers:systematic-debugging`): no — root cause was already isolated in the task's own Problem section; no repeated-failure trigger hit.
- Receiving code review (`superpowers:receiving-code-review`): yes — on claim PR #265, an independent review agent flagged the unquoted-colon YAML issue; steelmanned it, verified independently with `yaml.safe_load`, confirmed real, fixed rather than pushed back.
