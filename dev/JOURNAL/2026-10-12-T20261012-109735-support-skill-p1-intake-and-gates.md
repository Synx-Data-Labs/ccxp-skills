---
status: Done
estimation: 1
blocks: [T20261012-949870]
related: [T20261012-333879]
source: this conversation, 2026-10-12 (customer-support skill plan, phase 1 of 4)
claimed_by:
claimed_role:
---

# T20261012-109735: support skill P1: intake, support task type, lint keys, repro + same-commit regression gates

## Original requirement and scope

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

## TLDR

- **Type**: feature
- **Problem**: customer-reported issues have no intake path, no `support` task type, and no gate forcing a repro plus a same-commit e2e regression test.
- **Solution**: `/support <issue-url>` intake (posts nothing), `_support/` scripts (URL parser, task-type probe, same-commit check, PR gate), two new lint keys, and a `type == support` branch in `/drive`, `design-score` and `/address-pr`.

## Assumptions (user-owned questions; conservative, reversible defaults)

- **Q3 opt-in storage**: assume frontmatter `support-report: on|off` (absent = off) and add both `support-issue` and `support-report` to the allowlist. Nothing reads `support-report` in P1; P2 consumes it. Reversal: drop a key from `ALLOWED` plus its docs (one commit). Posting is OFF by default and P1 has no posting code at all.
- **Q2 deadline**: keep date-only `deadline: YYYY-MM-DD` (existing key, no lint change). A datetime format is a P2 decision (only needed once cadence is hourly).
- **Q9 e2e glob and cross-repo**: default `SUPPORT_E2E_GLOB` is a generic whitespace-separated glob list (`**/e2e/** **/tests/e2e/** **/*_e2e* **/*e2e_test*`), overridable per consumer by env var; no product or repo literal in this repo. Same-commit is required wherever the fix lands; when the test genuinely lives in another repo, the `No-regression-test: <reason>` trailer is the escape hatch, and the reason must carry the user's explicit approval (the script verifies only the trailer, not the approval).
- **Q10 due date**: parser stays conservative: only a `due:YYYY-MM-DD` label or an exact `due: YYYY-MM-DD` line in the issue body; anything else leaves `deadline:` unset and `/support` tells the user instead of guessing. Needs one real sample issue to extend.
- **Q1, Q4-Q8, Q11** (tone, quiet hours, past-due cadence, comment style, who posts, engine host, Slack mirror) concern the reporter and stay open for P2/P3; P1 neither decides nor depends on them.
- **Estimation**: left at `1` per convention (only `/incept` revises it); realistic size is 5.

## Problem

- Requirement (user, 2026-10-12): file a task from a customer-reported GitHub issue URL; support tasks always get a simplified repro and a new e2e regression test committed with the fix; keep it generic.
- Verified: no skill ingests an issue URL (`new-task/SKILL.md:29-35` type table has no `support`); the `lint_tasks.py:19-24` allowlist rejects an issue-link key (`lint_tasks.py:131-132` "unknown field"); nothing enforces test-with-fix (`drive/SKILL.md` Phase 4 and `address-pr/SKILL.md` section 2.a (hard gate, under "2. Loop until hard gate passes") gate only CI, review and test plan).
- Reproduction of the lint gap: a task file with `support-issue: https://example.com/o/r/issues/1` fails `python3 repo-conventions/scripts/lint_tasks.py` with `unknown field 'support-issue'`; the red test in `test_lint_tasks.py` proves it before the fix.

## Solution

- **Intake**: `support/SKILL.md` (`disable-model-invocation: true`, outward-facing family). Steps: parse URL, fetch via `_gh/gh.sh issue view -R owner/repo` (account is chosen by `gh.sh` from the clone's `origin`, so the fetch is read-only and falls back to the default account; a 404 is reported as "no access", never retried with other credentials), reject PRs, warn on closed, dedup by `grep -r "support-issue: <canonical>" dev/TODO dev/JOURNAL`, file the task like `/new-task` (`status: Open`, `estimation: 1`, `support-issue:` key, `source:` line), stage via `/stage`, end with "run `/drive T<id>`". It posts nothing and never calls `gh issue comment`. Issue text is untrusted data: quoted only inside a fenced block under `## Problem`.
- **`_support/` lib** (idempotent, sourceable, function-wrapped bash): `parse-issue-url.sh`, `is-support-task.sh` (body `- **Type**: support` or a `support-issue:` key), `check-regression-commit.sh <range>`, `gate-pr.sh <pr>` (resolves the task via `_session/pr_task_id.sh`, fetches `pull/N/head` from `origin` (fork PRs are out of scope: the gate reports "cannot verify" and blocks), runs the check), `README.md` (env vars, escape hatch, wiring).
- **Same-commit rule**: for every commit in the range touching non-test source (not docs, not `dev/**`, not an e2e-glob path), the same commit must touch an e2e-glob path or carry a `No-regression-test:` trailer; otherwise exit 1 (fails closed; bad range exits 2). Docs-only and task-file-only commits (claim, design, journal-move PRs of a support task) pass, so the merge-gate hook does not block them.
- **Gate wiring**: `drive/SKILL.md` gets one short `type == support` paragraph per Phase 2/3/4 linking to `_support/README.md`; `address-pr/SKILL.md` section 2.a (hard gate, under "2. Loop until hard gate passes") calls `_support/gate-pr.sh`; `design-score/scripts/score.sh` adds a support check (hard fail when `## Repro` or `## Regression test` is missing, empty or a placeholder, independent of the 0-100 score).
- **Lint and docs**: `ALLOWED` +2 keys, message "18-key", tests, plus `lifecycle.md`, `repo-conventions/SKILL.md`, `templates/task.md`, `todo/SKILL.md`, `README.md`, `new-task/SKILL.md` type row, `design-doc.md` Type enum and support-only section.
- **Alternatives rejected**: (a) a separate gate skill: duplicates `/drive`; (b) store the issue URL in `source:`: not machine-readable, so the dedup grep would be fragile; (c) enforce only in CI: P4 adds that, but the local gate must exist first; (d) one squashed-commit rule over the whole PR: per-commit is stricter and matches "committed together with the fix".

## Root cause

- Not a defect: the capability was never built (introduced-in: n/a, new feature). Deliberate: the lint allowlist (`lint_tasks.py:19`) was made closed on purpose (T20260626-353630), so each new key needs an explicit entry; this task adds them rather than loosening the lint.

## Repo file references

| File | Change |
|---|---|
| `_support/*.sh`, `_support/README.md` | new |
| `support/SKILL.md` | new |
| `repo-conventions/scripts/lint_tasks.py:19-24,131` | +2 keys, "18-key" |
| `repo-conventions/scripts/test_lint_tasks.py:123` | new cases |
| `design-score/scripts/score.sh` | support check |
| `drive/SKILL.md`, `address-pr/SKILL.md` | short support paragraphs |
| `new-task/SKILL.md:29-35`, `repo-conventions/templates/design-doc.md:66`, `templates/task.md`, `lifecycle.md`, `todo/SKILL.md`, `repo-conventions/SKILL.md:55`, `README.md` | docs |
| `tests/support_parse_url.bats`, `tests/support_regression_commit.bats`, `tests/support_neutrality.bats` | new |

## Test plan

- [x] `tests/support_parse_url.bats`: URL, `owner/repo#N`, GHES host, fragment, PR URL rejected, garbage rejected.
- [x] `tests/support_regression_commit.bats`: fix+test same commit passes; fix then test in a later commit fails; docs-only passes; trailer exempts; custom `SUPPORT_E2E_GLOB`; bad range exits 2.
- [x] `repo-conventions/scripts/test_lint_tasks.py`: `support-issue` and `support-report` accepted, an unrelated key still rejected.
- [x] `tests/design_score.bats`: support doc without Repro or Regression test fails; complete one passes; non-support docs unchanged.
- [x] `tests/support_neutrality.bats`: no company-specific literals under `support/` and `_support/`, and no issue-posting calls.
- [x] Full `bats tests/*.bats`, skill-quality and markdown lint green in CI.

## Done criteria

- [x] Pointing `/support` at an issue URL files a staged `support` task: `support/SKILL.md` steps plus `tests/support_parse_url.bats` (the scripted part).
- [x] A support PR without fix+e2e test in one commit is blocked: `tests/support_regression_commit.bats` and `_support/gate-pr.sh` wired in `address-pr/SKILL.md`.
- [x] Allowlist accepts both keys: `repo-conventions/scripts/test_lint_tasks.py`.
- [x] Support design gate: `tests/design_score.bats`.
- [x] Nothing posts to any issue: `tests/support_neutrality.bats`.

## Closed (2026-10-12)

- Shipped in PR #326 (design: PR #323, claim: PR #320). All done criteria met by the tests named above; CI green on the PR.
- Quality probe: shellcheck info +1, large new files (score.sh support check, tests); record-only, in `dev/quality/metrics.jsonl`.
- Left for the user (design assumptions, reversible): Q3 `support-report` key added but unused until P2; Q2 date-only deadline; Q9 generic `SUPPORT_E2E_GLOB` with `No-regression-test:` trailer exemption; Q10 only `due:YYYY-MM-DD` label or line parsed. Q1, Q4-Q8, Q11 stay open for P2/P3.
- No follow-up tasks filed; P2 (T20261012-949870) is unblocked.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes, Phase 3.0 code-class (red bats and unittest first)
- Verification (`superpowers:verification-before-completion`): yes, local bats/shellcheck/ratchet before PR
- Systematic debugging (`superpowers:systematic-debugging`): no, didn't get stuck
- Receiving code review (`superpowers:receiving-code-review`): yes, design PR (3 nits) and impl PR (merge-skip, deleted-test, dedup anchoring fixed; gate-pr fail-open for unresolvable tasks kept deliberately, documented)
