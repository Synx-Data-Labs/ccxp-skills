---
status: Open
estimation: 1
source: this conversation, 2026-10-16
---

# T20261016-316464: Extract a shared tests/test_helper.bash for the BATS suite

## Problem

- **Type**: chore
- A recent analysis of this repo's BATS test suite (1075 tests across 72
  files) found no shared `test_helper.bash` exists anywhere — zero `load`
  statements across all 72 files.
- Concrete duplication found:
  - 55/72 files repeat an identical
    `REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"` line.
  - 17 files duplicate a full git-fixture-repo bootstrap (`git init -q` +
    user config).
  - 4 files duplicate a fake-`gh`-binary PATH shim.
  - 4 files duplicate `CLAIMANT_STATE_DIR`/state-dir isolation setup.
- Fix: extract `tests/test_helper.bash` containing the common REPO_ROOT
  resolution, git-fixture bootstrap, fake-gh shim, and state-dir isolation
  patterns; update each affected file to `load test_helper` at the top and
  remove its duplicated inline version.
- This is pure DRY refactor — zero assertion changes, zero coverage
  changes intended.
- Test plan: full `bats tests/` suite must pass with identical pass/fail
  results before and after the refactor. Done-criterion: zero change in
  test outcomes (same tests pass, same tests fail, same counts).
- Note for whoever drives this: touches ~55-72 files mechanically (the
  categories above overlap — e.g. a file needing the git-fixture bootstrap
  also needs the REPO_ROOT line — so the union across 72 total files, not
  their 55+17+4+4 sum, bounds the actual count). This is expected
  full-suite scope by design, not scope creep — the whole point is
  touching many files identically with the same one-line change.
  Declare this explicitly in the design PR so the `/drive` skill's own
  ">8 files beyond design scope" escalation trigger doesn't misfire on an
  intentional, declared mechanical refactor.
