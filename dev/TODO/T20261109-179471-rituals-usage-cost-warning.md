---
status: Open
scheduled: 2026-11-23
estimation: 1
source: owner decision 2026-11-09 (T20261107-228304 scope cut)
related: T20261107-228304
description: The old daily-ccxp usage-cost warning, as a separate follow-up to the persona-driven rituals
---

# T20261109-179471: Usage-cost warning for the persona-driven daily rituals

## Problem

- The old launchd wrapper (`dev/daily-ccxp.sh` in the build hub, function `usage-warn`) warned when daily ritual runs got expensive. The persona-driven rituals (T20261107-228304, `agent-pairing/rituals.md`) deliberately do not include it.
- Owner: the old usage-cost warning from daily-ccxp is a separate follow-up task, not part of the rituals work.
- Done looks like: a ritual job (or the persona's own check) reports its cost or token use once per day and warns above a configurable threshold, with BATS where the logic is scriptable. First step: read `usage-warn` in the hub wrapper and decide whether a plugin-owned equivalent is still wanted.

## Done criteria

- [ ] Decide keep or drop (the wrapper is being retired by T20261107-431002); if kept, design and implement the warning.
