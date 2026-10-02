---
status: Done
scheduled: 2026-09-28
estimation: 2
source: discovered while /address-pr-ing T20260915-315552's implementation PR (#85)
related: T20260915-315552, T20260918-404944
claimed_by:
claimed_role:
---

# T20260922-324422: `_tc_pr_owner`/`_tc_resolve_task_location` misreads `unknown` for a same-repo close PR whose body `Task:` link points at a not-yet-merged path

## TLDR

- **Type**: bug
- **Problem**: `_tc_resolve_task_location` (`_session/task_claim.sh:634-708`) honors *any* `Task:`-prefixed blob link as cross-repo-authoritative without checking it's actually in a different repo, so a same-repo close PR whose `Task:` link points at the file's post-move JOURNAL path (not yet on `main`) 404s and reports `unknown` instead of falling back to the same-repo directory lookup.
- **Solution**: repo-match-first — compare the `Task:` link's repo against the PR's own repo (`gh repo view --json nameWithOwner`) before treating it as cross-repo; same repo routes into the existing same-repo lookup branch. Apply the identical fix to the sibling gate `_tc_pr_has_cross_repo_task_link`.

## Problem

- `_session/task_claim.sh pr-owner <pr>` returned `unknown` for PR #85 — a
  same-repo (not cross-repo) implementation PR that closes its own task in
  the same commit (journal-move per T20260914-422854's always-immediate
  convention) — even though the task's `claimed_by:` on `main` exactly
  matched this session's own `claimant-id` (`cc1-9a4074da:94a83ff0e786a885`,
  verified directly via `git show main:dev/TODO/T20260915-315552-*.md` and
  `task_claim.sh claimant-id`).
- PR #85's body included
  `Task: https://github.com/.../blob/main/dev/JOURNAL/2026-09-23-T20260915-315552-....md`
  (the *post-close* JOURNAL location, following the convention this repo
  already uses for cross-repo pointer PRs — `drive/SKILL.md` Phase 4 cross-repo
  step 3). That path doesn't exist on `main` yet (the move is still only on
  the PR branch, not merged) — the fetch 404s, `_tc_resolve_task_location`
  returns non-zero, and `pr-owner` reports `unknown` instead of falling back
  to the same-repo `dev/TODO/` directory lookup (which *would* have
  succeeded — verified manually, see `## Root cause`).
- Not unique to this exact task — **any** same-repo PR that both (a) closes
  its task in the same commit (journal-move) and (b) includes a `Task:`
  link in its body pointing at the file's *new* (not-yet-on-`main`)
  location will trip this the same way.

## Context

- `_tc_pr_owner` (`_session/task_claim.sh:807-853`) already documents this
  general failure shape in a comment: "a stale branch-name-vs-body-Task:-
  link mismatch can also surface as `unknown` on a rescoped PR — see
  T20260718-160579; that's a tooling bug to fix separately, not license to
  bypass the fail-safe" — and `/address-pr` §1.6 gives callers an explicit
  escape hatch for exactly this: manually confirm ownership and proceed,
  but say so and file/link the bug. This task IS that follow-up link.
- **Distinct from T20260918-404944** (also an `unknown`-from-`pr-owner`
  bug, also filed via the same escape hatch): that one is a `/stage` PR
  whose new task file is **completely absent from `main`** by design (a
  brand-new task, never staged before). This one is a task file that
  **is** on `main` (at its pre-move `dev/TODO/` path) — the resolver just
  never gets there, because the PR body's own `Task:` link diverts it into
  the cross-repo branch first. Same symptom (`unknown`), two different
  code paths inside `_tc_resolve_task_location` — worth fixing together
  if one person picks up both, but not the same root cause.
- Manually verified the same-repo fallback path (`_tc_task_dir` +
  `_session_gh api .../contents/dev/TODO?ref=main`) resolves
  `T20260915-315552-repo-conventions-mode-solo-team-switch.md` correctly
  when run directly, confirming the bug is specifically the cross-repo
  branch's premature commitment once *any* `Task:` link is present, not a
  broken same-repo lookup itself.

## Root cause

- `_tc_resolve_task_location` (`_session/task_claim.sh:634-708`) extracts
  whatever repo a `Task:` link names (the `sed -E` repo-extraction line
  inside the function's cross-repo branch) without ever comparing it to
  the PR's own repo. For PR #85's exact shape, this means the function
  **succeeds** with the wrong (not-yet-on-`main`) path — it does not
  fail, so the existing `_tc_resolve_task_location_head` fallback (built
  for the sibling bug, T20260918-404944, `_session/task_claim.sh:709-738`)
  never gets reached: it only fires on outright failure (`if ! loc=...`
  in `_tc_pr_owner`, `_session/task_claim.sh:824`), and this case doesn't
  fail.
- **Introduced**: the cross-repo `Task:`-link branch was added for
  cross-repo PRs (hub-repo task file, target-repo PR) — a deliberate
  design choice to let an explicit link override the default same-repo
  lookup. It never anticipated a *same-repo* PR also carrying a `Task:`
  link (the close-PR convention from `drive/SKILL.md` Phase 4 cross-repo
  step 3, applied here to a same-repo close) — an oversight in scope, not
  a regression.
- `_tc_pr_has_cross_repo_task_link` (`_session/task_claim.sh:739-762`) has
  the identical repo-blindness — it checks only "is there a `Task:`
  blob-link at all," never whether its repo differs from the PR's own.
  No live bug currently exercises it on this reproduction (`_tc_resolve_task_location`
  succeeds-wrong before this gate is ever consulted), but it shares the
  exact root cause and the file is already being touched.

## Solution

Grilled via `/incept` 2026-10-01 — settles the open choice below with
code-level facts, not guesswork.

- **Fix: repo-match-first.** Before honoring a `Task:` link as
  authoritative, compare its extracted repo against the PR's own repo
  (`gh repo view --json nameWithOwner`). Same repo → ignore the link,
  route into the existing same-repo `dev/TODO`/`dev/PARKING`
  directory-lookup branch (already implemented in
  `_tc_resolve_task_location`, just unreachable today for this shape).
  Different repo → today's cross-repo behavior, unchanged.
- **Rejected alternative**: when the cross-repo-shaped fetch 404s, fall
  back to the same-repo directory lookup by id before giving up with
  `unknown` — cheaper to implement, but changes
  `_tc_resolve_task_location`'s current "an explicit Task: link is
  authoritative" contract, which was a live concern until verified below.
  Rejected once the single-caller check (next bullet) showed there's no
  other caller whose contract this could break — repo-match-first is
  strictly more correct (it gets the cross-repo case right too, not just
  same-repo) for the same implementation cost.
- **No compatibility risk**: confirmed via repo-wide grep that
  `_tc_resolve_task_location` has exactly **one** caller (`_tc_pr_owner`
  itself, `_session/task_claim.sh:824`) — the rejected alternative's
  original concern about "other callers relying on an explicit Task:
  link being authoritative" doesn't apply.
- **Folded in** (grilled as a separate decision, not originally scoped):
  `_tc_pr_has_cross_repo_task_link` gets the identical repo-match fix in
  the same PR — same root cause, file already touched, cheaper than a
  second small PR later.
- **Out of scope**: T20260918-404944's own "new"-PR mechanism and its
  head-ref fallback (`_tc_resolve_task_location_head`) stay
  architecturally unchanged — this only tightens which branch routes
  into them.

Estimation revised from 1h to 2h: the original estimate covered one
function's fix; the folded-in scope now covers two functions and two
independent sets of BATS coverage.

## Test plan

- [x] New `tests/task_claim.bats` case: a same-repo PR whose `Task:` link
  (`_session/task_claim.sh:657-658` grep) points at the file's post-move
  JOURNAL path (present only on the PR branch, absent from `main`)
  resolves via the same-repo directory lookup (`mine`/`free`/`new` as
  appropriate), not `unknown`.
- [x] Existing cross-repo and same-repo-without-`Task:`-link cases in
  `tests/task_claim.bats` unchanged/still green (`bats tests/task_claim.bats`).
- [x] New `tests/task_claim.bats` case for `_tc_pr_has_cross_repo_task_link`
  (`_session/task_claim.sh:765-800`): a same-repo `Task:` link no longer
  reports "cross-repo link present" — the head-ref fallback gate
  correctly treats it as same-repo.
- [x] Local full suite green pre-push: 823/823 (`bats tests/`, exit 0).
- [x] CI (`bats` workflow on PR #215) green — all 5 checks passed
  (Markdown Lint, bats, lint-tasks, skill-quality, sync-tasks).

## Done criteria

- [x] `pr-owner` (or `_tc_resolve_task_location` directly,
  `_session/task_claim.sh:634-734`) resolves `mine` for a same-repo PR
  shaped like #85 (a `Task:` link to the file's post-move JOURNAL path,
  task actually still at its pre-move `dev/TODO/` path on `main`) — new
  `tests/task_claim.bats` case covers this.
- [x] `_tc_pr_has_cross_repo_task_link` (`_session/task_claim.sh:765-800`)
  correctly reports "no cross-repo link" for a same-repo `Task:` link —
  new `tests/task_claim.bats` case covers this.
- [x] Existing cross-repo and same-repo-without-a-`Task:`-link cases in
  `tests/task_claim.bats` unchanged/still green.

## Repo file references

| File | Lines (post-fix) | Purpose |
|---|---|---|
| `_session/task_claim.sh` | 634–734 | `_tc_resolve_task_location` — got the repo-match-first fix |
| `_session/task_claim.sh` | 735–764 | `_tc_resolve_task_location_head` — the sibling (T20260918-404944) fallback, unchanged |
| `_session/task_claim.sh` | 765–800 | `_tc_pr_has_cross_repo_task_link` — got the identical repo-match fix |
| `_session/task_claim.sh` | 845–891 | `_tc_pr_owner` — the sole caller of both functions above |
| `tests/task_claim.bats` | 920–964, 1068–1088 | new coverage for both fixed functions |

## Closed (2026-10-01)

- Shipped in **PR #215** (`https://github.com/Synx-Data-Labs/ccxp-skills/pull/215`).
- Both Done-criteria items met: `_tc_resolve_task_location` and
  `_tc_pr_has_cross_repo_task_link` now filter/classify a `Task:` link by
  actual repo match before trusting it as cross-repo-authoritative; new
  `tests/task_claim.bats` cases cover the same-repo-JOURNAL-link
  reproduction, the genuinely-cross-repo case, and the
  unresolvable-own-repo fail-closed case for both functions.
- Full local suite green pre-push: 823/823 (`bats tests/`, exit 0); PR
  #215's own CI confirmed the same across all 5 checks. Independent
  Claude Code review (dispatched during `/address-pr`): clean bill, 4
  minor non-blocking observations posted as a PR comment, no code
  changes needed.
- No follow-up tasks filed — T20260918-404944's own "new"-PR mechanism
  and head-ref fallback were confirmed out of scope and left unchanged
  (see `## Solution`). The review's 4 minor observations (an extra `gh
  repo view` call, case-sensitive repo comparison, small `sed`
  duplication, pre-existing shellcheck info note) were judged not worth
  separate follow-up tasks — low-likelihood edge cases / cosmetic only.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — Phase 3.0 code-class.
  Wrote the 5 new `tests/task_claim.bats` cases first, watched 2 of them
  fail for the expected reason (same-repo link still treated as
  cross-repo / still reporting "link present") before implementing the
  repo-match-first fix; the other 3 (genuinely-cross-repo,
  unresolvable-own-repo, genuinely-different-repo) passed immediately as
  regression guards for behavior that was correctly unchanged.
- Verification (`superpowers:verification-before-completion`): yes — ran
  the full `bats tests/` suite (823/823, exit 0) and `shellcheck` on the
  touched script before committing, not just the new test file.
- Systematic debugging (`superpowers:systematic-debugging`): yes — the
  first implementation attempt (repo-match check placed AFTER the
  id-token match) left one new test failing; traced it with `bash -x`
  rather than guessing, which surfaced that a same-repo JOURNAL-path
  link's date-prefixed basename never token-matches the task id in the
  first place, so the repo-match check needed to run BEFORE that match,
  not after it — corrected the root-cause framing in this doc to match.
- Receiving code review (`superpowers:receiving-code-review`): yes —
  dispatched an independent Claude Code review of the PR #215 diff during
  `/address-pr`; it returned a clean bill (control-flow and test-mock
  correctness both verified) with 4 minor non-blocking observations
  (one extra `gh repo view` call, a case-sensitive repo-string compare,
  a small `sed` duplication, and a pre-existing shellcheck info note) —
  posted verbatim as a PR comment, no code changes needed.
