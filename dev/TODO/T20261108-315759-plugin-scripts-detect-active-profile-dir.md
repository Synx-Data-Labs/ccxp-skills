---
status: Design
estimation: 1
source: owner request in this conversation, 2026-11-08
related: T20260911-698434
claimed_by: cc1-9f320372:3be9260d500b0fcc
claimed_role: interactive
scheduled: 2026-11-02
---

# T20261108-315759: Plugin scripts must detect the active profile dir instead of assuming ~/.claude

## TLDR

- **Type**: bug
- **Problem**: scripts default state and env paths to `$HOME/.claude`, recreating it on machines whose profile is elsewhere
- **Solution**: one side-effect-free helper `_session/profile-dir.sh` resolves the active profile dir; every script that needs the folder sources it; a lint keeps bare `~/.claude` out of code

## Problem

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

## Context

- A profile is the dir Claude Code runs with: `CLAUDE_CONFIG_DIR` when set (here `~/.claude-work`), else `~/.claude`
- The plugin is installed under `<profile>/plugins/cache/ccxp-skills/ccxp-skills/<version>/`, so a script can derive its profile from its own path even when the env var is absent (for example a cron or hook subprocess)
- Several scripts already write `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` inline (`hud/scripts/ledger.sh:63`, `hooks/terms-hook.sh:23`, `_repos/repos.sh:32`): correct when set, but each copy is a bare `$HOME/.claude` and none derives from the path
- `_session/claimant-id.sh` and `hud/scripts/hud-lib.sh` are deliberately side-effect-free (no `set`, no I/O at source time, header comments): the helper must keep that property

## Root cause

- Oversight, not a decision: `$HOME/.claude` was written as the default before profiles with a relocated config dir were in use
  - `_session/claimant-id.sh:30`, `hud/scripts/hud-lib.sh:26`, `hud/scripts/last-input-hook.sh:27` default state dirs under `$HOME/.claude` and ignore `CLAUDE_CONFIG_DIR`
  - Introduced in `5afe835` (2026-09-28, initial public release); `319083a` (2026-10-25) carried the hud copies forward (verified with `git log -S`)
- Same assumption in the `.env` loaders (`_session/_lib.sh:53`, `_session/task_claim.sh:538`, `_session/attribution.sh:68`, `_slack/webapi.sh:54`, `slack/scripts/slack-send.sh:49`), the session-id file (`_session/_lib.sh:110`) and `agent-pairing/scripts/agent-pairing.sh:38`
- Effect: any hook or HUD poll run with `HOME` set but state under `~/.claude-work` creates an empty `~/.claude/state/...` next to the real profile

## Solution

- New `_session/profile-dir.sh` (sourceable, no `set`, no I/O at source time) defining `ccxp_profile_dir`, which prints the first match of
  - `CLAUDE_CONFIG_DIR` when set and an existing directory
  - the helper's own resolved path, when it contains `/plugins/cache/` or `/plugins/marketplaces/`: everything before that segment
  - `$HOME/.claude` (unchanged legacy default; the one place the literal may appear)
- Every script that needs the folder sources the helper by a path relative to itself (`<dir>/../_session/profile-dir.sh`) and calls `ccxp_profile_dir`; explicit overrides (`CLAIMANT_STATE_DIR`, `LAST_INPUT_STATE_DIR`, `CCXP_LEDGER_FILE`, ...) still win, so tests and callers are unaffected
- `secret-guard.py` takes the log path from `secret-guard.sh` (which resolves it through the helper) instead of guessing `~` itself
- Audit rule: fix code lines; leave comment-only and docs-only mentions (README, SKILL.md prose) alone; update user-facing error messages to name the resolved dir
- Lint `_session/lint_profile_dir.sh`: fails on a bare `$HOME/.claude`, `${HOME}/.claude` or `~/.claude` on a non-comment line of any shell script outside the helper; run from BATS so CI enforces it
- Alternatives rejected
  - Each script keeps its inline `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`: the owner asked for detection of the running session, and the path-derivation step would be copied about 25 times
  - Read the profile from the Claude Code process environment or `ps`: not portable, and a hook subprocess already inherits `CLAUDE_CONFIG_DIR` when it is set
  - Make `CLAUDE_CONFIG_DIR` mandatory: breaks the unset case that `~/.claude` users rely on

## Test plan

- [ ] Unit: `tests/profile_dir.bats` covers all three resolution steps, a set-but-missing `CLAUDE_CONFIG_DIR`, a symlinked cache path, and a path with spaces
- [ ] Isolation: with `CLAUDE_CONFIG_DIR` and `HOME` both temp dirs, run `claimant-id.sh`, `last-input-hook.sh`, `hud-lib.sh` helpers, `_lib.sh` `session_cc_session_id` and assert `$HOME/.claude` is never created
- [ ] Backward compat: with `CLAUDE_CONFIG_DIR` unset and a clone path outside the cache, state lands in `$HOME/.claude/state` exactly as before
- [ ] Lint: `tests/profile_dir_lint.bats` passes on the tree and fails on a planted `$HOME/.claude` line
- [ ] CI: the full `bats tests/` suite and the repo lints are green on the PR

## Done criteria

- [ ] One helper, no other shell code line holds a bare profile literal: `_session/lint_profile_dir.sh`, `tests/profile_dir_lint.bats`
- [ ] The three named defaults honor the profile: `_session/claimant-id.sh`, `hud/scripts/hud-lib.sh`, `hud/scripts/last-input-hook.sh`, tested in `tests/profile_dir.bats`
- [ ] No `~/.claude` is created under a temp `HOME` when `CLAUDE_CONFIG_DIR` is set: `tests/profile_dir.bats`
- [ ] Unset `CLAUDE_CONFIG_DIR` behaves as before: `tests/profile_dir.bats` backward-compat case
- [ ] No release, tag or version bump in the PR: diff of `.claude-plugin/plugin.json` is empty

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_session/profile-dir.sh` | new | the shared helper |
| `_session/lint_profile_dir.sh` | new | lint for bare profile literals |
| `_session/claimant-id.sh` | 30 | state dir default |
| `hud/scripts/hud-lib.sh` | 26, 30, 183, 349, 408 | last-input dir, skills fallback, cache, ledger, queue |
| `hud/scripts/last-input-hook.sh` | 27 | last-input dir default |
| `_session/_lib.sh`, `task_claim.sh`, `attribution.sh`, `lint_frozen.sh` | see Root cause | `.env` loaders, session-id, lint path |
| `_slack/webapi.sh`, `slack/scripts/slack-send.sh` | 54, 49 | `.env` lookup and messages |
| `hooks/*.sh`, `hooks/secret-guard.py` | 22-28, 271 | hook config and log paths |
| other hud, agent-pairing, eta, repos, memory-to-skill scripts | see lint output | inline fallbacks moved to the helper |
