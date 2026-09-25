---
status: Open
estimation: 4h
source: lsc-pa conversation, 2026-09-25
---

# T20260925-219021: Retire auto-switch.sh and caller-side GH_TOKEN; route all gh through _gh/gh.sh

## Problem

- **Type**: chore
- `hooks/hooks.json` wires `_gh/auto-switch.sh` as a plugin-level
  SessionStart hook, so every session in every repo runs a global
  `gh auth switch`
  - Concurrent sessions on different accounts (75033us vs xinzweb) keep
    flipping each other's active account
  - Consumers have fallen back to hardcoding
    `GH_TOKEN=$(gh auth token --user <name>)` per command
- `_gh/gh.sh` already solves this with no global state: it picks the account
  that can read `origin` and runs `gh` with a process-scoped `GH_TOKEN`
  - It should be the only sanctioned way to call `gh`; `auto-switch.sh`
    becomes redundant
- Caller-side `GH_TOKEN` / bare `gh` sites that bypass the wrapper:
  - `ccxp/scripts/epic-status.sh:144,217,261,276,337`: `GH_TOKEN="$tok" gh ...`
  - `_session/_lib.sh:74-91`: token fallback chain ending in `GH_TOKEN`,
    with a raw-`gh` branch
  - README.md:59 and README.md:275-282 plus `gcpr/SKILL.md:182` document
    the old pattern
- Done looks like:
  - `auto-switch.sh`, its hook entry, `tests/auto-switch.bats`, and its
    README section are deleted
  - All `gh` calls in skills/scripts go through `_gh/gh.sh` (git through
    `_gh/git.sh`)
  - Only `gh.sh`/`git.sh` set `GH_TOKEN` internally; CI-only paths
    (`actions/sync-tasks/`, keyring-less) are an explicit allowlisted
    exception
  - A lint or bats check fails on a new bare `gh` call or a caller-side
    `GH_TOKEN=` in skill/script sources
