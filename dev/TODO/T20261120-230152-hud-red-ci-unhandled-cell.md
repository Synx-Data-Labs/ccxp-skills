---
status: Open
estimation: 1
source: Job 1339 analysis (n362), owner 2026-11-20 "then fix n362"
description: HUD red-CI cell showing unhandled failed CI runs across watched repos
type: feature
---

# T20261120-230152: HUD red-CI cell for unhandled failed runs (n362 step 1)

## Problem

- **Type**: feature
- 2026-11-20: Nightly Orchestrator and Upstream Sync went red at 06:06Z and nobody noticed for ~10 h; the HUD `ci` cell shows one workflow+branch only (`hud/scripts/hud-ci.sh`), so Upstream Sync and Tests were invisible.
- Add `hud/scripts/hud-redci.sh`: one cached, detached `gh run list --status failure` per watched repo (TTL, lock dir, timeout; no gh call per HUD refresh), modelled on `hud-ci.sh`.
- Drop runs superseded by a later success on the same workflow+branch, and runs already handled (run id in a ccxp-context file, a ledger title or a TODO).
- Show `✗ N unhandled CI` in the HUD red top row (merge with the `isCiRed` row); wire `hud-data.sh`, `config.ts`, `model.ts`, `render.tsx`; bats tests.
- Defaults: watched repos = session repo plus a configurable list in the hud config (default session repo only); Upstream Sync and Tests failures on the default branch count; no overnight push (follow-up).
- Analysis: r1339 proposal A. Do not touch versions, tags or releases (job 1341 cuts 6.4.0).
