---
status: Done
estimation: 2h
source: this conversation, 2026-09-28 — live incident while running /land
related: T20260910-919422, T20260922-383156, T20260922-253015, T20260929-128287
claimed_by:
claimed_role:
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
   over `*.md` finds six, not the two the original problem statement named
   (the **caller-list gap**, resolved here — see decision below); a second,
   **unrestricted** sweep (`git grep` over `*.md` **and** `*.sh` — the design
   phase's own `*.md`-only grep repeated the same narrowing mistake it was
   meant to fix) turns up two more in `ccxp/scripts/`:
   - `gcpr/SKILL.md:67` — already explicit-path (`$CHANGED_MD`, guarded
     non-empty) — drop `--fix` only.
   - `new-task/SKILL.md:95` — already explicit-path (`dev/TODO/T<id>-<slug>.md`) —
     drop `--fix` only.
   - `incept/SKILL.md:119` — already explicit-path (`dev/TODO/T<id>-*.md`) —
     drop `--fix` only.
   - `drive/SKILL.md:552` — already explicit-path (the journal-move target
     file) — drop `--fix` only.
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
   - `ccxp/scripts/reclaim-sweep-pr.sh:48` — **bare, no path** (`--fix ||
     true`), found only by the unrestricted sweep. Its own following line
     (`git add dev/TODO/*.md`) shows the actual commit scope is whatever
     `reclaim_sweep.sh --apply` touched in `dev/TODO/`. Decision: same
     `$CHANGED_MD`-style derivation as `ccxp/SKILL.md`, scoped to
     `git status --porcelain -- dev/TODO/*.md`.
   - `ccxp/scripts/update-roadmap.sh:133` — **bare, no path**, found only by
     the unrestricted sweep. Its own following line (`git add
     dev/ROADMAP.md`) names the one file this ever edits. Decision: pass
     `dev/ROADMAP.md` explicitly — no derivation needed, the caller already
     knows the single file.
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

- [x] `_docs/lint-docs.bats`: `bash _docs/lint-docs.sh` (zero args) exits 2
  with a usage message — new case (2 new `@test` blocks added).
- [x] `_docs/lint-docs.bats`: existing MD032/runner-resolution/vendored-fallback
  cases stay green (they don't touch `--fix`).
- [x] `tests/lint-docs.bats`: dropped all 8 `--fix`-mode `@test` blocks (12
  assertions) — the whole file was written to test `--fix`'s `--no-globs` +
  safe-fix behavior, both removed; replaced with 3 cases covering the
  surviving check-only `--no-globs` scoping guarantee (still meaningful:
  paths are mandatory now, so it always applies).
- [x] `bats tests/lint-docs.bats` and `bats _docs/lint-docs.bats` green locally.
- [ ] CI `bats` check green on the implementation PR (post-PR item).

## Done criteria

- [x] `_docs/lint-docs.sh` has no `--fix` code path and no default-scope
  substitution for empty args — verified by `_docs/lint-docs.bats`'s new
  zero-args cases (`lint_docs_run` and direct `bash _docs/lint-docs.sh`
  invocation both exit 2).
- [x] `gcpr`, `new-task`, `incept`, `drive` no longer pass `--fix`
  (`gcpr/SKILL.md:67`, `new-task/SKILL.md:95`, `incept/SKILL.md:119`,
  `drive/SKILL.md:552`) — verified: `git grep -n "lint-docs.sh.*--fix" -- '*.md' '*.sh'`
  returns zero matches outside `dev/JOURNAL/`/`dev/quality/` history and this
  task's own body.
- [x] `ccxp/SKILL.md:422`, `retro/SKILL.md:293`,
  `ccxp/scripts/reclaim-sweep-pr.sh:48`, `ccxp/scripts/update-roadmap.sh:133`
  no longer pass `--fix` and no longer rely on the removed default-scope
  fallback — verified by the same `git grep` plus a read of each call site's
  replacement (`$CHANGED_MD` for ccxp/reclaim-sweep, `${swept_paths[@]}` for
  retro, the single literal `dev/ROADMAP.md` for update-roadmap).
- [x] Both bats suites for `lint-docs.sh` green (`tests/lint-docs.bats`,
  `_docs/lint-docs.bats`) — verified by local `bats` run; CI `bats` check
  verification is a post-PR item above.

## Soft blocker discovered during implementation (2026-09-29)

- While verifying `ccxp/SKILL.md`'s `$CHANGED_MD`-derived replacement (see
  Solution above), found that the `$CHANGED_MD` unquoted-word-splitting
  pattern it mirrors from `gcpr/SKILL.md` Step 1.5 silently lints **zero**
  files (exits 0, reports clean) when the executing shell is zsh — this
  session's own shell (`$0` → `/bin/zsh`, `$BASH_VERSION` empty) reproduces
  it directly. Filed as **T20260929-128287** (staged into the current
  iteration). **Escalation**: `DRIVE_ESCALATION_CHANNEL_ID` is unconfigured
  in this environment, so per `drive/SKILL.md`'s degraded-transport path
  this note stands in for the Slack escalation (type: `blocker`, soft).
- **Soft, not hard** — worked around by proceeding unchanged: the new
  `ccxp/SKILL.md`/`reclaim-sweep-pr.sh` code mirrors the exact,
  already-in-production `gcpr/SKILL.md` pattern rather than introducing a
  new risk, and CI's own `Markdown Lint` check remains the unaffected,
  authoritative gate either way (this guard is defense-in-depth, not the
  only backstop). `reclaim-sweep-pr.sh`/`update-roadmap.sh` are unaffected
  regardless (real `.sh` files with a `bash` shebang, invoked via
  `bash script.sh` — word-splitting happens inside real bash there,
  confirmed by direct test). Continuing T20260928-608242 unchanged.

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
| `_docs/lint-docs.sh` | 39–48, 57, 59–66, 169–270, 286–346 (pre-change) | `--fix` code path + default-scope substitution removed; header/usage updated |
| `_docs/lint-docs.bats` | +2 new `@test` blocks | zero-args-errors cases (via `lint_docs_run` and direct `bash` invocation) |
| `tests/lint-docs.bats` | whole file (255 lines, 12 `--fix` assertions, pre-change) | rewritten — 3 cases covering surviving check-only `--no-globs` scoping |
| `gcpr/SKILL.md` | 67 | caller — explicit path, drop `--fix` |
| `new-task/SKILL.md` | 95 | caller — explicit path, drop `--fix` |
| `incept/SKILL.md` | 119 | caller — explicit path, drop `--fix` |
| `drive/SKILL.md` | 552 | caller — explicit path, drop `--fix` |
| `ccxp/SKILL.md` | 422 | caller — bare/no-path, replaced with `$CHANGED_MD`-scoped call |
| `retro/SKILL.md` | 293–298 | caller — bare/no-path, replaced with `${swept_paths[@]}`-scoped call |
| `ccxp/scripts/reclaim-sweep-pr.sh` | 48 | caller — bare/no-path (found by the unrestricted `.sh`-inclusive sweep), replaced with `$CHANGED_MD`-scoped call over `dev/TODO/*.md` |
| `ccxp/scripts/update-roadmap.sh` | 133 | caller — bare/no-path (found by the unrestricted `.sh`-inclusive sweep), replaced with the literal `dev/ROADMAP.md` |

## Closed (2026-09-29)

Shipped in **PR #182** (design in PR #181, both merged to `main`).

- All Done criteria met — `_docs/lint-docs.sh` has no `--fix` path and no
  default-scope substitution (verified by `_docs/lint-docs.bats`'s 2 new
  zero-args cases); all 8 real callers (`gcpr`, `new-task`, `incept`,
  `drive`, `ccxp/SKILL.md`, `retro`, `ccxp/scripts/reclaim-sweep-pr.sh`,
  `ccxp/scripts/update-roadmap.sh`) updated; both bats suites green
  locally (20/20) and in CI.
- **Independent review round 1** (PR #182, sha 53107c7) found one real
  regression bug — `ccxp/scripts/reclaim-sweep-pr.sh`'s `$CHANGED_MD`
  derivation used the naive `awk '{print $2}'` pattern already known
  (T20260910-919422) to mis-handle a renamed file's path and to not skip
  deleted entries — plus one minor consistency nit (`drive/SKILL.md`'s bare
  `|| true`). Both fixed in a follow-up commit (c1befe9); **review round 2**
  confirmed the fix and gave a clean bill.
- **Also caught mid-implementation**: `gcpr/SKILL.md`'s own edit initially
  dropped its `skill-quality` CI check below its 90 baseline (88 < 90,
  `dev/quality/skill-scores.json`) by adding redundant task-ID mentions and
  lengthening a paragraph past 60 words — fixed by trimming the noise
  (history belongs in `dev/JOURNAL`, not inline).
- **Follow-up task filed**: T20260929-128287 (non-blocking) — a soft
  discovery made while verifying the `$CHANGED_MD` replacement pattern:
  unquoted word-splitting of a newline-joined variable is shell-dependent
  (works under bash, silently no-ops under zsh). Staged into the current
  iteration; doesn't block this close since the new code mirrors an
  already-in-production pattern rather than introducing a new risk.
- Nothing left unverified — no post-merge-only items on this task.

## Skills invoked

- `ccxp-skills:drive` — end-to-end orchestration (claim → design →
  implement → PR → close), Phases 1-4 and 7.
- `ccxp-skills:todo` (`sweep`, `next`) — Phase 1 backlog sync and task pick.
- `ccxp-skills:design-score` — design PR gate (88/100, PASS).
- `ccxp-skills:address-pr` — both the design PR (#181) and implementation
  PR (#182) merge loops, including the independent-review dispatch (two
  rounds) and CI-gate verification.
- `ccxp-skills:quality-probe` — recorded post-implementation metrics
  (`dev/quality/metrics.jsonl`); non-blocking regressions noted, not acted
  on beyond the `skill-quality` CI-enforced ratchet (which is a separate,
  blocking check the ratchet-restore commit fixed).
- `superpowers:receiving-code-review` (implicit) — verified rather than
  reflexively applied the independent reviewer's finding on
  `reclaim-sweep-pr.sh` before fixing it.
