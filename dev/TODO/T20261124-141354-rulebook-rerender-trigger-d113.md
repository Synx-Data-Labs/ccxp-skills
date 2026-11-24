---
status: Open
estimation: 1
source: owner request 2026-11-24 (job 1524), epic E4
related: [T20261121-412600]
description: Automatic rulebook re-render trigger when a decision is added, superseded or retired; prints or dispatches the render command, batched
type: feature
---

# T20261124-141354: Rulebook re-render trigger on decision changes (d113)

## Problem

- **Type**: feature
- Implements decision d113 (2026-11-12): whenever a decision is added, superseded or retired, dispatch a job that re-renders `dev/RULEBOOK.md` in the synxdb-team repo (`scripts/render-rulebook.sh`) and lands it by PR; batch a burst of changes into one export.
- Today nothing triggers it; the re-render happens only when someone remembers.
- Wanted: a post-step in `ledger.sh decision add|supersede|retire` that writes a pending marker (batching a burst), plus a command that prints (or the dispatcher runs) the render job prompt once the burst settles; clear the marker when the render PR is opened.
- Bats tests: marker written on each change type, one pending marker for a burst, cleared after the render step, no marker on `decision list`.
- Retire when shipped: nothing; d113 stays as the rule (owner decides).

## Done criteria

- Trigger and bats tests merged; `hud/scripts/ledger.md` documents the marker and the render command.
