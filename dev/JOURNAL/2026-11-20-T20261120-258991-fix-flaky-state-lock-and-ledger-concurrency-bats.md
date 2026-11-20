---
status: Done
estimation: 1
source: owner direction via Cui, 2026-11-20 (flaky tests blocking PRs)
description: stale-lock-break race in _ap_lock and ledger-with-lock makes two bats concurrency tests flaky
claimed_by:
claimed_role:
---

# T20261120-258991: Fix flaky bats "state lock: stale lock" and "decision: concurrent adds are serialized" (stale-lock-break race)

## Problem

- **Type**: bug
- Failing tests:
  - `tests/autopilot_state.bats`: "state lock: a stale lock directory is broken; two writers both land"
  - `tests/ledger.bats`: "decision: concurrent adds are serialized (no lost entries, no duplicate refs); the lock is released"
- Evidence: tests workflow failed 11 of the last 40 runs; runs 44783662871, 44783123513, 44779747248, 44779089504, 44778963101 (and 44587210041 earlier) fail on one or both; identical code passes on rerun
- Impact: forced reruns on PRs 674, 676, 677, 681, 682; delays PR 5133
- Suspected root cause: the stale-lock break is not atomic in `_ap_lock` (`autopilot/scripts/autopilot-state.sh`) and `ledger-with-lock` (`hud/scripts/ledger.sh`)
  - a waiter that saw the lock as stale can `rmdir` a lock a peer has just re-taken, so two writers hold it and an update is lost
- Required: fix the product lock, make both tests deterministic (handshakes, no sleeps), keep every assertion, prove 200 runs each plus under CPU stress with zero failures

## Closed (2026-11-20)

- Root cause: ubuntu-latest now ships uutils coreutils; its `mkdir` is not exclusive (18 of 300 trials with 8 concurrent callers had more than one winner), so the `mkdir` locks in `autopilot/scripts/autopilot-state.sh` and `hud/scripts/ledger.sh` did not exclude and both concurrency tests lost an update (about 40% of runs)
- Fix: PR #685, shared `_session/lock.sh` (noclobber lock file, atomic stale break); four regression tests (stale lock re-taken by a live writer; mutual exclusion independent of `mkdir`) fail on the old locks
- Stability: 200 runs of each test on macOS under 20 CPU spinners and on the uutils runner unloaded, zero failures; the tests workflow on main is green
- Follow-up: the other `mkdir` locks (`hud/scripts/hud-*.sh`, `1password-env-setup/scripts/refresh-env.sh`) have the same weakness
