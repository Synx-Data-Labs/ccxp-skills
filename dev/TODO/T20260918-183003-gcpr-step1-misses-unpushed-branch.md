---
status: Coding
estimation: 30m
scheduled: 2026-09-14
source: this conversation, 2026-09-18 — discovered running /land on a branch with a committed-but-unpushed change and no PR yet
---

# T20260918-183003: `/gcpr` step 1 stops at "nothing to commit" without checking for an unpushed/PR-less branch

## Problem

- `gcpr/SKILL.md` step 1 ("Assess changes") only looks at the working
  tree: `git status --short` / `git diff --stat` / `git diff --staged
  --stat`. If all three are empty, it tells the user "nothing to commit"
  and stops.
- That's blind to a real, common case: the current branch already has
  one or more **committed** changes that are either unpushed (no
  upstream configured) or pushed but with no open PR yet. The user is on
  a feature branch, has nothing left to stage, but the branch's whole
  point — landing a PR — hasn't happened.
- Observed: on branch `docs/stage-20260918-125737` with 1 commit ahead
  of `main`, `git status --short` was empty, so `/land` (via `/gcpr`)
  reported "nothing to commit, working tree is clean" and stopped —
  when the correct next step was to push and open the PR (steps 5-6).

## Solution

- In step 1, after confirming no uncommitted/staged changes, add a
  check: if not on `main`, is there at least one commit ahead of `main`
  (`git log --oneline main..HEAD`)? If yes:
  - Check whether the branch has an open PR already (`bash ../_gh/gh.sh
    pr list --head <branch> --state all`).
  - No PR found → skip the "nothing to commit" early-stop and continue
    straight to step 5 (push) / step 6 (create PR) / step 7 (hand off to
    `/address-pr`) — step 2-4 (grouping/branch/commit) are moot since
    there's nothing new to commit.
  - PR already exists → report its URL and hand off to `/address-pr
    <number>` instead of re-creating one.
- If on `main` with no changes and no ahead-commits: this is the
  genuine "truly nothing to do" case — keep today's behavior (stop,
  tell the user "nothing to commit").

## Test plan

- [x] Manual repro: branch with a committed, unpushed, PR-less commit
      → `/land` pushes + opens the PR instead of stopping (this is
      literally what surfaced the gap in this conversation — branch
      `docs/stage-20260918-125737` had a clean tree but an unpushed,
      PR-less commit; walked through push (step 5) + PR create (step 6)
      by hand before this fix existed)
- [ ] Branch with a commit already pushed and an open PR → `/land`
      reports the existing PR and hands off to `/address-pr`, no
      duplicate PR created (not separately exercised — doc-only change,
      no script to unit test)
- [ ] `main` branch, clean tree → still reports "nothing to commit"
      (unchanged behavior, not re-verified live)

## Done criteria

- [x] `gcpr/SKILL.md` step 1 documents the ahead-of-main / PR-exists
      check and the branch to step 5-7 vs. genuine stop
- [x] `land/SKILL.md` needs no changes — it forwards to `gcpr` unchanged
