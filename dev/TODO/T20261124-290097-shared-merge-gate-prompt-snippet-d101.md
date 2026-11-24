---
status: Open
estimation: 1
source: owner request 2026-11-24 (job 1524), epic E4
related: [T20261121-412600]
description: Script that prints the standard merge-gate and authorization paragraph so job prompts and autopilot cycle prompts stop re-typing it
type: chore
---

# T20261124-290097: Shared job-prompt snippet for the merge gates (d101)

## Problem

- **Type**: chore
- Implements decision d101 (2026-11-12): commit-producing work goes through /new-task then /drive; claim PR, implementation PR, a fresh independent review on every PR, `/address-pr`, wait for all required checks, `gh pr merge --rebase`; never `--admin`, never `--auto`; the task-close is a separate PR.
- Today each job prompt and each autopilot cycle prompt re-types this paragraph by hand, so wording drifts and the persona grows.
- Wanted: a script (for example `agent-pairing/scripts/job-gates.sh`) that prints the standard gate paragraph (with options for repo and task id) so the dispatcher and autopilot paste its output; one place to edit.
- Switch `autopilot` cycle prompt building and the persona's "Writing a job prompt" to call it; bats test that the output names every gate (fresh review, all checks, rebase merge, no admin or auto, separate close PR).
- Retire when shipped: nothing; d101 stays as the source text the script quotes (owner decides).

## Done criteria

- Script and bats test merged; autopilot and persona use it instead of a typed paragraph.
