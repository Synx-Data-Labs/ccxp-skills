---
estimation: 1
# estimation was "30m" (duration buckets retired, T20260924-232855)
status: Open
scheduled: 2026-08-10
source: Retro 2026-08-13
---

# T20260813-406012: `ccxp` Phase 0 sync silently switches away from a self-authored branch with an open, unmerged PR

## Description

**Category: process**

Discovered live during this retro. This session started on branch
`docs/2026-08-13-addendum-10` (per the session's initial git status) — a
previous ccxp tick had committed a standup addendum to this branch, pushed
it, and opened PR #2772, but the session ended before running `/address-pr`
on it. This session's Phase 0 (`sync-and-prune-branches.sh`) ran
`git checkout main && git pull --ff-only` without ever checking whether the
branch it was leaving behind had unmerged, pushed work — it just moved on and
started fresh standup ticks against `main` at its current tip.

The result: PR #2772 sat open and undrained through 10+ subsequent standup
ticks (Addenda continued numbering from where that branch's HEAD was, not
noticing the divergence), and this retro's own report initially cited
"Addendum 10" as if it were part of the standup record on `main` when it was
actually stranded on an unmerged branch — caught only because an independent
review agent flagged the daily-summary file on disk didn't contain it.

**Definition of done**: `sync-and-prune-branches.sh` (or a new Phase 0 step)
checks, before switching off the starting branch: does the current branch
have commits not on `main`, and if so, is there an open PR for it? If yes,
either drain it via `/address-pr` before proceeding, or at minimum surface it
loudly in the tick's output so it isn't silently left behind. This is
distinct from the existing "uncommitted changes" check in `dev/guidelines.md`
— this is about **committed-and-pushed-but-unmerged** work on a branch about
to be abandoned.

## Test plan

- [ ] Given the starting branch has an open PR with no unmerged commits beyond
      what's already in the PR, Phase 0 either drains it or reports it explicitly
- [ ] Given the starting branch is `main` already (the normal case), no change
      in behavior
- [ ] A repeat of this scenario (branch left behind mid-PR) surfaces within one
      tick instead of silently persisting across many
