---
status: Open
estimation: 1
source: lsc-bot session conversation, 2026-10-08
related: PR #280 (manual bump 1.0.1 → 1.1.0)
description: Auto-bump plugin.json version on release so installed plugin caches actually refresh
---

# T20261008-636871: Auto-bump plugin.json version on release

## Problem

- **Type**: chore
- The installed plugin cache stayed on the 2026-09-15 snapshot for about 246 commits
  - `~/.claude-personal/plugins/cache/ccxp-skills/ccxp-skills/1.0.1` was pinned at commit `f212fa2`
  - `.claude-plugin/plugin.json` `version` stayed at `1.0.1` from `5051a9e` (initial release) until [PR #280](https://github.com/Synx-Data-Labs/ccxp-skills/pull/280)
- `claude plugin update` reinstalls only when the version changes; it reported nothing new and kept serving stale skills
  - The stale copy had no `_gh/git.sh` and still had the retired `_gh/auto-switch.sh`
  - Sessions therefore ran bare `git`/`gh` (wrong active account) or fell back to manual `GH_TOKEN=...` workarounds
- Marketplace auto-update (`/plugin` → Marketplaces → enable auto-update) runs into the same version check, so turning it on alone doesn't fix this

## Done looks like

- Every merge to `main` that changes shipped plugin content bumps the `plugin.json` version without anyone remembering to
  - Options: a CI step on push to `main`, or a pre-push hook; pick one at design time
- The README documents turning on marketplace auto-update for this local-directory marketplace, so new versions load at session start
