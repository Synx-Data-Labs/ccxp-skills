---
status: In Progress
estimation: 1
source: owner request in this conversation, 2026-11-08
claimed_by: cc1-9f320372:3be9260d500b0fcc
claimed_role: interactive
scheduled: 2026-11-02
---

# T20261108-315759: Plugin scripts must detect the active profile dir instead of assuming ~/.claude

## Problem

- **Type**: bug
- Plugin 6.2.0 scripts assume `~/.claude`, recreating it on machines whose profile is elsewhere (for example `CLAUDE_CONFIG_DIR=~/.claude-work`)
  - `_session/claimant-id.sh:30` defaults `CLAIMANT_STATE_DIR` to `${HOME}/.claude/state`
  - `hud/scripts/hud-lib.sh:26` and `hud/scripts/last-input-hook.sh:27` default `LAST_INPUT_STATE_DIR` to `${HOME}/.claude/state/last-input`
  - About 26 shell scripts mention `~/.claude` or `$HOME/.claude`; some already fall back via `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`
- Owner: the plugin must detect the actual folder of the running session and use that profile folder
- Done looks like
  - One shared helper resolves the profile dir: `CLAUDE_CONFIG_DIR` if set and a directory; else derived from the script's own path under `<profile>/plugins/cache/...`; else `~/.claude`
  - Every script needing the folder uses it; audit fixes real assumptions, leaves docs-only mentions
  - A BATS test with `CLAUDE_CONFIG_DIR` and `HOME` both temp dirs asserts no `~/.claude` is created
  - A lint fails on a bare `$HOME/.claude` or `~/.claude` outside the helper
  - Behavior is unchanged when `CLAUDE_CONFIG_DIR` is unset
- Out of scope: any release, tag or version bump (the owner decides the next plugin version)
