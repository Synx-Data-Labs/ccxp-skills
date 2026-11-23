---
status: Done
scheduled: 2026-11-23
estimation: 2
source: Step of T20261122-234265 (cross-account bus build order)
related: T20261122-234265
description: Finish the watch wake (asyncRewake) path and the idle-wake.sh deliver fallback
---

# T20261123-212153: Bus step 6: watch wake hook and idle-wake fallback

Parent: T20261122-234265; spec: [cross-account-bus-spec.md](../docs/cross-account-bus-spec.md)

## Scope

- `watch` wake behaviour: one watcher per name, wake via stderr and exit 2, inotifywait or fswatch when present
- Fallback: `idle-wake.sh` also runs `bus.sh deliver`
- Anything needing two live accounts stays an unticked acceptance item on the parent

## Solution

- The `watch` wake itself shipped with `bus.sh` (step 2: one watcher per name through `watch/<name>.pid`, polls every 2 s or waits on `inotifywait` when present, prints the wrapped notes on stderr and exits 2, gives up quietly at 28740 s, leaves when orphaned) and the hook entries (step 3: `SessionStart` and `Stop`, `asyncRewake`, timeout 28800).
- This step adds the fallback: `idle-wake.sh plan --wake` (the `[idle-wake]` wake) runs `bus.sh deliver` and prints unread notes, wrapped, on stderr; stdout stays `schedule <n>`. No persona text change (the persona is at its size guard). Worst case a note waits one idle-wake interval (30 minutes).
- `agent-pairing/idle-wake.md` documents the fallback.

## Test plan

- [x] `bats tests/idle_wake.bats`: notes on stderr and schedule line on stdout, delivered once, a plain `plan` leaves the bus alone, silent without bus config or with a broken bus
- [x] `bats tests/bus.bats` watch tests: wake with exit 2 and the wrapped note on stderr, second watcher exits at once, deadline exit 0, dead pid file replaced
- [ ] Live: an idle session on one account is woken by a note from another (needs two real accounts; listed on the parent task)

## Closed

- Merged through `/address-pr`. The live two-account wake stays an open acceptance item on T20261122-234265.
