---
status: Done
scheduled: 2026-10-05
estimation: 2
source: lsc-pa PR #159 follow-up, 2026-09-25
related: T20260925-219021
claimed_by:
claimed_role:
---

# T20260925-427007: Four scripts look for `gh.sh` at the dead `~/.claude/skills/_gh/` path

## TLDR

- **Type**: bug
- **Problem**: four callers hardcode the pre-plugin symlink path
  `~/.claude/skills/_gh/gh.sh` to find the account-aware `gh` wrapper; under
  a plugin install that path never exists, so they silently fall back to
  bare `gh` (wrong-account auth, or a skipped check).
- **Solution**: resolve the wrapper relative to each caller's own file
  location (siblings under the same repo root) instead of a hardcoded
  absolute path, falling back to bare `gh` only when the sibling is
  genuinely missing; `lint_refs.py` additionally searches the plugin cache
  for vendored copies that have no `_gh/` sibling of their own.

## Problem

- **Type**: bug
- Under a plugin install, `_gh/gh.sh` lives at
  `$CLAUDE_CONFIG_DIR/plugins/cache/ccxp-skills/ccxp-skills/<version>/_gh/gh.sh`
  (verified locally: `ls ~/.claude/plugins/cache/ccxp-skills/ccxp-skills/1.0.1/_gh/gh.sh`).
  The legacy symlink path `~/.claude/skills/_gh/gh.sh` doesn't exist, so
  these callers silently fall back to bare `gh`. That can authenticate as
  the wrong account on multi-account machines, or skip work outright:

  | Call site | Effect |
  |---|---|
  | `repo-conventions/scripts/lint_refs.py:290` (`gh_argv()`) | `PR #N`/`issue #N` linking runs as the wrong account; vendored copies inherit this |
  | `_taskid/url.sh:43` (`taskid-gh`) | T-id issue links resolve under the wrong account |
  | `_gh/ci-triage.sh:35` (`ci_triage_gh`) | CI triage `gh` calls run as the wrong account |
  | `quality-probe/scripts/probe.sh:45` (`QP_GH`) | code-scanning probe always skipped |

- Evidence:
  - lsc-pa's quality-probe run on 2026-09-25 printed
    `skip: code-scanning unavailable`.
  - lsc-pa fixed its vendored `lint_refs.py` in <consumer-account>/lsc-pa#159
    (`find_gh_wrapper()`: newest plugin-cache version, then the legacy
    path).
  - This clone confirms the dead path: `~/.claude/skills/_gh/gh.sh` does not
    exist, only `~/.claude/plugins/cache/ccxp-skills/ccxp-skills/1.0.1/_gh/gh.sh`
    (assumed representative of other plugin-install machines; verified on
    this one).
- T20260925-219021 lists `_taskid/url.sh` as one caller in its much larger
  "retire `auto-switch.sh`" scope. This task is just the dead-path lookup at
  all four sites, so it can ship on its own. Tick that bullet there when
  this one lands.

## Context

- **Bug** — repro environment: any machine where ccxp-skills is installed
  as a Claude Code plugin (the now-standard install path) rather than the
  old manual `~/.claude/skills/` symlink layout. `_gh/gh.sh` itself (the
  account-aware wrapper, unaffected by this bug) picks the GitHub account
  that can read the repo's `origin` remote and runs `gh` with a
  process-scoped `GH_TOKEN` — see `dev/JOURNAL/2026-09-29-T20260925-219021-retire-auto-switch-gh-wrapper-only.md`.
  Each of the four call sites is supposed to reach that same wrapper but
  checks a path that only existed under the retired layout.
- This repo has **no precedent yet** for resolving `$CLAUDE_CONFIG_DIR`
  (verified: `git grep -n CLAUDE_CONFIG_DIR` outside this task file returns
  nothing) — that gap is tracked separately in `T20261002-303999` and is
  out of scope here. This task only needs `$CLAUDE_CONFIG_DIR` for the
  plugin-cache *search fallback* (vendored `lint_refs.py` copies), so it
  reads the env var inline with a `~/.claude` default, the same fallback
  `T20261002-303999` will eventually centralize — this task does not block
  on that one landing first.
- An established sibling-relative pattern already exists in this repo:
  `cleanup-branch/scripts/cleanup-branch.sh:17` resolves
  `"$(dirname "${BASH_SOURCE[0]}")/../../_gh/gh.sh"` rather than a
  hardcoded home-dir path — this task generalizes that same idea to the
  four sites above (plus a DI-seam-aware fallback chain, since three of the
  four already have one).

## Solution

- Each of the three bash call sites resolves `_gh/gh.sh` **relative to its
  own file**, computed once from `${BASH_SOURCE[0]}`, keeping the existing
  DI-seam-first / bare-`gh`-last fallback order:
  1. `_taskid/url.sh` (`taskid-gh`, sibling-of-parent: `_taskid/` and `_gh/`
     are both direct children of the repo root) →
     `$(dirname "${BASH_SOURCE[0]}")/../_gh/gh.sh`
  2. `_gh/ci-triage.sh` (`ci_triage_gh`, **same directory** as `gh.sh`) →
     `$(dirname "${BASH_SOURCE[0]}")/gh.sh`
  3. `quality-probe/scripts/probe.sh` (`QP_GH`, two levels under root) →
     `$(dirname "${BASH_SOURCE[0]}")/../../_gh/gh.sh`
  - **Per-site fallback asymmetry (not uniform — correcting an earlier draft
    of this design):** `taskid-gh` and `ci_triage_gh` fall back to bare `gh`
    when the resolved path is missing/non-executable (unchanged — this task
    only changes *which path* they check first). `QP_GH` is different: it
    is a plain variable, not a function with a fallback branch, and
    `qp-run-code-scanning` (`quality-probe/scripts/probe.sh:262`) already
    treats a missing/non-executable `$QP_GH` as "skip this check entirely"
    (`qp-log-skip code-scanning unavailable; printf 'null'; return 0`) —
    **not** a bare-`gh` call. This task changes only `QP_GH`'s *default
    value* (dead path → sibling-relative path); the existing
    skip-the-check-cleanly behavior on a still-missing wrapper is
    unchanged and must **not** be widened into a bare-`gh` fallback — that
    would be a behavior change beyond this bug's scope (pure path
    resolution, not probe semantics).
- `repo-conventions/scripts/lint_refs.py` (`gh_argv()`) gets a two-step
  resolution, since it is the one call site with vendored copies that
  physically move outside this repo (lsc-pa vendors a standalone copy, per
  the Problem section):
  1. Try the **sibling-relative** path first (`Path(__file__).resolve()
     .parent.parent.parent / "_gh" / "gh.sh"`), mirroring the existing
     `URL_SH` constant two lines above `gh_argv()` in the same file — this
     covers the plugin-internal / same-repo-checkout case with zero
     filesystem search.
  2. If that's missing (a vendored copy with no `_gh/` sibling), search
     `${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/cache/*/ccxp-skills/*/_gh/gh.sh`
     and take the lexicographically-last match (best-effort "newest
     version" — not full semver-aware, acceptable for this fallback path).
  3. Else, bare `gh` (unchanged final fallback).
- **Alternatives considered and rejected**:
  - *Keep the legacy path as a second fallback, add the plugin-cache search
    as a third* — rejected: the legacy path can never exist again (the
    symlink layout it pointed at is retired), so keeping it is dead weight
    the Done-when's `git grep` check would have to special-case instead of
    just asserting "gone."
  - *Introduce `$CLAUDE_PLUGIN_ROOT` as the primary resolution mechanism*
    (the Problem section's evidence / T20260925-219021 both mention it) —
    rejected for the three bash call sites: confirmed empty in this
    session's shell (`env | grep CLAUDE_PLUGIN_ROOT` → nothing), so it's
    only populated for hook-invoked contexts, not for a script someone runs
    directly or that another skill shells out to. Sibling-relative
    resolution via `${BASH_SOURCE[0]}` works in every invocation context
    and needs no environment plumbing.
  - *Centralize all four into one shared `find_gh_wrapper()` helper
    (bash+python)* — rejected for this task's scope: the three bash sites
    already have divergent, independent DI seams (`TASKID_GH`,
    `CI_TRIAGE_GH`, `QP_GH`) that predate this bug and are out of scope to
    consolidate; a shared-lib extraction is a separate, larger refactor
    (candidate follow-up, not required to fix the dead path).

## Test plan

- [x] `tests/taskid_url.bats`: added a case with a fake sibling `_gh/gh.sh`
      present (relative to a temp copy of `url.sh`) asserting `taskid-gh`
      invokes it, a case with no wrapper present asserting fallback to
      bare `gh` (stubbed) — unchanged fallback semantics, only the checked
      path moves — and a `git grep` regression guard against the dead path
      string. 3 new cases, all green.
- [x] `tests/ci-triage.bats`: same three cases for `ci_triage_gh` (same-dir
      sibling) — same unchanged bare-`gh`-fallback semantics. All green.
- [x] `tests/quality_probe.bats`: added a case asserting `QP_GH`'s *default
      value* resolves relative to `probe.sh` (not via `$HOME`), plus a
      `git grep` regression guard. The existing "logs 'unavailable'" case
      already covers the **unchanged** skip-cleanly behavior when `QP_GH`
      is missing (it sets `QP_GH` explicitly, independent of the default) —
      per the per-site asymmetry noted in `## Solution`, no new bare-`gh`
      fallback was added. 2 new cases, all green; whole file still 33/33.
- [x] `repo-conventions/scripts/test_lint_refs.py` (unit test, not bats —
      see rationale in `## Repo file references`): 4 new cases covering env
      override, own-sibling-present, plugin-cache-fallback (including
      lexicographically-last-version selection), and bare-`gh` when
      nothing resolves. All green; whole file 37/37.
- [x] Local: `bats tests/taskid_url.bats tests/ci-triage.bats
      tests/quality_probe.bats` (77/77) and
      `python3 repo-conventions/scripts/test_lint_refs.py -v` (37/37) all
      green. Full suite re-run for regressions: `bats tests/*.bats`
      (837/837) and every `test_*.py` in the repo, all exit 0. **Note**:
      `test_lint_refs.py` is not currently wired into `tests.yml` at all
      (verified: `grep -n test_lint_refs .github/workflows/tests.yml`
      returns nothing) — out of scope to fix here, flagged as a candidate
      follow-up so the new cases this task adds don't silently stop running
      in CI.
- [x] `git grep -nE '\.claude/skills/_gh|"skills" / "_gh"' -- '*.sh' '*.py'
      ':!tests/'` returns empty — verified locally post-implementation
      (required rewording two in-code comments that would otherwise have
      matched the same dead-path string they were describing).

## Done criteria

- [x] The three plugin-internal scripts resolve their sibling wrapper
      relative to themselves, each keeping its own pre-existing fallback
      behavior unchanged when the sibling is missing (bare `gh` for
      `taskid-gh`/`ci_triage_gh`; skip-the-check for `QP_GH` — see
      `## Solution`'s asymmetry note) — verified by `tests/taskid_url.bats`,
      `tests/ci-triage.bats`, `tests/quality_probe.bats` new cases above.
- [x] `lint_refs.py` tries its own plugin-relative location first, then the
      plugin-cache search for vendored copies — verified by
      `repo-conventions/scripts/test_lint_refs.py` new cases above.
- [x] Test cases (bats for the three bash sites, a Python unittest for
      `lint_refs.py`) cover wrapper resolution with a fake plugin layout
      and with no wrapper at all — same four test files above.
- [x] None of the four call sites references the legacy path any more —
      verified by `git grep -nE '\.claude/skills/_gh|"skills" / "_gh"' --
      '*.sh' '*.py' ':!tests/'` returning empty.

## Root cause

- The hardcoded `~/.claude/skills/_gh/gh.sh` path dates to a pre-plugin
  install layout where `ccxp-skills` was checked out and manually
  symlinked under `~/.claude/skills/`. This repo's single squashed history
  (`git log --follow` on all four call sites bottoms out at `5051a9e
  "Initial public release"`, 2026-09-28 — the split from the private
  source repo) means the exact original-introduction commit isn't
  recoverable here; the mechanism is confirmed by T20260925-219021's own
  Problem section, filed the same week, independently describing the same
  dead path at `_taskid/url.sh:43` (*verified* cross-reference, not
  speculation).
- It reads as an **oversight**, not a deliberate choice: all three bash
  sites (`taskid-gh`, `ci_triage_gh`, `QP_GH`) already carry a DI-seam +
  a "use the wrapper if found" fallback (bare `gh` for the first two,
  skip-the-check for `QP_GH` — see the asymmetry note in `## Solution`),
  i.e. the authors intended the wrapper to always be found when present —
  the bug is that the literal path stopped resolving once the plugin-cache
  layout replaced the symlink layout, and nothing flagged the now-permanent
  fallback branch each site quietly took instead.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_taskid/url.sh` | 36–45 | `taskid-gh()` — dead-path lookup, fix site #1 |
| `_gh/ci-triage.sh` | 28–38 | `ci_triage_gh()` — dead-path lookup, fix site #2 |
| `quality-probe/scripts/probe.sh` | 45 | `QP_GH` default — dead-path lookup, fix site #3 |
| `repo-conventions/scripts/lint_refs.py` | 95, 284–293 | `URL_SH` (existing sibling-relative pattern to mirror) and `gh_argv()` — dead-path lookup, fix site #4 |
| `cleanup-branch/scripts/cleanup-branch.sh` | 17 | existing sibling-relative precedent (`GH_SCRIPT=`) this task generalizes |
| `tests/taskid_url.bats`, `tests/ci-triage.bats`, `tests/quality_probe.bats` | — | new wrapper-resolution test cases (bash sites) |
| `repo-conventions/scripts/test_lint_refs.py` | — | new `gh_argv()` resolution test cases (Python unit test, not bats) |

## Closed (2026-10-06)

- Shipped in two PRs, after a design-only PR per `/drive` Phase 2:
  - Claim: [#256](https://github.com/Synx-Data-Labs/ccxp-skills/pull/256)
  - Design: [#257](https://github.com/Synx-Data-Labs/ccxp-skills/pull/257) — design-score 84/100 (PASS, threshold 70); one independent review round fixed two inaccuracies (a false "all three bash sites fall back to bare `gh`" claim — `QP_GH` actually skips the check cleanly; and a misassigned test-file location) before merge.
  - Implementation: [#258](https://github.com/Synx-Data-Labs/ccxp-skills/pull/258) — one independent review round, clean bill (no findings).
- All Done criteria met — see the checked boxes above:
  - All four call sites (`_taskid/url.sh`, `_gh/ci-triage.sh`, `quality-probe/scripts/probe.sh`, `repo-conventions/scripts/lint_refs.py`) resolve the `gh` wrapper relative to their own file location instead of the dead symlink-era path.
  - Each site's pre-existing fallback behavior is unchanged (bare `gh` for `taskid-gh`/`ci_triage_gh`, skip-the-check for `QP_GH`); `lint_refs.py` additionally gained a plugin-cache search step for vendored copies, documented as new (not "unchanged").
  - New test coverage: `tests/taskid_url.bats`, `tests/ci-triage.bats`, `tests/quality_probe.bats` (bats, 77/77 across the three files) and `repo-conventions/scripts/test_lint_refs.py` (Python unittest, 37/37). Full regression sweep (`bats tests/*.bats`, 837/837; every `test_*.py` in the repo) stayed green throughout.
  - `git grep -nE '\.claude/skills/_gh|"skills" / "_gh"' -- '*.sh' '*.py' ':!tests/'` returns empty.
- External/unverified: none — every Done criterion mapped to a test or command that was actually run (see Test plan above), not just asserted.
- Follow-up noted, not filed as a separate task (low-stakes, judgment call not to add backlog churn for it): `repo-conventions/scripts/test_lint_refs.py` is not wired into `.github/workflows/tests.yml` at all (pre-existing gap, confirmed still true post-merge) — the new `GhArgvTest` cases this task added only run when invoked manually or via a future fix to that gap.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — Phase 3.0, code-class. Each of the 4 fix sites had its test written first and verified RED (failing for the right reason — missing `GH_SH` attribute, bare-`gh`/dead-path still active, wrong default value) before the corresponding implementation commit, per the red-green cycle.
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6 (fresh re-run of the full bats suite, every `test_*.py`, shellcheck, and the Done-criteria `git grep` check immediately before the PR) and Phase 7.0 (this block). No Claude Code review iteration needed a re-verification pass (both PRs' reviews landed clean after at most one fix round).
- Systematic debugging (`superpowers:systematic-debugging`): no — no test took more than one attempt to turn green; the one design-time correction (the `QP_GH` fallback-behavior claim) was caught by the independent design review, not by a debugging session.
- Receiving code review (`superpowers:receiving-code-review`): yes — design PR #257's independent review found two real inaccuracies (steelmanned, both accepted and fixed, no pushback needed since both findings were correct on inspection against the actual code). Implementation PR #258's review was a clean bill, no findings to respond to.
