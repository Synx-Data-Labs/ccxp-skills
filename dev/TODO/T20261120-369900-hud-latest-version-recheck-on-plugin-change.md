---
status: In Progress
estimation: 1
source: Job 1340 finding (HUD latest-version cache), owner 2026-11-20
description: Re-check the HUD latest-version cache once when plugin.json mtime changes
type: bug
related: T20261120-230152
claimed_by: cc1-50ac6891:063790e7ec65724a
claimed_role: interactive
scheduled: 2026-11-16
---

# T20261120-369900: HUD latest-version cache re-check on plugin change (n362 step 3)

## Problem

- **Type**: bug
- `hud/scripts/hud-version.sh` caches the latest remote tag for 6 h (`HVR_TTL=21600`); after a plugin update or `/reload-plugins` the HUD can show a stale "latest" for up to 6 h.
- Re-check once when the running plugin's `plugin.json` mtime changes (store the mtime in the cache); keep TTL, lock and detached refresh; bats test.
- Do not touch versions, tags or releases.
