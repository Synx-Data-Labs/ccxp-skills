---
status: In Progress
scheduled: 2026-10-05
estimation: 1
source: Split off T20260928-101526 (2026-09-28 skill-review findings, README §1) — the design-score gate failed on the parent 8-point task (56/100), so this next self-contained bug is being driven to merge on its own per /drive's "break into subtasks" guidance, same pattern as T20261006-138216.
related: T20260928-101526
description: cleanup-branch's merged-PR sweep force-deletes (`git branch -D`) any branch with a merged PR, discarding local commits made after the merge
claimed_by: cc1-50ac6891:ed6da7ef699fc33b
claimed_role: interactive
---

# T20261006-579135: `cleanup-branch` force-delete fallback discards commits made after a branch's PR merged

## TLDR

- **Type**: bug
- **Problem**: `cleanup-branch/scripts/cleanup-branch.sh`'s `run_pr_verified()` falls back to `git branch -D` for *any* branch carrying a merged PR, with no check for whether the branch has moved since — silently discarding commits added after the PR merged.
- **Solution**: before force-deleting, compare the branch's current tree to `main`'s (`git diff --quiet main "$b"`); identical trees means the `-d` refusal was just the ordinary squash/rebase SHA mismatch (safe to force-delete), different trees means the branch carries un-merged content (skip, report for human review).

## Problem

- 2026-09-28 skill-review finding (`dev/quality/skill-review-2026-09-28/README.md` §1, carried into T20260928-101526's Problem list): "Force-deletes (`branch -D`) any branch with a merged PR, including local commits made after the merge." (`cleanup-branch/scripts/cleanup-branch.sh:89-92`).
- Reproduced directly (see `tests/cleanup_branch.bats`, confirmed red pre-fix):
  - Branch `feature` gets a commit, its content is squash-merged into `main` (common GitHub squash-merge — `main` gets the content under a *different* commit SHA than `feature`'s tip), then `feature` picks up one more commit afterward.
  - Pre-fix: `git branch -d feature` fails (not a fast-forward ancestor of `main` — expected after a squash merge), the script falls straight to `git branch -D feature`, which succeeds and **silently deletes the branch along with the post-merge commit** — no warning, no recovery path (it's a hard branch delete, not a safe-to-undo stash).
- Impact: any automated or interactive run of `/cleanup-branch` against a branch a developer kept working on after its PR merged (a common pattern — "one more fixup before the next PR") loses that work with no prompt.

## Context

- `cleanup-branch/scripts/cleanup-branch.sh`'s own top-of-file contract states the invariant this bug violates: "Exits non-zero only on conditions that need a human/agent decision … those cases print to stderr and must NOT be worked around automatically (no stash, no discard)." The merged-PR force-delete path was the one spot that *did* auto-discard.
- `git branch -d` (lowercase) already protects against deleting a branch with un-merged commits **when the merge was a real, non-squash merge** (the branch's commits are literal ancestors of `main`). It does *not* protect against the squash/rebase-merge case, where `main` never contains the branch's commits as ancestors even though their *content* landed — that's exactly why the script falls back to `-D` at all, and exactly the gap this task closes.

## Solution

- Before the `-D` fallback, check `git diff --quiet main "$b" --`:
  - **No diff** (branch's tree == `main`'s tree): the earlier `-d` refusal was just the squash/rebase SHA mismatch — nothing on the branch is at risk, safe to force-delete. Behavior unchanged from before for this, the common, case.
  - **Diff exists**: the branch carries content `main` doesn't have — most likely commits added after the PR merged. Skip the delete and report `SKIPPED: diverges from main since PR merge — needs human review`, consistent with the script's existing "needs human/agent decision" invariant (same shape as the pre-existing checkout-blocked-by-local-changes case).
- **Alternative considered and rejected**: the review's suggested approach — fetch the PR's `headRefOid` (via an added `--json ...,headRefOid` field) and compare it to the branch's current tip SHA. Rejected because it answers a narrower question (did the branch's *commit* move?) than the one that actually matters (would deleting it *lose data*?): a trivial rebase/amend that leaves the final tree unchanged would still trip a `headRefOid` mismatch and force an unnecessary human-review stop, while the content-diff check only stops when there's something to actually lose.
- Scope: this task only fixes the merged-PR sweep (`run_pr_verified`). The separate `prune` subcommand (deletes branches whose upstream is `[gone]`) already requires an explicit `[gone]` tracking signal from `git fetch --prune` and isn't part of this bug.

## Test plan

- [ ] New `tests/cleanup_branch.bats`, hermetic (local bare repo + fake `_gh/gh.sh`, no network/real GitHub — same pattern as `tests/sync_and_prune_branches.bats`):
  - [ ] "SKIPS (does not force-delete) a merged-PR branch that has commits made after the merge" — must be confirmed **red** against the unmodified script (`git stash` isolation), **green** after the fix.
  - [ ] "force-deletes a merged-PR branch whose tree matches main (squash/rebase merge, no drift)" — regression guard for the pre-existing, common case.
  - [ ] "still soft-deletes normally when the branch is a true ancestor of main (regular merge)" — regression guard for the `-d` fast path.
- [ ] `bats tests/` full suite green with the new file included.

## Done criteria

- [ ] The merged-PR sweep no longer force-deletes a branch whose content diverges from `main` — `tests/cleanup_branch.bats::"SKIPS (does not force-delete)…"`.
- [ ] The common squash/rebase-merge case (no drift) still force-deletes as before — `tests/cleanup_branch.bats::"force-deletes a merged-PR branch whose tree matches main…"`.
- [ ] The true-ancestor case still soft-deletes via `-d` — `tests/cleanup_branch.bats::"still soft-deletes normally…"`.
- [x] Parent task `T20260928-101526` updated to record this split-off and link back here.

## Root cause

- Mechanism: `run_pr_verified()` treated "has a merged PR" and "safe to force-delete" as equivalent. They aren't — a merged PR only vouches for the content that existed *at merge time*; anything committed to the branch afterward is unrelated to that PR and was never reviewed/landed anywhere.
- Introduced: `cleanup-branch/scripts/cleanup-branch.sh` predates this repo's visible history (squashed at `5051a9e`, "Initial public release" — `git log --follow` shows no earlier commit). Given the fallback reads as a deliberate (if incomplete) attempt at convenience — "PR merged, so just force it through" — rather than an accidental typo, this is plausibly a scope gap rather than a pure oversight, but intent can't be confirmed past the history squash — **assumed**.
- Why it went undetected: the dangerous path only triggers when a developer continues committing to a branch *after* its PR merges but *before* running `/cleanup-branch` — a real but not everyday sequence, and the script's own output for the force-delete case (`deleted (force, rebased/squash merge)`) reads identically whether or not anything was actually lost, so there was no observable signal.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `cleanup-branch/scripts/cleanup-branch.sh` | `89-100` | `run_pr_verified`'s delete logic — new diff-based guard added before the `-D` fallback |
| `tests/cleanup_branch.bats` | all (new) | hermetic regression coverage, red→green confirmed |
