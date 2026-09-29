---
status: Open
estimation: 2h
source: this conversation, 2026-09-28 — live incident while running /land
related: T20260910-919422, T20260922-383156, T20260922-253015
---

# T20260928-608242: Remove `lint-docs.sh`'s `--fix` entirely and require an explicit path argument

## Problem

- **Type**: bug
- Today, `bash _docs/lint-docs.sh --fix` was called with an accidentally-empty
  path list (a caller-side bug, not the script's). `lint_docs_run` treats zero
  paths as "default scope" (`_docs/lint-docs.sh:330`): it sets
  `explicit=0` and substitutes the full repo config-glob, then runs
  `markdownlint-cli2 --fix` directly against it — 1509 files in this repo.
- That raw run hit an `EACCES` writing into `.git/objects/pack/...rev`
  and fell back to the vendored MD032 check, an unscoped, surprising blast
  radius for what was meant to be a 2-file guard.
- **This is the third distinct incident in this script's `--fix` path**:
  T20260910-919422 fixed uncontrolled repo-wide linting by adding
  `--no-globs` when the caller passes explicit paths; T20260922-383156 then
  found `--fix` still corrupts prose (`MD004`/`MD037`) even when scoped, and
  added an isolated-tmpdir safe-fix override — but that override only
  activates when `explicit=1` (`_lint_docs_run_tool`,
  `_docs/lint-docs.sh:290`). The zero-explicit-paths branch was never
  covered by either fix, so a caller bug that yields an empty path list
  silently falls back to the exact unscoped, non-isolated `--fix` behavior
  both prior tasks fixed for the explicit-path case.
- Two rounds of incremental "make `--fix` safer" patches have not closed
  the risk surface — a third, different failure mode keeps appearing.
  Removing `--fix` (making the tool check-only, matching the vendored
  path's own existing design note: "check-only... logs and reports without
  fixing") and requiring an explicit path (erroring on zero args instead of
  substituting a default scope) removes the whole class at once instead of
  patching the next surfaced variant.

## What to do

- Remove the `--fix` option and its supporting code
  (`_lint_docs_safe_fix`, the `fix`-branches in `_lint_docs_run_tool` and
  `lint_docs_run`, `_LINT_DOCS_SAFE_FIX_DISABLE_RULES`) from
  `_docs/lint-docs.sh`.
- Make a path argument mandatory: `lint_docs_run` should print usage and
  return 2 when `paths` is empty, instead of substituting
  `_LINT_DOCS_DEFAULT_PATHS`.
- Update the two callers that pass `--fix`: `gcpr/SKILL.md` (Step 1.5) and
  `new-task/SKILL.md` (Step 4) — drop `--fix`, keep the existing
  empty-`$CHANGED_MD`/explicit-path guards.
- Update `tests/lint-docs.bats` (12 `--fix` assertions currently, all of
  them — `_docs/lint-docs.bats` has none) to drop the fix-mode cases, and
  add a zero-args-errors case to `_docs/lint-docs.bats`.
- Update the header-comment usage block in `_docs/lint-docs.sh` itself
  (currently documents `--fix` and the no-args default scope).

## Done when

- [ ] `_docs/lint-docs.sh` has no `--fix` code path and no default-scope
  substitution for empty args
- [ ] `bash _docs/lint-docs.sh` (no args) exits 2 with a usage message
- [ ] `gcpr` and `new-task` no longer pass `--fix`
- [ ] Both bats suites for `lint-docs.sh` green

## Out of scope

- The PNG-mutation report (T20260922-253015) — separate investigation, not
  blocking this removal. **Update 2026-09-29**: that investigation
  confirmed the reproduction and traced it to the same root mechanism this
  task already targets — `markdownlint-cli2` given a **directory** argument
  (the bare/default no-args scope) doesn't filter to `.md`, so `--fix`
  corrupts any binary file it finds there too. This task's fix (mandatory
  explicit path, no more directory-arg default scope) closes that vector
  too, as a side effect — no separate fix task needed.

## Caller-list gap found during T20260922-253015 (2026-09-29)

"Update the two callers that pass `--fix`" above names only `gcpr/SKILL.md`
and `new-task/SKILL.md`, but `git grep -n "lint-docs.sh --fix"` also finds
two more bare (no-path) invocations that will need the same treatment once
`--fix` requires an explicit path: `ccxp/SKILL.md:422` and
`retro/SKILL.md:293` (both `bash .../lint-docs.sh --fix || true`, no path
argument — the same default-scope guard use case T20260910-919422's Root
cause section already flagged as "left unchanged" for CI-parity coverage).
Add these two to the caller-update step, or decide their default-scope
guard behavior needs a different replacement (e.g. an explicit `**/*.md`-
scoped call, or drop the guard from these two skills) before landing this
task.
