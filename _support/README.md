# _support — customer-support task lib

Shared by `/support` (intake) and the `type == support` branch of `/drive`,
`design-score` and `/address-pr`. Nothing here posts to an issue.

## Scripts

| Script | Role |
|---|---|
| `parse-issue-url.sh [--canonical] <ref>` | URL or `owner/repo#N` to `owner repo number`; `GH_HOST` for the shorthand; exit 2 on a PR URL |
| `is-support-task.sh <file\|T<id>>` | exit 0 when the body has `- **Type**: support` or the frontmatter has `support-issue:` |
| `check-regression-commit.sh <base>..<head>` | same-commit rule, below |
| `gate-pr.sh <pr>` | `/address-pr` hook: resolve the task, skip non-support, fetch `pull/N/head`, run the check; fork PRs are blocked |

## Task shape

- Frontmatter: `support-issue: <canonical url>` (dedup key), optional `support-report: on|off` (absent = off; read only by the later reporter phase), existing `deadline: YYYY-MM-DD`.
- Body: `- **Type**: support`, `## Customer summary`, `## Repro`, `## Regression test`.

## Fix-side gates (via `/drive`)

- **Phase 2**: `## Repro` (minimal, sanitized of customer data, copy-pasteable) and `## Regression test` (path of the new e2e test) are mandatory; `design-score` hard-fails a support doc missing either or holding placeholders.
- **Phase 3**: write the e2e test first and record its failing (red) output in the PR body, then fix to green.
- **Phase 4**: fix and test land in the same commit. Run `check-regression-commit.sh origin/main..HEAD` before opening the PR; `/address-pr` runs `gate-pr.sh` at its hard gate.

## Same-commit rule

- Every commit that touches non-test source must also touch a path matching `SUPPORT_E2E_GLOB`, or carry a non-empty `No-regression-test: <reason>` trailer. Docs, `dev/**` and e2e paths are not source.
- The trailer needs the user's explicit approval; the script checks only that it exists and prints a warning.
- Cross-repo fixes: the check runs in the repo where the fix lands. If the test must live elsewhere, use the trailer.
- Fails closed: exit 1 on a violation, exit 2 on a bad range.

## Configuration (env vars, never hardcoded)

- `SUPPORT_E2E_GLOB`: whitespace-separated globs, `*` spans `/`, a leading `**/` also matches the repo root. Default: `**/e2e/** **/tests/e2e/** **/*_e2e* **/*e2e_test*`.
- `GH_HOST`: host for the `owner/repo#N` shorthand (default `github.com`).
