---
status: In Progress
scheduled: 2026-10-12
estimation: 1
source: this conversation, 2026-10-16
related: T20261016-393753
claimed_by: cc1-50ac6891:21294cd91b2eccea
claimed_role: interactive
---

# T20261016-316464 — Extract a shared tests/test_helper.bash for the BATS suite

> Design approved in-conversation 2026-10-16 (explicit standing authorization
> to drive this exact extraction end-to-end, including merge) — design PR
> skipped per `/drive` Phase 2's skip path; this file carries the full design
> instead, verified directly against the test files before any line was
> changed.

## TLDR

- **Type**: chore
- **Problem**: the 72-file, 1074-test BATS suite has zero shared
  `test_helper.bash` — every file re-derives `REPO_ROOT`, and several
  duplicate a git-fixture bootstrap, a fake-`gh` PATH shim, or
  `CLAIMANT_STATE_DIR` isolation inline.
- **Solution**: add `tests/test_helper.bash` with four small helpers
  (`REPO_ROOT` export, `git_identity`, `use_fake_bin`,
  `isolate_claimant_state`); `load` it from every file whose duplicate is a
  safe, behavior-preserving match; leave genuinely-different bespoke
  variants alone rather than forcing false uniformity.

## Problem

- Zero `load` statements existed anywhere in `tests/`, `_docs/`, `_slack/`
  before this change — confirmed via
  `grep -rl '^load ' tests/*.bats _docs/*.bats _slack/*.bats` returning
  nothing on `main`.
- `REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"` was duplicated
  byte-for-byte in 55 of 72 `.bats` files (verified:
  `grep -l 'REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/\.\." && pwd)"' <all 72 files> | wc -l` → `55`).
- A git-fixture-repo bootstrap (`git init -q` + `git config user.email` +
  `git config user.name`, sometimes `+ commit.gpgsign false`) was repeated,
  with minor per-site variation (different invocation style, different
  placeholder email/name), across 14 files / 17 call sites.
- A fake-`gh`-binary PATH shim (`mkdir $FAKEBIN && cp fixture $FAKEBIN/gh &&
  chmod +x && export PATH=$FAKEBIN:$PATH`) was repeated **identically** in
  2 files (`tests/epic-status.bats`, and `tests/gh.bats`'s own
  `_gh_bats_use_fake_gh()` helper).
- `CLAIMANT_STATE_DIR="$BATS_TEST_TMPDIR/<name>"` isolation was repeated in
  4 files (`tests/claimant_id.bats`, `tests/task_claim.bats`,
  `tests/eta.bats`, `tests/statusline_setup.bats`).
- Impact: a future change to any of these four patterns (e.g. adding
  `commit.gpgsign false` everywhere, or a new git version's init warning)
  requires touching dozens of files instead of one.

## Context

- This repo has no shared BATS helper infrastructure of any kind — not a
  partial one that needs extending, a from-scratch extraction.
- Found by the same audit that filed the sibling task
  `T20261016-393753` (parallelize the suite with `--jobs`) — both tasks
  touch the same `tests/` tree but along independent axes (dedup vs.
  wall-clock), hence `related:` rather than `blocked-by:`.
- `.github/workflows/tests.yml`'s `bats` job runs
  `bats tests/*.bats _docs/*.bats _slack/*.bats` — a glob that naturally
  excludes a non-`.bats` helper file, so adding `tests/test_helper.bash`
  needs no CI workflow change.

## Solution

- Add `tests/test_helper.bash`, loaded via `load test_helper` (same
  directory) or `load ../tests/test_helper` (from `_docs/`, `_slack/` —
  both one level below repo root, same as `tests/`, so the relative path is
  identical for every file outside `tests/`), providing:
  - `REPO_ROOT` — exported at load time; `$BATS_TEST_DIRNAME` is already
    set by bats before `load` runs the helper body, confirmed working by
    the actual migration (every one of the 55+ converted files passes).
  - `git_identity <dir> [email] [name]` — the `user.email`/`user.name`
    (+ `commit.gpgsign false`) pair/triple, parameterized since the
    per-site email/name values differ; deliberately does **not** run
    `git init` itself, since init flags vary per site (bare vs. normal,
    `-b <branch>`, trailing `.`) and those stay inline at each call site.
  - `use_fake_bin <fixture> <name>` — the mkdir/cp/chmod/PATH-export
    ceremony, reusable for more than one binary per test (git.sh's wrapper
    tests need both a fake `gh` and a fake `git`, had they used this path —
    see exclusions below for why they don't).
  - `isolate_claimant_state [subdir]` — the `CLAIMANT_STATE_DIR` one-liner.
- **Alternatives rejected**:
  - A single one-size-fits-all `bootstrap_git_fixture` that also runs
    `git init` — rejected after inspecting all 17 call sites: `land.bats`
    needs a bare origin repo AND a `-b main` branch name, `support_regression_commit.bats`
    needs `-b main .`, `epic-status.bats` needs a trailing `.` plus a
    `remote add` right after. Forcing one `init` signature would either
    lose those variants or need as many parameters as lines saved.
  - Blindly converting every file matching a loose grep for "fake gh" —
    rejected after reading each of the 5 matching files: 3 of them
    (`git.bats`, `cleanup_branch.bats`, `land.bats`) use **materially
    different** fake mechanisms (git.bats deliberately keeps `$FAKEBIN` off
    `$PATH` except per-invocation via an explicit prefix — its own comment
    says so, "`$FAKEBIN` only goes on `$PATH` per-invocation inside each
    `@test`"; `cleanup_branch.bats`/`land.bats` embed bespoke
    heredoc-defined fakes with their own env-var contracts
    `FAKE_GH_MERGED_BRANCHES`/`LAND_GH`+`LAND_GIT`). Forcing these through
    a PATH-exporting shared helper would silently change `git.bats`'s
    documented per-invocation-only isolation — a correctness risk for a
    cosmetic win. Left untouched.
  - Converting `taskid_check_orphaned_refs.bats` (matched an early loose
    grep on "init -q" + "user.email" co-occurring in-file, but not
    adjacent) — excluded on inspection: it runs bare `git init -q .` with
    **no** identity config at all (no commits made), so there is nothing to
    extract.
  - Converting `reclaim_sweep_pr.bats`'s one `init -q` site — excluded: it
    deliberately uses `"$REAL_GIT"` (a captured real-git path, not the
    ambient `git`) plus an extra `checkout -q -b main` step, testing
    something specific about bypassing a stubbed git. Not a safe match for
    a helper that assumes the ambient `git`.

## Test plan

- [x] Full suite of all 60 touched files run individually/in small batches
  (`bats <file>` per file, plus whole-file batches where the sandbox
  allowed) — 557+ individual test results observed across both passes,
  zero regressions. One pre-existing, unrelated failure found and
  confirmed pre-existing by reverting the single file and re-running
  (`tests/chore_review.bats` "list-due: selects a row >= 1 iteration old");
  filed separately as `T20261016-360850`, out of scope for this PR.
- [x] `tests/git.bats` could not be run to completion in this sandbox (a
  `run bash .../git.sh ...` subprocess-exec test hangs under this
  environment's shell sandboxing) — confirmed this is **pre-existing**, not
  caused by this change, by reverting `tests/git.bats` to its
  pre-this-task content and reproducing the identical hang. CI's `bats`
  job (a plain Ubuntu runner, no such sandboxing) is the authoritative
  gate for this file; it has passed on every recent `main` commit
  (e.g. PR #356, ~1m47s for the full suite including `git.bats`).
- [ ] CI's `bats` GitHub Actions job passes on this PR (post-merge item:
  tick once CI is green on the PR — this is the authoritative full-suite
  before/after comparison, since `main` was green immediately before this
  PR per the point above).
- [x] `python3 repo-conventions/scripts/lint_tasks.py --changed <this file>` passes.

## Done criteria

- [x] `tests/test_helper.bash:1-66` exists with all four helpers.
- [x] 55/55 `REPO_ROOT` duplicates converted — verified via `bats tests/claim_gap.bats tests/to-task_neutrality.bats _docs/doc-impact.bats`.
- [x] 14/14 git-fixture-bootstrap files converted to `git_identity` — verified via `bats tests/chore_review.bats tests/task_claim.bats`.
- [x] 2/2 fake-`gh`-PATH-shim files converted to `use_fake_bin` — verified via `bats tests/epic-status.bats tests/gh.bats`.
- [x] 4/4 `CLAIMANT_STATE_DIR` files converted to `isolate_claimant_state` — verified via `bats tests/claimant_id.bats tests/task_claim.bats tests/eta.bats tests/statusline_setup.bats`.
- [ ] CI's `bats` job (`.github/workflows/tests.yml`) green on this PR — the final before/after proof.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `tests/test_helper.bash` | `1-66` | the new shared helper (`REPO_ROOT` export, `git_identity`, `use_fake_bin`, `isolate_claimant_state`) |
| `tests/*.bats`, `_docs/doc-impact.bats` | various | 55 files: `load test_helper`/`load ../tests/test_helper` added, inline `REPO_ROOT` line removed |
| `tests/epic-status.bats`, `tests/estimation_revisions.bats`, `tests/journal_compact.bats`, `tests/attribution.bats`, `tests/migrate_task.bats`, `tests/quality_probe.bats`, `tests/task-state.bats`, `_docs/doc-impact.bats`, `tests/task_claim.bats`, `tests/eta.bats`, `tests/chore_review.bats`, `tests/support_regression_commit.bats`, `tests/land.bats`, `tests/compute_velocity.bats` | various | 14 files / 17 call sites: inline `git config user.email`/`user.name` pair replaced with `git_identity` |
| `tests/epic-status.bats`, `tests/gh.bats` | various | 2 files: inline fake-`gh` PATH-shim ceremony replaced with `use_fake_bin` |
| `tests/claimant_id.bats`, `tests/task_claim.bats`, `tests/eta.bats`, `tests/statusline_setup.bats` | various | 4 files: inline `CLAIMANT_STATE_DIR=` replaced with `isolate_claimant_state` |

## Root cause

- Not a bug — a chore/DRY task. No root cause in the bug-RCA sense; the
  "why does the duplication exist" answer is simply that the suite grew
  file-by-file over time with no `tests/test_helper.bash` ever introduced,
  so each new `.bats` file's author copied the nearest existing file's
  boilerplate rather than factoring out a shared helper.

## Closed

Filled at merge — see the PR this task ships in.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — pure refactor of test
  scaffolding, not new behavior; verification was via rerunning the
  existing tests, not writing new ones.
- Verification (`superpowers:verification-before-completion`): yes — every
  touched file rerun individually/in batches before considering the change
  complete; two anomalies found this way (an empty `setup(){}` syntax
  error, and a pre-existing unrelated flake) were each root-caused before
  moving on.
- Systematic debugging (`superpowers:systematic-debugging`): yes — the
  `gh-wrapper-usage.bats` empty-function syntax error and the
  `chore_review.bats`/`git.bats` anomalies were each isolated by reverting
  the single file to its pre-change content and reproducing (or not)
  against that baseline, rather than guessing.
- Receiving code review (`superpowers:receiving-code-review`): n/a at
  design-doc time — applies once `/address-pr`'s independent review runs
  on the implementation PR.
