---
status: Open
estimation: 1
source: owner request, this conversation, 2026-11-09
description: HUD queue.source defaults to default-branch, not the local working tree
---

# T20261109-338243: HUD queue source defaults to the GitHub default branch

## Problem

- **Type**: feature
- Owner: the HUD default config should always read the queue from the current repo's default branch on GitHub, not from the local clone, because the local clone falls behind.
- Today an unset `queue` means `working-tree` (`hud/register.tsx:163`, `hud/scripts/hud-data.sh:65`, `hud/scripts/hud-lib.sh` `sl-queue-json`).
- Wanted:
  - Unset or invalid `queue.source` means `default-branch`; an explicit `"working-tree"` stays supported as opt-in.
  - The never-fatal fallback to the working tree (flagged `fallback`) stays.
  - The detached fetch goes to `origin` and the default branch only, never to local branches.
  - README (Config table, Queue cell), the `/hud config` dialog default and the bats/vitest tests follow.
