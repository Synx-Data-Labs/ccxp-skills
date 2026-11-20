---
status: Open
estimation: 1
source: Job 1342 (n362): five PRs in a row needed bats reruns on 2026-11-20
description: Two lock tests fail intermittently on the CI runner (ledger decision adds, autopilot state lock)
type: bug
---

# T20261120-160823: Flaky lock bats tests on CI (ledger concurrent adds, autopilot state lock)

## Problem

- **Type**: bug
- `tests/ledger.bats` "decision: concurrent adds are serialized ..." (8 parallel `ledger.sh decision add`) and the autopilot "state lock: a stale lock directory is broken; two writers both land" test fail intermittently on the GitHub runner and pass on macOS (looped 3 of 3 locally, also under CPU load).
- Evidence: PR runs 44777791430, and the `tests` runs of #671, #673, #674, #676, #677, #681 each failed one of the two at least once and passed on rerun; main's own run for the same content passed once.
- Suspected cause: the mkdir lock in `hud/scripts/ledger.sh` `ledger-with-lock` waits at most ~10 s (100 x 0.1 s) while each critical section runs several jq processes, so on a slow runner the 8th writer times out and its entry is lost; unverified.
- Done looks like: root cause found, the test or lock wait fixed so the suite no longer needs reruns, and the CI log of a failing run kept as evidence.
