---
status: Open
estimation: 2
source: Step of T20261122-234265 (cross-account bus build order)
related: T20261122-234265
description: Finish the watch wake (asyncRewake) path and the idle-wake.sh deliver fallback
---

# T20261123-212153: Bus step 6: watch wake hook and idle-wake fallback

Parent: T20261122-234265; spec: [cross-account-bus-spec.md](../docs/cross-account-bus-spec.md)

## Scope

- Adds the `Stop` async `watch` entry to `hooks/hooks.json` (step 3 owns the `SessionStart` entries)
- `watch` wake behaviour: one watcher per name, wake via stderr and exit 2, inotifywait or fswatch when present
- Fallback: `idle-wake.sh` also runs `bus.sh deliver`
- Anything needing two live accounts stays an unticked acceptance item on the parent
