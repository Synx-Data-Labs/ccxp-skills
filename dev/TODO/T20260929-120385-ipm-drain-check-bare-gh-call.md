---
status: Open
scheduled: 2026-10-12
estimation: 1
source: T20260925-219021 implementation, 2026-09-29 — surfaced during that
  task's own bare-`gh`-call sweep, deliberately left out of scope there
related: T20260925-219021
---

# T20260929-120385: `_ipm/ipm-iteration-drain-check.sh:224` makes a bare, unwrapped `gh` call

## Problem

- **Type**: bug
- `_ipm/ipm-iteration-drain-check.sh:224` reads:

  ```bash
  board="$(gh project item-list "$project" --owner "$owner" --format json --limit 1000)"
  ```

  — a bare `gh` invocation, not routed through `_gh/gh.sh`. On a
  multi-account machine, this silently authenticates as whichever account
  is globally active, same failure mode T20260925-219021 retired
  `_gh/auto-switch.sh` over (except that script no longer papers over it
  either — `_gh/auto-switch.sh` is now gone).
- Discovered while sweeping the repo for caller-side `GH_TOKEN=`/bare-`gh`
  sites during T20260925-219021's implementation; deliberately left
  out of that task's scope (it wasn't in the original Problem section,
  and fixing it isn't part of retiring `auto-switch.sh`) but tracked here
  per that task's own Alternatives-rejected entry.
- Done looks like: this call routes through `_gh/gh.sh` (e.g.
  `bash ../_gh/gh.sh project item-list ...`, resolving the wrapper's path
  the same way this script already resolves its other sibling scripts) —
  or, if `gh project item-list`'s output shape needs the raw `gh` binary
  for some reason not obvious from the current code, that constraint is
  documented inline the way `ccxp/scripts/epic-status.sh`'s header
  documents its own cross-repo exception.

## Context

- `_ipm/ipm-iteration-drain-check.sh` already resolves `--home-repo`/
  `--owner` from the local clone's git remote when not passed explicitly
  (`_ipm_drain_repo_slug`), so it has everything `_gh/gh.sh` needs to pick
  the right account — this isn't a cross-repo-scoping case like
  `epic-status.sh`'s documented exception.
