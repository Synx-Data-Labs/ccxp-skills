---
status: Review
estimation: 1
source: owner request 2026-11-24 (job 1524), epic E4
related: [T20261121-412600]
description: Script that checks a branch or clone is based on the latest origin/main (rebase or fail loudly) before any workflow dispatch or push; wired into /drive and /land
type: feature
claimed_by: cc1-50ac6891:2a82d411376c36a9
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261124-392722: Pre-dispatch fresh-base gate script (d129)

## TLDR

- **Type**: feature
- **Problem**: d129 (latest main before work, push and workflow dispatch) is prose only; a stale branch already caused a Checkout failure (T20261106-421407).
- **Solution**: `_gh/fresh-base.sh check [--rebase]` and `remote <branch>`, one verdict line plus exit code, wired into `/drive` and `/gcpr` (`/land`).
- Design approved in-conversation 2026-11-24 (owner: "go" on the epic E4 split); design PR skipped.

## Problem

- **Type**: feature
- Implements decision d129 (2026-11-17): every ongoing task, branch and verification or build run uses the latest main; fetch and rebase onto `origin/main` before work, before pushing, and before dispatching any workflow run. A stale branch caused the T20261106-421407 Checkout failure.
- Today the rule is prose only; no script checks it before a push or a `gh workflow run`.
- Wanted: one sourceable script (for example `_gh/fresh-base.sh`) that fetches through `_gh/git.sh`, compares `HEAD` with `origin/main`, and reports `fresh`, `rebased` or `stale` with a nonzero exit; `--rebase` does a plain rebase and stops loudly on a conflict, never force-pushes.
- Wire it into `drive/SKILL.md` (before push and before any workflow dispatch) and `gcpr/SKILL.md` (`/land`), with bats tests for fresh, behind-clean (rebases), behind-conflict (fails), no remote (fails closed) and a dirty tree.
- Retire when shipped: d129 (the owner or dispatcher retires it later, not this task).

## Context

- Decision d129 (2026-11-17); the sibling guard `drive/scripts/cross-repo-guard.sh` shows the one-line verdict plus exit-code style reused here.
- `_gh/git.sh` supplies the account-aware fetch (`_gh/git.sh:1`), so the script never calls bare network git.

## Root cause

- The freshness rule lived only in prose (`dev/guidelines.md`, task d129), with no mechanical check in `/drive` (`drive/SKILL.md` Phase 3 step 6) or `/gcpr` (`gcpr/SKILL.md` step 5), so a stale branch was pushed and dispatched (T20261106-421407). Verified against the pre-change SKILL.md text.

## Repo file references

| File | Change |
|---|---|
| `_gh/fresh-base.sh` | new script |
| `tests/fresh_base.bats` | new tests |
| `drive/SKILL.md` | wire Phase 3 steps 6-7 |
| `gcpr/SKILL.md` | wire step 5 |

## Solution

- `_gh/fresh-base.sh` (sourceable, functions, `set -uo pipefail`): `check` fetches via `_gh/git.sh` (override `FRESH_BASE_GIT` for tests) and compares `HEAD` with `origin/main`; `remote <branch>` checks the pushed branch contains `origin/main`.
- Verdicts: exit 0 `fresh`/`rebased`, 10 `stale behind=N`, 11 `conflict` (rebase aborted), 12 `dirty`, 13 `detached`/`in-progress`, 3 `fetch-failed`/`no-base` (fail closed), 2 usage; any non-zero exit stops the flow.
- Alternatives rejected:
  - A git pre-push hook: invisible to `gh workflow run` dispatches and not installed in fresh clones.
  - Auto force-push after rebase: unsafe; the script never pushes.
- Wiring: `drive/SKILL.md` Phase 3 steps 6 and 7 (push, dispatch), `gcpr/SKILL.md` step 5 (push).

## Test plan

- [x] `tests/fresh_base.bats` (15 cases) against a bare origin and a working clone, plain git.

## Done criteria

- [x] Script returns the verdicts above: `tests/fresh_base.bats` the verdict cases.
- [x] `/drive` and `/land` docs call it before push and dispatch: `drive/SKILL.md:352-353`, `gcpr/SKILL.md` step 5, the wiring test.
- [x] A stale branch cannot reach a push or dispatch silently: any non-zero exit stops the flow (stale, conflict, dirty, fetch-failed, detached cases).
