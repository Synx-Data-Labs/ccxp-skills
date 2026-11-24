---
status: In Progress
estimation: 1
source: owner request, this conversation, 2026-11-24
description: HUD shows how many commits the local branch is behind (and ahead of) its remote
type: feature
claimed_by: cc1-50ac6891:9ce523ecfd3a0b1f
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261124-317732: HUD: show commits behind the remote

## Problem

- **Type**: feature
- Owner, verbatim: "in the hud, i also want to show how many commits behind of the local branch from the remote."
- Show `main ↓134` (and `↑2 ↓134` when ahead) next to the branch for the session repo; the behind count is against the upstream (`@{u}`), falling back to origin/<default branch>.
- Computed from the remote-tracking ref on disk; kept fresh by a detached, rate-limited (about 5 min per repo, 15 s timeout) `git fetch --quiet --no-tags --no-prune origin`, cached like hud-version.sh; a failed fetch keeps the last answer.
- Silent at 0/0, outside a repo, with no upstream and no origin default branch, and on a detached HEAD; neutral color when small, warning past about 20.
- Logic in `hud/scripts/hud-behind.sh` with bats tests (behind, ahead, both, no-upstream fallback, detached, not a repo, cache and rate limit); update `hud/README.md` and `hud/HELP.md`; add to `/hud details` if the one-row band is too narrow.
- Done: behind indicator renders, tests green, docs updated; no version bump or release.
