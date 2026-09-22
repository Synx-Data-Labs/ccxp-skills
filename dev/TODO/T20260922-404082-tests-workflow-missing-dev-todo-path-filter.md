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
- [ ] **Post-merge**: a future PR touching only `dev/TODO/**`/`dev/JOURNAL/**` triggers `lint-tasks`/`sync-tasks` — can't be verified within this PR's own diff, since GitHub evaluates `pull_request` path filters against the *target* branch's current workflow definition (which doesn't have this fix until it merges), and this PR's own commits also touch `.github/workflows/tests.yml` directly (already always-triggering), so its own CI run doesn't exercise the new filter in isolation

## Closed (2026-09-22)

- Shipped in PR #<PR_NUMBER_PLACEHOLDER> — added `dev/TODO/**` and `dev/JOURNAL/**` to both `push.paths` and `pull_request.paths` in `.github/workflows/tests.yml`.
- Verified pre-merge: `python3 -c "import yaml; yaml.safe_load(...)"` and `actionlint` both clean (exit 0).
- Not yet verified: whether a future `dev/TODO/**`-only PR actually triggers `lint-tasks`/`sync-tasks` — external, confirmed on the next such PR (T20260922-195629's eventual research work, or any other `/stage`/`/new-task` PR, will be the first real test).
- No follow-up tasks filed — this closes the gap flagged while addressing PR #56.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — technically code-class (workflow YAML), but a two-line path-filter addition has no meaningful unit-testable behavior; verification is YAML-parse + `actionlint` + an inherently post-merge CI observation (see Test plan)
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6, confirmed real `actionlint`/YAML-parse exit codes rather than assuming clean output
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck, single mechanical edit
- Receiving code review (`superpowers:receiving-code-review`): {pending — filled in after `/address-pr`}
