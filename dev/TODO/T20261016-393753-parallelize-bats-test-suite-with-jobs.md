---
status: Open
estimation: 1
source: CI wall-clock analysis, this conversation, 2026-10-16
---

# T20261016-393753: parallelize bats test suite with --jobs to cut CI wall-clock

## Problem

- **Type**: chore
- The `bats` job in `.github/workflows/tests.yml` runs `bats tests/*.bats
  _docs/*.bats _slack/*.bats` serially — 1075 tests, ~89s wall-clock.
- Analysis attributes the ~89s almost entirely to per-test fork overhead
  (~83ms/test), not test logic — this job is fork-overhead-bound, not
  compute-bound.
- `bats --jobs N` (backed by GNU parallel, typically preinstalled on
  GitHub-hosted ubuntu runners) could cut wall-clock roughly linearly with
  N, with zero test-content changes and zero coverage risk — **provided**
  there are no cross-test fixture collisions outside `$BATS_TEST_TMPDIR`.
- A spot-check suggested tests already neutralize `$HOME` per-test
  (encouraging), but this is NOT yet confirmed by an actual CI run — only
  by static review. Parallel execution can expose hidden shared-state
  collisions (shared fixture paths outside `$BATS_TEST_TMPDIR`, shared
  global env vars, port binding, etc.) that serial execution never
  triggers.
- Secondary, low-risk, bundle-if-convenient: the `bats` job does
  `sudo apt-get update && sudo apt-get install -y bats` fresh every run;
  caching or pinning the bats install instead is estimated to save
  ~15-19s per run with very low risk.

## Fix

- Add `--jobs N` to the bats invocation in the `bats` job of
  `.github/workflows/tests.yml` (currently:
  `bats tests/*.bats _docs/*.bats _slack/*.bats`). Pick a reasonable N
  (e.g. 4, or derive from `nproc` on the runner).
- If convenient, also cache/pin the bats install step instead of
  apt-get installing fresh each run; otherwise file as a tiny separate
  follow-up.

## Test plan

This is a TRIAL/experiment, not a guaranteed-safe mechanical change — done
criteria are evidence-based, not just "the diff looks right":

- Run the modified workflow for real on a branch (push or
  `workflow_dispatch`), not just a dry run or static review.
- Confirm ALL 1075 tests still pass, with no flaky or order-dependent
  failures introduced by parallel execution.
- Confirm wall-clock time actually drops versus the ~89s serial baseline.
- If fixture collisions or flakiness surface: either fix the specific
  collision (e.g. isolate a shared fixture path) or revert the `--jobs`
  change and document in the task/journal why parallelization isn't safe
  yet — do not force it through.
- Because this changes `.github/workflows/tests.yml`, it requires the
  `/drive` Phase 3 "Workflow verification" step: trigger the modified
  workflow on the feature branch and observe a full green run before
  opening the PR.
