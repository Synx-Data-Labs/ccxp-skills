---
status: Open
estimation: 2
source: Step of T20261122-234265 (cross-account bus build order)
related: T20261122-234265
description: Add _bus/bus.sh (send, deliver, watch, status, read, prune) with the bats suite
---

# T20261123-352398: Bus step 2: _bus/bus.sh and bats tests

Parent: [T20261122-234265](../TODO/T20261122-234265-cross-account-mailbox-bus.md); spec: [cross-account-bus-spec.md](../docs/cross-account-bus-spec.md)

## Scope

- `_bus/bus.sh` with `send`, `deliver`, `watch`, `status`, `read`, `prune`; locks through `_session/lock.sh`, no `flock`
- Bash and tools present on macOS and Linux only; pin time with `NOW=`
- Bats: encode/decode, unknown fields, 4000-char cap, cursor and `recent_ids`, rotation at EOF, 4 writers concurrency, `kill -9` crashes, permission and second-session guards, injection sanitizing
