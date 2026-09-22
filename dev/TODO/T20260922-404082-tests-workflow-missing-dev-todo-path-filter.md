---
status: Coding
estimation: 15m
source: this conversation, 2026-09-22 — noticed while /address-pr'ing PR #56, a pure task-filing PR that only got Markdown Lint as its CI signal
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260922-404082: `tests.yml`'s path filters omit `dev/TODO/**` and `dev/JOURNAL/**`, so `lint-tasks`/`sync-tasks` never run on a pure task-file change

## Problem

- **Type**: chore
- `.github/workflows/tests.yml`'s `push`/`pull_request` `paths` lists cover
  `actions/sync-tasks/**`, `repo-conventions/scripts/**`, `_gh/**`,
  `_session/**`, `_docs/**`, `slack/**`, `design-score/**`, `retro/**`,
  `quality-probe/**`, `statusline-setup/**`, `migrate-task/**`, `tests/**` —
  but not `dev/TODO/**` or `dev/JOURNAL/**`.
- `lint-tasks` runs `repo-conventions/scripts/test_lint_tasks.py` (task-file
  schema validation) and `sync-tasks` runs `actions/sync-tasks/test_sync.py`
  — both exist specifically to validate task files, yet neither triggers on
  a PR that only touches `dev/TODO/**`/`dev/JOURNAL/**`.
- Observed directly: [PR #56](https://github.com/Synx-Data-Labs/ccxp-skills/pull/56) (ccxp-skills) — a pure `/stage` PR adding one new
  task file and one `queue.md` line — only got `Markdown Lint` as its CI
  signal; `lint-tasks`/`sync-tasks` never ran.
- Same class of gap as `_gh/**`'s prior omission, fixed in [PR #40](https://github.com/Synx-Data-Labs/ccxp-skills/pull/40)
  (ccxp-skills): a directory with dedicated CI validation, missing from the
  trigger list that's supposed to run it.

## Context

- `.github/workflows/tests.yml` (repo root)
- Precedent fix: [PR #40](https://github.com/Synx-Data-Labs/ccxp-skills/pull/40) (ccxp-skills) added `_gh/**` to the same two path
  lists for the identical reason.

## Solution

- Add `dev/TODO/**` and `dev/JOURNAL/**` to both the `push.paths` and
  `pull_request.paths` lists in `.github/workflows/tests.yml`.

## Test plan

- [ ] YAML still parses (`python3 -c "import yaml; yaml.safe_load(open('.github/workflows/tests.yml'))"`)
- [ ] A PR touching only `dev/TODO/**` now triggers `lint-tasks`/`sync-tasks`
      (this PR's own diff, once opened, is the test case)
