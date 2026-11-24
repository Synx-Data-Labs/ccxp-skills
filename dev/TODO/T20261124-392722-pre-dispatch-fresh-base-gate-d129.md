---
status: Open
estimation: 1
source: owner request 2026-11-24 (job 1524), epic E4
related: [T20261121-412600]
description: Script that checks a branch or clone is based on the latest origin/main (rebase or fail loudly) before any workflow dispatch or push; wired into /drive and /land
type: feature
---

# T20261124-392722: Pre-dispatch fresh-base gate script (d129)

## Problem

- **Type**: feature
- Implements decision d129 (2026-11-17): every ongoing task, branch and verification or build run uses the latest main; fetch and rebase onto `origin/main` before work, before pushing, and before dispatching any workflow run. A stale branch caused the T20261106-421407 Checkout failure.
- Today the rule is prose only; no script checks it before a push or a `gh workflow run`.
- Wanted: one sourceable script (for example `_gh/fresh-base.sh`) that fetches through `_gh/git.sh`, compares `HEAD` with `origin/main`, and reports `fresh`, `rebased` or `stale` with a nonzero exit; `--rebase` does a plain rebase and stops loudly on a conflict, never force-pushes.
- Wire it into `drive/SKILL.md` (before push and before any workflow dispatch) and `gcpr/SKILL.md` (`/land`), with bats tests for fresh, behind-clean (rebases), behind-conflict (fails), no remote (fails closed) and a dirty tree.
- Retire when shipped: d129 (the owner or dispatcher retires it later, not this task).

## Done criteria

- Script plus bats tests merged; `/drive` and `/land` docs call it; a stale branch cannot reach a push or a workflow dispatch without a loud failure.
