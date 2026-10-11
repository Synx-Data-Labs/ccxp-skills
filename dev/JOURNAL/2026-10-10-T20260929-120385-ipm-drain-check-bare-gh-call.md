---
status: Done
scheduled: 2026-10-12
estimation: 1
source: T20260925-219021 implementation, 2026-09-29 — surfaced during that
  task's own bare-`gh`-call sweep, deliberately left out of scope there
related: T20260925-219021
claimed_by:
claimed_role:
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

## Closed (2026-10-10) — superseded, not fixed as filed

- Closed as moot in the same PR that implements T20261005-554581 (drain
  gate reads a retired Project board): the maintainer's decision there was
  to make the gate **file-only** — read `dev/TODO/*.md` frontmatter
  directly, no `gh` call of any kind. The bare `gh project item-list` line
  this task asked to route through `_gh/gh.sh` no longer exists in
  `_ipm/ipm-iteration-drain-check.sh` at all, so "route it through the
  wrapper" has nothing left to apply to.
- No code change specific to this task; see T20261005-554581's Closed
  section for the actual rewrite and its test coverage
  (`tests/ipm_iteration_drain_check.bats`, including a case that confirms
  no `--home-repo`/`--owner`/`--project`/`GH_TOKEN` trace remains).

## Skills invoked

- Verification (`superpowers:verification-before-completion`): yes —
  confirmed via `grep` that no `gh project`/`GH_TOKEN` call remains in the
  rewritten script before closing this as superseded
