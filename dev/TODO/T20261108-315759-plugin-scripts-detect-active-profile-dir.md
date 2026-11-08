---
status: Design
estimation: 3
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

- New `_session/profile-dir.sh` (sourceable, no `set`, no writes, no exports, tolerates unset `HOME`) sets the plain variable `CCXP_PROFILE_DIR` eagerly at source time (a few `[ -d ]` stats, no writes: the same cost class as the existing source-time work) and defines two functions
  - `ccxp_profile_dir`: prints `CCXP_PROFILE_DIR`; callers read the variable directly on hot paths, so nothing forks and nothing needs to cross a subshell
  - `ccxp_env_files`: prints `<profile>/.env`, then the legacy `$HOME/.claude/.env` when it differs, one per line (existence is the caller's check)
- Resolution order for `CCXP_PROFILE_DIR`, first match wins
  - `CLAUDE_CONFIG_DIR` when set and non-empty: the running session is authoritative, so a named profile is used even if its directory does not exist yet (Claude Code creates it); this widens the owner's "set and a directory" wording so that a named profile can never fall through to `~/.claude`
  - the helper's own logical absolute path (`cd && pwd`, never `-P` or `readlink -f`, so a symlinked cache keeps its `/plugins/cache/` segment) when it contains `/plugins/cache/`: everything before the last such segment (hooks run from `${CLAUDE_PLUGIN_ROOT}`, inside the cache)
  - `$HOME/.claude` (the legacy default; the only place the literal may appear)
- Trailing slashes are stripped; `/private/var` vs `/var` is left to the caller (the test compares resolved paths)
- Callers source the helper by a path relative to their own location (`../_session/` from `hooks`, `_slack`, `slack/scripts`; `../../_session/` from `hud/scripts` and `agent-pairing/scripts`) with a bare `[ -r ] && .`; a missing helper leaves `CCXP_PROFILE_DIR` empty and every caller skips its profile-dependent write or read (hooks stay fail-open, nothing is created, nothing guesses `~/.claude`); the legacy `$HOME/.claude/skills/_session/` fallback loops (`hud-lib.sh:30`, `eta.sh:22`) are dropped: the plugin ships `_session/` beside them (verified by the tree layout), the statusline wrapper that could run them from a flat `~/.claude/skills` install was retired in `319083a`, and the literal cannot survive the lint
- `.env` loaders (`_session/_lib.sh`, `task_claim.sh`, `attribution.sh`, `_slack/webapi.sh`, `slack-send.sh`) read `<profile>/.env` first, then the helper's `ccxp_env_files` also yields the legacy `$HOME/.claude/.env` when it differs, so an owner with a relocated profile and an old `.env` loses nothing; BATS reaches `_lib.sh`, `task_claim.sh` and `attribution.sh` through the existing `ENV_FILE` hook, `slack-send.sh` through `SLACK_ENV_FILE`, and `_slack/webapi.sh` (no seam) by sourcing it with a temp `HOME` and `CLAUDE_CONFIG_DIR` whose `.env` holds a dummy value, plus a direct `ccxp_env_files` test
- `hooks/secret-guard.sh` exports `CCXP_SECRET_GUARD_LOG` (resolved through the helper) before `python3 -I`; `secret-guard.py:271` and `lint_refs.py:296` fall back to `CLAUDE_CONFIG_DIR` then `~/.claude` on a line carrying the marker `profile-dir-ok`, because Python cannot source the helper
- `_session/lint_frozen.sh:42` (a skills-tree path, not state) resolves `$CCXP_PROFILE_DIR/skills/...` through the helper; the helper is bash-only (it needs `BASH_SOURCE`), as are all callers
- Audit rule: fix every code line; fix agent-executed prose too (`agent-pairing/assets/ccxp-agent.md`, `retro/SKILL.md:466,469`: give the `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` form); leave explanatory comments and README prose; update user-facing error messages to name the resolved dir
- Lint `_session/lint_profile_dir.sh`: scans `*.sh` and `*.py` outside `tests/`; flags `$HOME/.claude`, `${HOME}/.claude`, `~/.claude` `Path.home() / ".claude"` and a quoted `".claude"` path component (as in `os.path.join(..., ".claude", ...)`) followed by a non-word, non-hyphen character or end of line (so `.claude-work`, `.claude-plugin` and repo-relative `.claude/state` pass) on non-comment lines, including every inline `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`; the helper, the lint itself and lines with the `profile-dir-ok` marker are exempt; run from BATS so CI enforces it
- Env/path disagreement: `CLAUDE_CONFIG_DIR` wins over the script path (the running session is authoritative); the path derivation covers hooks and cron with no env
- Alternatives rejected
  - Each script keeps its inline `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`: the owner asked for detection of the running session, and the path-derivation step would be copied about 25 times
  - Read the profile from the Claude Code process environment or `ps`: not portable, and a hook subprocess already inherits `CLAUDE_CONFIG_DIR` when it is set
  - Make `CLAUDE_CONFIG_DIR` mandatory: breaks the unset case that `~/.claude` users rely on

## Test plan

- [ ] Unit: `tests/profile_dir.bats` covers each resolution step, a set-but-missing `CLAUDE_CONFIG_DIR`, a symlinked cache path (expects the profile before the link), a path with spaces, a trailing slash, an unset `HOME`, and `ccxp_env_files`
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
| `hooks/*.sh`, `hooks/secret-guard.py`, `repo-conventions/scripts/lint_refs.py` | 22-28, 271, 296 | hook config and log paths |
| `agent-pairing/assets/ccxp-agent.md`, `retro/SKILL.md` | 466, 469 | agent-executed prose with a bare `~/.claude` |
| other hud, agent-pairing, eta, repos, memory-to-skill scripts | see lint output | inline fallbacks moved to the helper |
