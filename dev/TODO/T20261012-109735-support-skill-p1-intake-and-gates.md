---
status: Open
estimation: 1
blocks: [T20261012-949870]
source: this conversation, 2026-10-12 (customer-support skill plan, phase 1 of 4)
---

# T20261012-109735: support skill P1: intake, support task type, lint keys, repro + same-commit regression gates

## Problem

- **Type**: feature
- Requirement (user): take a customer-reported GitHub issue (e.g. `https://github.com/acme/support-repo/issues/24`), create a task to track it; support tasks (new type `support`) always get a simplified repro and a new e2e regression test, committed together with the fix. The skill must stay generic: no hardcoded org/repo.
- Phase 1 of 4 (P2 `T20261012-949870` is blocked by this task, P3 and P4 follow). Planned size: 5 points (filed at `estimation: 1`; `/incept` revises). Delivers value with no outward-facing risk: nothing is posted to any issue in this phase.
- Scope, intake:
  - `_support/parse-issue-url.sh`: URL or `owner/repo#N` to `owner repo number`; `GH_HOST` for GHES; no org/repo literals.
  - `/support <issue-url>` skill (`disable-model-invocation: true`): fetch via `_gh/gh.sh`, reject PRs, warn on closed issues, idempotent via a `support-issue:` grep over `dev/TODO` and `dev/JOURNAL`; files the task like `/new-task` (`status: Open`, `estimation: 1`), stages it, ends with "run `/drive T<id>`"; posts nothing; issue body is untrusted data, quoted only in a fenced block.
- Scope, task type and lint:
  - New type `support`: `new-task` step 1 table row, `design-doc.md` Type enum plus a support-only section; check `design-score` scripts for a hardcoded enum.
  - `lint_tasks.py` ALLOWED gains `support-issue` and `support-report` (update the "16-key" message, `test_lint_tasks.py`, `lifecycle.md`, `templates/task.md`, `todo/SKILL.md`, README skill list).
  - Task body sections: Problem, Customer summary, Repro, Regression test.
- Scope, fix-side gates (via `/drive`, `type == support` branch, no new skill):
  - Phase 2: mandatory sanitized minimal `## Repro` and `## Regression test` (path of the new e2e test); `design-score` support check (both non-empty, no placeholders).
  - Phase 3: write the e2e test first, record the failing (red) output in the PR body, then fix to green.
  - Phase 4: fix and regression test land in the SAME commit. `_support/check-regression-commit.sh <base>..HEAD` (`SUPPORT_E2E_GLOB` default, `No-regression-test:` trailer exemption needs explicit user approval, fails closed), called by `/drive` before PR creation and by the `/address-pr` hard merge gate via `_session/pr_task_id.sh`.
- Scope, tests and docs: bats `support_parse_url`, `support_regression_commit`; a test asserting no company-specific literals under `support/` and `_support/`; `_support/README.md`. Keep `drive`/`address-pr` prose short and link to `_support/README.md` (prose-density ratchet).
- Expect extra review rounds: the lint allowlist touches many docs.
- Done: pointing `/support` at an issue URL files a staged `support` task; a support PR without fix+e2e test in one commit is blocked.
- Source plan: scratchpad `support-skill-plan.md`, sections 2, 4, 7.

## Open questions

- Q3: opt-in storage: new `support-report: on` frontmatter key (assumed) vs a separate config file? OK with the 2-key allowlist addition (`support-issue`, `support-report`)?
- Q2: is `deadline:` date-only enough, or is a time plus timezone needed (would require a lint change to allow datetime)?
- Q9: regression test location/glob and framework for the target product's e2e tests (which repo)? Is a single commit with fix+test truly required even for cross-repo fixes where the test lives in a different repo?
- Q10: where does the due date come from in real support-repo issues (label, form field, comment)? One real sample issue is needed to define the parser.
