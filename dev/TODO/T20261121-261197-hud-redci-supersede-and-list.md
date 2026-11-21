---
status: Review
estimation: 2
scheduled: 2026-11-16
source: owner message 2026-11-21 (job 1355)
description: HUD red-CI cell counts superseded failures; add a list subcommand to see the unhandled runs
type: bug
---

# T20261121-261197: HUD red-CI counts superseded failures; add `hud-redci.sh list`

## Problem

- **Type**: bug
- Owner (Shine, 2026-11-21): "if the CI is passing, why the hud shows red? what are the 7 unhandled CI?"
- Root cause: `hud/scripts/hud-redci.sh` looked up successes with one repo-wide `gh run list --status success --limit 50`; on a busy repo an older workflow's later success falls outside that window, so its failures stay counted (SynxDB2 Install Test, 2 failures with later successes on main).
- The cell shows only a count and at most 3 names; nothing shows event, run id or URL.
- Done: superseded failures are dropped per (workflow, branch); `hud-redci.sh list` prints id, workflow, event, branch, age, URL for every unhandled run.
- Decision kept (d137): manual `workflow_dispatch` failures on the default branch count ("red is red"); documented in `hud/README.md`.

## Solution

- One `gh run list --workflow <id> --branch <b> --status success --limit 1` per distinct failing pair (max 20), replacing the repo-wide window.
- Items carry `id`, `ev`, `br`, `url`; new `list` CLI subcommand; bats tests with the real data shape (success outside the newest-50 window).
