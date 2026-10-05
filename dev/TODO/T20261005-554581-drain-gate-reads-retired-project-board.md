---
status: Open
estimation: 1
source: 2026-10-05 /incept readiness pass in a consumer repo (build-pipeline-repo) — follow-up from closing its board-sync task as moot
related: T20261002-359869 (lifecycle.md opt-in board note — prose side), _ipm/ipm-iteration-drain-check.sh, ipm/SKILL.md (step 5a drain gate), lifecycle.md (§ Iteration assignment, board described as optional)
description: The /ipm drain gate hard-requires a GitHub Project board; a consumer that has retired its board gets a permanently red gate
---

# T20261005-554581: `ipm-iteration-drain-check.sh` hard-requires a Project board, so a board-less consumer's IPM gate is permanently red

## Problem

- `_ipm/ipm-iteration-drain-check.sh:224` lists items with
  `gh project item-list <n>` and treats the board's Iteration/Status fields as
  the source of truth.
- `lifecycle.md` already says the board is optional ("`scheduled:` plus the
  local `dev/TODO/` and `dev/JOURNAL/*.md` files are fully sufficient"), but
  the gate contradicts that.
- Observed: a consumer repo retired its `sync-tasks-to-issues` workflow and
  closed its Project board (2026-09-25). Since then every Monday `/ipm` reports
  the drain gate red, and the IPM notes blame an unrelated, now-closed task.
- The consumer's maintainer confirmed (2026-10-05) they do not want a board.

## Plan sketch (to be settled in Design)

- Make the gate derive "left over from iteration N" from `scheduled:` in
  `dev/TODO/` when no live board is configured (or the board is closed), instead
  of failing; keep the board path for consumers that still use one.
- Fold in the old consumer-side ask (closed there as moot): never block on the
  previous IPM's own auto-generated "Weekly Focus" pointer issue.
- Refresh `ipm/SKILL.md` step 5a and `lifecycle.md` prose to match.

## Done criteria

- [ ] With no board configured (or a closed board), the gate runs from
      `scheduled:` alone and exits 0 on a drained iteration
- [ ] Board-backed consumers see no behaviour change (fixture test)
- [ ] BATS coverage for both paths
