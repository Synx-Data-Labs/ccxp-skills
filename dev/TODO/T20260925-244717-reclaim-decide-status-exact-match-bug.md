---
status: Open
estimation: 1h
source: 2026-09-25 conversation — surfaced live while taking over a stale
  claim on T20260914-175513 in synxdb-build-pipeline
related: T20260925-383305 (same file, `_tc_fm_set` — a different bug in the
  same function-neighborhood; this one is in `_tc_reclaim_decide`)
---

# T20260925-244717: `_tc_reclaim_decide` exact-matches `status` against `Coding`/`Review`, so any narrated status always reads `live`

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
- Reproduced live: `T20260914-175513` in `synxdb-build-pipeline` has
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
