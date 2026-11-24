---
status: Open
estimation: 1
source: owner request 2026-11-24 (job 1524), epic E4
related: [T20261121-412600]
description: Move the persona's CI-failure response flow into a skill and script with a dedupe step; the persona keeps a one-line pointer
type: chore
---

# T20261124-395783: CI-failure response into a skill and script (d148)

## Problem

- **Type**: chore
- Implements decision d148 (2026-11-23): on a nightly, release or default-branch failure (not PR branches) start an investigation job at once (new task, topped, driven); per-turn job cap configurable (6); never re-dispatch a run id; no publish, promote, tag or release; NEEDS INPUT for expired credentials; alert threads in #slack-automation-alerts get the RCA as one reply with no secrets or customer names.
- Today the flow lives in the persona's "CI failure response" section (about 2.4 KB); the pieces `ci-triage.sh`, `/nightly-check` and `/labrun-rca` exist but the dedupe, cap and "never re-dispatch a run id" rules are prose.
- Wanted: extend `/nightly-check` or add a small skill with a script that lists new failed runs, skips run ids already handled (a marker file), applies the cap, and prints the job prompt to dispatch; the persona section shrinks to a one-line pointer.
- Bats tests for dedupe, cap, PR-branch exclusion and the credentials stop.
- Retire when shipped: d148 text moves to the skill; the owner or dispatcher retires the decision later.

## Done criteria

- Persona CI-failure section is a pointer; script and bats tests merged; behaviour identical (key rules still appear in skill or script).
