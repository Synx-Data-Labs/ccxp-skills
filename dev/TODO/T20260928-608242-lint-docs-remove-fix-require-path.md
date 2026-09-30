---
status: Design
estimation: 2h
source: this conversation, 2026-09-28 — live incident while running /land
related: T20260910-919422, T20260922-383156, T20260922-253015
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-28
---

# T20260928-608242: Remove `lint-docs.sh`'s `--fix` entirely and require an explicit path argument

## TLDR

- **Type**: bug
- **Problem**: `_docs/lint-docs.sh --fix` with an accidentally-empty path list silently
  falls back to an unscoped, non-isolated `--fix` over the whole repo — the third
  distinct incident in this code path (T20260910-919422, T20260922-383156, this one).
- **Solution**: remove `--fix` entirely (check-only, matching the vendored path's
  existing design note) and make a path argument mandatory (usage + exit 2 on empty
  args) — this removes the whole risk class instead of patching the next variant.

## Problem

- Today, `bash _docs/lint-docs.sh --fix` was called with an accidentally-empty
  path list (a caller-side bug, not the script's). `lint_docs_run` treats zero
  paths as "default scope" (`_docs/lint-docs.sh:330`): it sets `explicit=0` and
  substitutes the full repo config-glob, then runs `markdownlint-cli2 --fix`
  directly against it — 1509 files in this repo.
- That raw run hit an `EACCES` writing into `.git/objects/pack/...rev` and fell
  back to the vendored MD032 check — an unscoped, surprising blast radius for
  what was meant to be a 2-file guard.
- **Third distinct incident in this script's `--fix` path**:
  - T20260910-919422 fixed uncontrolled repo-wide linting by adding `--no-globs`
    when the caller passes explicit paths.
  - T20260922-383156 then found `--fix` still corrupts prose (MD004/MD037) even
    when scoped, and added an isolated-tmpdir safe-fix override — but that
    override only activates when `explicit=1` (`_lint_docs_run_tool`,
    `_docs/lint-docs.sh:290`).
  - The zero-explicit-paths branch was never covered by either fix, so a
    caller bug that yields an empty path list silently falls back to the
    exact unscoped, non-isolated `--fix` behavior both prior tasks fixed for
    the explicit-path case.
- Two rounds of incremental "make `--fix` safer" patches have not closed the
  risk surface — a third, different failure mode keeps appearing.

## Context

- `_docs/lint-docs.sh` is a shared script (`_docs/`) invoked from six skills'
  `SKILL.md` files across this repo (see Repo file references below) as a
  pre-commit doc-lint guard (MD032 blanks-around-lists, the recurring
  standup/journal render-bug class).
- Two calling shapes exist today:
  - **Explicit path(s)** — `gcpr`, `new-task`, `incept`, `drive` — already pass
    a caller-computed path list (e.g. `$CHANGED_MD`, a glob, a single file).
  - **Bare, no-path** — `ccxp`, `retro` — rely on the "no args = default scope
    (`dev/JOURNAL` + `dev/TODO`)" fallback as an intentional guard-everything
    call, always followed by `|| true` (fix-then-continue, non-blocking).
- The PNG-mutation investigation (T20260922-253015, out of scope here but
  informative) confirmed the same root mechanism: `markdownlint-cli2` given a
  **directory** argument doesn't filter to `.md`, so `--fix` over a directory
  can corrupt a binary file it finds there too. Check-only mode is harmless
  against the same directory argument — it just misreports a bogus lint error
  against the non-`.md` file instead of corrupting it. Removing `--fix`
  entirely closes that vector regardless of path-argument shape.

## Solution

Remove the whole `--fix` code path instead of patching the next variant:

1. **`_docs/lint-docs.sh`**: delete `_lint_docs_safe_fix`, `_LINT_DOCS_SAFE_FIX_DISABLE_RULES`,
   the `fix`-branches in `_lint_docs_run_tool` and `lint_docs_run`, and
   `_LINT_DOCS_DEFAULT_PATHS` (now dead — paths are mandatory, so nothing
   substitutes a default). `lint_docs_run` prints usage and returns 2 when
   `paths` is empty, instead of substituting a default scope. Since paths are
   now always caller-supplied, `_lint_docs_run_tool`'s `explicit` parameter
   collapses to always-1 (`--no-globs` always applies) — simplify its
   signature accordingly. Update the header usage/comment block to match
   (drop `--fix` and the no-args-default-scope description).
2. **Update every caller that passes `--fix`** — `git grep -n "lint-docs.sh --fix"`
   finds six, not the two the original problem statement named (the
   **caller-list gap**, resolved here — see decision below):
   - `gcpr/SKILL.md:67` — already explicit-path (`$CHANGED_MD`, guarded
     non-empty) — drop `--fix` only.
   - `new-task/SKILL.md:95` — already explicit-path (`dev/TODO/T<id>-<slug>.md`) —
     drop `--fix` only.
   - `incept/SKILL.md:119` — already explicit-path (`dev/TODO/T<id>-*.md`) —
     drop `--fix` only. (Missed by the original task filing; found via the
     same `git grep` sweep used for the ccxp/retro gap below — same
     caller-list-completeness gap, not a separate one.)
   - `drive/SKILL.md:552` — already explicit-path (the journal-move target
     file) — drop `--fix` only. (Same gap as `incept` above.)
   - `ccxp/SKILL.md:422` — **bare, no path** (`--fix || true`). Decision:
     replace with the same `$CHANGED_MD`-derived scoped call `gcpr` already
     uses (`git status --porcelain` → changed `*.md` paths), guarded
     non-empty, non-blocking (`|| echo "::warning::..."`). This preserves
     "guard whatever doc I'm about to commit this tick" without ever
     substituting a full-repo default scope.
   - `retro/SKILL.md:293` — **bare, no path**, but unlike `ccxp` its caller
     already computes the exact file list to commit (`${swept[@]}` — the
     journal-move destinations from the batch sweep just above). Decision:
     pass `${swept[@]}` explicitly instead of a fresh `$CHANGED_MD` re-derive
     — the caller already knows precisely which files it's about to commit.
3. **Alternatives considered and rejected**:
   - *Keep `--fix` but make the empty-path branch error too* (i.e. patch only
     the newly-discovered variant) — rejected: this is the third round of
     "patch the newly-discovered variant," and the task's own history shows
     each patch leaves another branch uncovered. Removing the feature removes
     the whole class.
   - *Give `ccxp`/`retro` a `**/*.md`-scoped default instead of dropping the
     guard* — rejected in favor of the `$CHANGED_MD`/`${swept[@]}`-derived
     scoped call above: a `**/*.md` glob re-introduces exactly the
     "unbounded blast radius" this task exists to close, just with a
     different glob instead of no glob.

## Test plan

- [ ] `_docs/lint-docs.bats`: `bash _docs/lint-docs.sh` (zero args) exits 2
  with a usage message — new case.
- [ ] `_docs/lint-docs.bats`: existing MD032/runner-resolution/vendored-fallback
  cases stay green (they don't touch `--fix`).
- [ ] `tests/lint-docs.bats`: drop all `--fix`-mode cases (12 assertions,
  8 `@test` blocks — the whole file was written to test `--fix`'s
  `--no-globs` + safe-fix behavior, both removed).
- [ ] `bats tests/` and `bats _docs/*.bats` green locally before pushing.
- [ ] CI `bats` check green on the implementation PR.

## Done criteria

- [ ] `_docs/lint-docs.sh` has no `--fix` code path and no default-scope
  substitution for empty args — verified by `_docs/lint-docs.bats`'s new
  zero-args case (`lint_docs_run` / `bash _docs/lint-docs.sh` with no args
  exits 2).
- [ ] `gcpr`, `new-task`, `incept`, `drive` no longer pass `--fix`
  (`gcpr/SKILL.md:67`, `new-task/SKILL.md:95`, `incept/SKILL.md:119`,
  `drive/SKILL.md:552`) — verified by `git grep -n "lint-docs.sh --fix"`
  returning zero matches under `*/SKILL.md`.
- [ ] `ccxp/SKILL.md:422` and `retro/SKILL.md:293` no longer pass `--fix`
  and no longer rely on the removed default-scope fallback — verified by the
  same `git grep` plus a read of both call sites' replacement (`$CHANGED_MD`
  for ccxp, `${swept[@]}` for retro).
- [ ] Both bats suites for `lint-docs.sh` green (`tests/lint-docs.bats`,
  `_docs/lint-docs.bats`) — verified by local `bats` run + CI `bats` check.

## Out of scope

- The PNG-mutation report (T20260922-253015) — separate investigation, not
  blocking this removal. That investigation confirmed the reproduction and
  traced it to the same root mechanism this task already targets —
  `markdownlint-cli2` given a **directory** argument (the bare/default
  no-args scope) doesn't filter to `.md`, so `--fix` corrupts any binary file
  it finds there too (check-only mode is harmless against the same directory
  argument — it just misreports a bogus lint error against the non-`.md`
  file instead of corrupting it). Of this task's two changes, **removing
  `--fix`** is what closes that vector; the mandatory-explicit-path half is a
  separate hardening (this task's own "1509 files, `EACCES`" incident) — no
  separate fix task needed either way, since this task already removes
  `--fix` entirely.

## Root cause

- `_docs/lint-docs.sh:330` (`lint_docs_run`): `[ "${#paths[@]}" -eq 0 ] &&
  { explicit=0; paths=("${_LINT_DOCS_DEFAULT_PATHS[@]}"); }` — introduced by
  T20260626-117003 (this script's original authoring) as an intentional
  "no args = guard the high-risk default scope" convenience for `ccxp`/`retro`'s
  ad-hoc commit paths. Deliberate at the time; it became a latent hazard once
  `--fix` was layered on top (T20260910-919422 onward) without re-examining
  whether the default-scope branch should ever also carry `--fix`.
- `_docs/lint-docs.sh:290` (`_lint_docs_run_tool`): the safe-fix isolation
  (T20260922-383156) is gated on `explicit=1`, so the default-scope branch
  (`explicit=0`) always falls through to the plain, non-isolated
  `markdownlint-cli2 --fix` invocation — the exact behavior an *explicit*
  path call was already hardened against.
- Both are oversights of omission (each prior fix scoped itself to the
  explicit-path branch that was in front of the author at the time), not
  deliberate decisions to leave the default-scope branch unsafe.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_docs/lint-docs.sh` | 39–48, 57, 59–66, 169–270, 286–346 | `--fix` code path + default-scope substitution to remove; header/usage to update |
| `_docs/lint-docs.bats` | new test | zero-args-errors case |
| `tests/lint-docs.bats` | whole file (255 lines, 12 `--fix` assertions) | drop all `--fix`-mode cases |
| `gcpr/SKILL.md` | 67 | caller — explicit path, drop `--fix` |
| `new-task/SKILL.md` | 95 | caller — explicit path, drop `--fix` |
| `incept/SKILL.md` | 119 | caller — explicit path, drop `--fix` (caller-list gap) |
| `drive/SKILL.md` | 552 | caller — explicit path, drop `--fix` (caller-list gap) |
| `ccxp/SKILL.md` | 422 | caller — bare/no-path, replace with `$CHANGED_MD`-scoped call |
| `retro/SKILL.md` | 293 | caller — bare/no-path, replace with `${swept[@]}`-scoped call |

## Skills invoked

(filled at close)
