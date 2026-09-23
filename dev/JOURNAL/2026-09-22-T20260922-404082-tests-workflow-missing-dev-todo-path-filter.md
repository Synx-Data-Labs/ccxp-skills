---
status: Done
estimation: 15m
source: this conversation, 2026-09-22 — noticed while /address-pr'ing PR #56, a pure task-filing PR that only got Markdown Lint as its CI signal
claimed_by:
claimed_role:
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

- [x] YAML still parses (`python3 -c "import yaml; yaml.safe_load(open('.github/workflows/tests.yml'))"`) and `actionlint` reports 0 issues
- [x] A `dev/TODO/**`-only push (no workflow-file touch) triggers `lint-tasks`/`sync-tasks`/`bats` — verified **pre-merge**, on this very PR: commit `6262501` touched only the task file itself, and all three jobs ran and passed (this corrects an earlier, wrong assumption in this PR's own body that GitHub only evaluates `pull_request` path filters against the *target* branch's workflow definition — it evidently also honors the *head* branch's version, since the new filter wasn't on `main` yet when this fired)

## Closed (2026-09-22)

- Shipped in PR #59 — added `dev/TODO/**` and `dev/JOURNAL/**` to both `push.paths` and `pull_request.paths` in `.github/workflows/tests.yml`.
- Verified pre-merge, both items: YAML parse + `actionlint` clean, and — directly on this PR's own branch (commit `6262501`, a task-file-only push) — `lint-tasks`/`sync-tasks`/`bats` all triggered and passed. No post-merge verification needed; the fix was empirically confirmed working before merge.
- No follow-up tasks filed — this closes the gap flagged while addressing PR #56.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — technically code-class (workflow YAML), but a two-line path-filter addition has no meaningful unit-testable behavior; verification is YAML-parse + `actionlint` + an inherently post-merge CI observation (see Test plan)
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6, confirmed real `actionlint`/YAML-parse exit codes rather than assuming clean output
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck, single mechanical edit
- Receiving code review (`superpowers:receiving-code-review`): no — `/address-pr`'s review agent returned a clean bill, nothing to push back on
