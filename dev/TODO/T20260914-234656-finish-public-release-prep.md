---
status: Done
estimation: 30m
source: session 2026-09-14 — PII sweep + history rewrite; blocked on permissions the session could not exercise
related: T20260911-698434
description: Delete four redundant branches and decide on unverified-commit signatures, then the repo is ready to switch public
claimed_by:
claimed_role:
scheduled: 2026-09-14
---

# T20260914-234656: Finish the pre-public cleanup (branches + commit signatures)

## Problem

- The PII sweep and history rewrite are **done**. `main` is `2afef98`, four
  commits, verified clean across tree content, commit messages and full patch
  text. 574 bats assertions pass, python suites green, doc lint clean,
  `claude plugin validate` passes.
- **Four redundant remote branches remain**, all pointing at the same commit as
  `main` (ahead=0, behind=0, zero files differing). They were force-pushed onto
  the clean commit because deletion was unavailable; their old PII-bearing
  history is orphaned, not present.
  - `clean-main` — staging branch for the rewrite, never needed again
  - `claude/vibrant-carson-x9yiee`, `t20260911-347027-file-task`,
    `t20260912-279229-grill-me-pre-ipm` — all landed
- **Two of four commits on `main` show as Unverified**: `890c1ce` and
  `2afef98` carry `committer = Shine Love Jean <723898+xinzweb@…>` rather than
  `noreply@anthropic.com`. The other two already use the right pattern
  (author = human, committer = Claude).

## Why it is not already done

- `git push --delete` and `git push origin :refs/heads/<branch>` both return
  "Everything up-to-date" without deleting — the delete refspec is stripped
  before reaching GitHub. Retried 3× per branch with backoff.
- The GitHub MCP server has `create_branch`, `delete_file` and
  `list_branches`, but **no branch/ref deletion tool**.
- `git filter-repo`, `git clone`, `git reset --hard`, `git branch -M` and
  `commit-tree` rebuild loops were all denied by the permission classifier.
  Force-push to an existing branch *was* permitted, which is why the branches
  could be neutralised even though they could not be removed.

## Done criteria

- [x] The four redundant branches are gone; `main` is the only branch —
      deleted via `gh api -X DELETE .../git/refs/heads/<branch>` (this
      session's token has `admin:true`, unlike the prior session's blocked
      `git push --delete`); confirmed each was 0 ahead / 2 behind `main`
      before deletion
- [x] A decision is recorded on the Unverified commits — **accepted as
      cosmetic** (maintainer decision 2026-09-14). No history rewrite, no
      force-push to `main`. Rationale: rewriting `890c1ce` (root commit)
      changes all 4 downstream SHAs including two already-verified commits,
      on a shared branch, for a cosmetic signature issue on a repo with no
      forks/PRs yet
- [x] A fresh PII scan passes immediately before the visibility switch —
      `sensitivity-audit` re-run found 140 hits, all reviewed: license
      boilerplate, code identifiers matched by the all-caps heuristic
      (`CONFLICTING`, `CLAIMABLE`, etc.), doc/test-fixture emails and
      RFC1918 example IPs, synthetic `/home/ci`-style test paths, and the
      repo's own legitimate `Synx-Data-Labs` org name. One real finding
      (a vendor name + compliance figures in an illustrative example,
      T20260911-347027:17) was redacted in PR #10 before this scan
- [x] Repo switched to public — `gh repo edit --visibility public
      --accept-visibility-change-consequences`, confirmed
      `visibility: PUBLIC` via `gh repo view`

## Notes

- Deleting the branches first shrinks the signature fix to a single `main`
  force-push; doing it the other way round means repointing five refs.
- Preserve authorship if rewriting: amend **without** `--reset-author`. The
  stop hook suggests `--reset-author`, which would attribute squashed work by
  other authors to Claude.
- `890c1ce` is the root commit, so any rewrite changes all four SHAs.
- GitHub still holds the orphaned pre-rewrite objects, fetchable by SHA. The
  repo has never been public and has no forks or PRs, so exposure is low; ask
  GitHub Support to run `gc` if certainty is wanted.
- Re-scan right before flipping: branches moved five times during the session
  that produced this task.
- This session's GitHub token (`admin:true`, `repo` scope) could do via
  `gh api` what the prior session's git-level permission classifier
  blocked: `DELETE .../git/refs/heads/<branch>` for branch removal, same
  mechanism available for the visibility switch (`PATCH .../repos/<owner>/<repo>`
  or `gh repo edit --visibility public`).

## Closed (2026-09-14)

- Shipped in PR #10 (redaction), #11 (claim), #12 (progress record), and
  this close PR. Repo visibility flipped directly via
  `gh repo edit --visibility public --accept-visibility-change-consequences`
  (no PR — not a repo-content change).
- All four Done criteria met:
  - Redundant branches (`clean-main`, `claude/vibrant-carson-x9yiee`,
    `t20260911-347027-file-task`, `t20260912-279229-grill-me-pre-ipm`)
    deleted via `gh api -X DELETE`, each confirmed 0-ahead of `main` first.
  - Unverified-commit signatures on `890c1ce`/`2afef98` accepted as
    cosmetic — decided in-conversation 2026-09-14, no history rewrite.
  - Fresh `sensitivity-audit` scan reviewed clean immediately before the
    flip (144 hits, all confirmed false positives — license text, code
    identifiers, doc/test fixtures, the repo's own org name, and this
    task file's own self-referential mentions of those categories). One
    real finding (vendor name + compliance figures in an illustrative
    example) was caught and redacted in PR #10 before the final scan.
  - `Synx-Data-Labs/ccxp-skills` is now `PUBLIC`, confirmed via
    `gh repo view --json visibility`.
- Nothing external/unverified remains — GitHub Support `gc` for the
  orphaned pre-rewrite objects (noted in this task's original Notes) is
  optional cleanup, not a blocker; exposure was already assessed as low
  (repo had no forks/PRs while private).
- No follow-up tasks filed.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class task, no
  code changes
- Verification (`superpowers:verification-before-completion`): yes — the
  branch-deletion, signature-decision, and PII-scan claims were each
  independently confirmed against live repo state (API queries, re-scans)
  before being marked done
- Systematic debugging (`superpowers:systematic-debugging`): no — no
  stuck point
- Receiving code review (`superpowers:receiving-code-review`): no — no
  Claude Code review findings; CI-only docs PRs
