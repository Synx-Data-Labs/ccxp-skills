---
status: In Progress
estimation: 1
source: CI wall-clock analysis, this conversation, 2026-10-16
claimed_by: cc1-50ac6891:5e1f014a92f728aa
claimed_role: interactive
scheduled: 2026-10-12
---

# T20261016-393753: parallelize bats test suite with --jobs to cut CI wall-clock

- Design approved in-conversation 2026-10-16: filed with the design
  (problem, fix, test plan) already spelled out and explicitly authorized
  by the maintainer as a trial to drive end-to-end.
- Design PR skipped per `/drive` Phase 2's "design already in file AND
  maintainer has explicitly approved it in conversation" carve-out.
- Expanded to the full design-doc template below to clear the Phase 2
  step 7 design-score gate, which still applies even when the design PR
  itself is skipped.

## TLDR

- **Type**: chore
- **Problem**: the `bats` CI job runs 1074 tests serially in
  `.github/workflows/tests.yml:109`, taking ~89s wall-clock, dominated by
  per-test fork overhead (~83ms/test) rather than test logic.
- **Solution**: add `bats --jobs N` to parallelize that job, trialed live
  on a branch (not just reasoned about statically) to confirm it's safe
  and actually faster before merging, **with a memory/parallelism cap**
  (default job count derived from CPU and RAM, env override, optional
  watchdog) so a local run cannot freeze the dev box (see Feedback).

## Feedback (2026-10-19)

- **Observed** (reported by the maintainer; not re-measured here): running
  the suite in parallel locally exhausted all memory on the macOS dev
  machine and froze it. Each bats job forks a subshell per `@test`, so
  N jobs multiply the resident footprint; unbounded `--jobs` (or `--jobs
  $(nproc)`-style defaults) is unsafe on a laptop that also runs an IDE,
  Claude sessions, etc.
- **New requirement**: the parallel path must have a way to limit
  parallelism and memory so it cannot freeze the dev box. Safe-by-default
  locally; CI may be more aggressive.

## Problem

- The `bats` job (`.github/workflows/tests.yml:101-109`) runs
  `bats tests/*.bats _docs/*.bats _slack/*.bats` serially.
- 1074 `@test` blocks counted directly (`grep -rh '^@test' tests/*.bats
  _docs/*.bats _slack/*.bats | wc -l`), matching the ~1075 figure from the
  originating CI wall-clock analysis.
- That analysis attributes the ~89s run time almost entirely to per-test
  fork overhead (~83ms/test), not test logic — i.e. this job is
  fork-overhead-bound, not compute-bound, which is exactly the profile
  `bats --jobs N` (GNU-parallel-backed) is built to fix.
- This costs ~89s of CI wall-clock on every push/PR touching the paths
  listed in `tests.yml`'s `on:` filters (`dev/TODO/**`, `**/SKILL.md`,
  `tests/**`, etc.) — a frequent trigger set, so the serial cost is paid
  often, not just occasionally.
- **Memory-safety gap (feedback 2026-10-19)**: plain `--jobs N` has no
  memory bound. Verified by the maintainer's report: a local parallel run
  froze macOS. Unverified: which tests/process trees dominate memory (a
  few heavy tests vs. N x baseline) — measure before choosing the
  per-job budget.

## Context

- Verified: `nproc` on this environment reports 8 cores; GitHub-hosted
  `ubuntu-latest` runners are documented as 4-core by default, so `N=4` is
  the safe, conservative pick (matches reported run time without
  eagerly offering more concurrency than runner's baseline).
- Verified (git archaeology): the `bats` job has been serial (no
  `--jobs`) since it was introduced in `5afe835` ("Initial public
  release", 2026-09-28) — plain default usage, not a deliberate decision
  against parallelism; nothing in history explains why it was never
  parallelized, so this reads as an oversight / unexplored option, not an
  intentional constraint.
- Assumed, flagged by the originating analysis as unconfirmed by a real
  run: BATS tests in this repo already appear to neutralize `$HOME`
  per-test (a spot-check finding, not exhaustively verified) — encouraging
  for parallel-safety, but cross-test fixture collisions **outside**
  `$BATS_TEST_TMPDIR` (shared files/dirs, shared global env vars, port
  binding) could still exist and would only surface under real parallel
  execution, not static review.

## Solution

- Add `--jobs N` to the bats invocation in `.github/workflows/tests.yml`'s
  `bats` job (`tests.yml:109`): `bats --jobs 4 tests/*.bats _docs/*.bats
  _slack/*.bats`. `N=4` matches the standard GitHub-hosted runner's core
  count — see Context.
- Bundled, low-risk secondary fix: cache/pin the bats install step
  (`tests.yml:105-106`, currently a fresh `apt-get install` every run) via
  `actions/cache` keyed on the bats version, to also save the estimated
  ~15-19s/run noted by the originating analysis. Bundled here rather than
  filed separately since it's a one-line addition to the same job in the
  same file.
- **Alternatives considered and rejected**:
  - *Split tests across a GitHub Actions matrix (multiple jobs) instead of
    `--jobs`*: rejected — more invasive (new job definitions, artifact/log
    fan-out to reconcile) for the same fork-overhead-bound problem that
    `--jobs` solves with a one-line change; no evidence the extra
    complexity buys anything `--jobs` doesn't already give here.
  - *Reduce test count / merge redundant tests*: rejected — this is a
    coverage change in disguise (the slow part isn't excess tests, it's
    per-test fork overhead on tests that are each individually fast),
    and the user explicitly ruled out any test-content change for this
    task.
  - *Do nothing (89s is "fine")*: rejected — it's paid on every push/PR
    matching the workflow's trigger paths, a frequent set, and the fix is
    a one-line, reversible trial.

- **Memory-cap options evaluated** (design-level; feasibility on macOS
  is from general knowledge, not tested here — verify in the trial):
  - *Bound job count by RAM* (**primary**): `jobs = min(cpus,
    floor(avail_ram / per_job_budget), hard_cap)`. RAM via `sysctl -n
    hw.memsize` (macOS) / `/proc/meminfo` (Linux); CPUs via `sysctl -n
    hw.ncpu` / `nproc`. Per-job budget (assumed ~512 MB-1 GB) to be
    measured. Portable, no privileges.
  - *Env override*: `BATS_JOBS=<n>` (explicit wins, still clamped by the
    hard cap unless `BATS_JOBS_FORCE=1`).
  - *Wrapper script* (e.g. `scripts/run-bats.sh`) that computes the above,
    execs `bats --jobs`, and is what `make test`/docs/CI call, so the
    default lives in one place.
  - *Per-process limit*: macOS has no cgroups and `ulimit -v` is
    unreliable/ignored there (assumed; confirm), so do **not** rely on it.
    Use `ulimit -v` only on Linux CI if useful (optional).
  - *Watchdog*: background loop in the wrapper polling free memory
    (`vm_stat` / `memory_pressure` on macOS, `/proc/meminfo` on Linux);
    below a floor (e.g. <10% free) kill the bats process group and fail
    with a clear message. Last-line defence, not primary.
  - *Local vs CI defaults*: local = RAM-bounded and low (e.g. max 2-4,
    default `min(cpus/2, RAM-derived)`); CI (`CI=true`) = `--jobs 4`
    matching the 4-core runner (7 GB RAM, assumed from GitHub docs).

## Test plan

This is a TRIAL/experiment, not a guaranteed-safe mechanical change — done
criteria are evidence-based, not just "the diff looks right":

- [ ] Run the modified workflow for real on a branch (push or
      `workflow_dispatch`), not just a dry run or static review.
- [ ] Confirm ALL 1074 tests still pass, with no flaky or order-dependent
      failures introduced by parallel execution.
- [ ] Confirm wall-clock time actually drops versus the ~89s serial
      baseline (measure the branch run's `bats` job duration).
- [ ] If fixture collisions or flakiness surface: either fix the specific
      collision (e.g. isolate a shared fixture path) or revert the
      `--jobs` change and document in the task/journal why
      parallelization isn't safe yet — do not force it through.
- [ ] Memory cap (feedback 2026-10-19): on a macOS machine, run the
      suite via the wrapper with defaults and record peak memory (e.g.
      `/usr/bin/time -l`, Activity Monitor/`memory_pressure`); the box
      stays responsive and no swap storm occurs.
- [ ] Unit-test the job-count computation (bats test with mocked
      RAM/CPU inputs: low RAM clamps jobs, `BATS_JOBS` override,
      `CI=true` default, floor of 1).
- [ ] Watchdog: simulate low-memory (stubbed free-memory probe) and
      confirm it kills the run and exits non-zero with a message.
- [ ] `/drive` Phase 3 step 7 "Workflow verification": trigger the
      modified workflow on the feature branch and observe a full green
      run before opening the PR (required because this touches
      `.github/workflows/tests.yml`).

## Done criteria

- [ ] `.github/workflows/tests.yml`'s `bats` job invokes `bats --jobs 4
      ...` — `file:line` after the change: `.github/workflows/tests.yml`
      (bats step).
- [ ] A live CI run of the modified workflow on the feature branch shows
      all 1074 tests passing — the triggered run's own log/summary is the
      evidence (linked in the PR and in `## Closed` below).
- [ ] The same run's `bats` job duration is measurably lower than the
      ~89s serial baseline — the run's own duration field is the
      evidence.
- [ ] A single entry point (wrapper or Makefile target) computes a
      conservative default job count from CPU and RAM, honours a
      `BATS_JOBS` env override, and uses a distinct CI default; the
      default never exceeds a hard cap. Documented in the README/guidelines
      test section.
- [ ] A watchdog (or documented decision to omit it, with reason) guards
      against memory exhaustion on macOS; peak memory of a default local
      run is recorded in `## Closed`.
- [ ] No test marked flaky/order-dependent across the trial run(s) — if
      any surfaces, either a fix is committed (and re-verified green) or
      the change is reverted with the reason documented here before
      close.

## Root cause

- Not a bug — this is a chore/perf task, so "root cause" here is "why
  this was never parallelized": the `bats` job has run with plain
  `bats <globs>` since it was introduced in `5afe835` ("Initial public
  release", 2026-09-28) — a default/unexplored option, not a deliberate
  decision against `--jobs`. Nothing in the commit history or this
  repo's docs documents a reason parallel execution was avoided.
- Mechanism: per-test fork overhead (bats forks a subshell per `@test`)
  dominates at ~83ms/test × 1074 tests ≈ 89s — exactly the profile
  `--jobs N` (GNU parallel under the hood) addresses by running N test
  processes concurrently instead of one at a time.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `.github/workflows/tests.yml` | `101-109` | The `bats` job: installs bats (apt-get, fresh every run) then runs the full suite serially — both the `--jobs` change and the bundled install-caching change land here |
| `tests/*.bats`, `_docs/*.bats`, `_slack/*.bats` | n/a | The 1074 test cases being parallelized; no test-content changes intended |

## Closed

Filled in once the implementation PR merges — see Phase 7 (PR number, live
trial run link, wall-clock before/after, and whether the secondary
bats-install-caching fix landed in the same PR or as its own follow-up).

## Skills invoked

Filled in once the implementation PR merges (Phase 7.0 audit block).
