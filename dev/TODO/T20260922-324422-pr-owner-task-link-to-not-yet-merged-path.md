---
status: Open
scheduled: 2026-10-05
estimation: 1h
source: discovered while /address-pr-ing T20260915-315552's implementation PR (#85)
related: T20260915-315552, T20260918-404944
---

# T20260922-324422: `_tc_pr_owner`/`_tc_resolve_task_location` misreads `unknown` for a same-repo close PR whose body `Task:` link points at a not-yet-merged path

## Problem

- `_session/task_claim.sh pr-owner <pr>` returned `unknown` for PR #85 — a
  same-repo (not cross-repo) implementation PR that closes its own task in
  the same commit (journal-move per T20260914-422854's always-immediate
  convention) — even though the task's `claimed_by:` on `main` exactly
  matched this session's own `claimant-id` (`cc1-9a4074da:94a83ff0e786a885`,
  verified directly via `git show main:dev/TODO/T20260915-315552-*.md` and
  `task_claim.sh claimant-id`).
- Root cause: `_tc_resolve_task_location` (`_session/task_claim.sh:623-673`)
  checks the PR body for **any** `Task:`-prefixed line with a GitHub blob
  link first, and if found, treats resolution as the cross-repo path —
  fetching that exact path from `main` — regardless of whether the PR is
  actually same-repo. PR #85's body included
  `Task: https://github.com/.../blob/main/dev/JOURNAL/2026-09-23-T20260915-315552-....md`
  (the *post-close* JOURNAL location, following the convention this repo
  already uses for cross-repo pointer PRs — `drive/SKILL.md` Phase 4 cross-repo
  step 3). That path doesn't exist on `main` yet (the move is still only on
  the PR branch, not merged) — the fetch 404s, `_tc_resolve_task_location`
  returns non-zero, and `pr-owner` reports `unknown` instead of falling back
  to the same-repo `dev/TODO/` directory lookup (which *would* have
  succeeded — verified manually, see below).
- Not unique to this exact task — **any** same-repo PR that both (a) closes
  its task in the same commit (journal-move) and (b) includes a `Task:`
  link in its body pointing at the file's *new* (not-yet-on-`main`)
  location will trip this the same way.

## Context

- `_tc_pr_owner` (`_session/task_claim.sh:733-757`) already documents this
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

## Solution (sketch — not yet designed in full)

- Prefer trying the same-repo `dev/TODO`/`dev/PARKING` directory lookup
  FIRST when the PR's own repo (from `gh repo view`) matches the `Task:`
  link's repo — only fall into the cross-repo fetch-by-exact-path branch
  when the linked repo differs from the PR's own repo (the actual
  cross-repo signal), or when the same-repo lookup itself fails.
- Alternative: when the cross-repo-shaped fetch 404s, fall back to the
  same-repo directory lookup by id before giving up with `unknown` —
  cheaper to implement, but changes `_tc_resolve_task_location`'s current
  "an explicit Task: link is authoritative" contract, which other callers
  may rely on for exactly the opposite reason (trusting an explicit link
  over a same-repo guess). Needs whoever picks this up to check callers
  before choosing between the two.
- Either way needs new `tests/task_claim.bats` coverage: a same-repo PR
  whose body's `Task:` link points at a path absent from `main` (present
  only on the PR branch) still resolves via the same-repo directory
  lookup, not `unknown`.

## Done criteria

- [ ] `pr-owner` (or `_tc_resolve_task_location` directly) resolves `mine`
  for a same-repo PR shaped like #85 (a `Task:` link to the file's
  post-move JOURNAL path, task actually still at its pre-move `dev/TODO/`
  path on `main`) — new `tests/task_claim.bats` case
- [ ] Existing cross-repo and same-repo-without-a-Task:-link cases in
  `tests/task_claim.bats` unchanged/still green
