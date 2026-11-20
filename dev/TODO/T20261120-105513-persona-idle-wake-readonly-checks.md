---
status: Open
estimation: 1
source: Job 1339 analysis B(3) option 2 (L119), owner choice 2026-11-20
description: Persona idle wake every 30 min running only the read-only alerts and CI checks
type: feature
related: T20261120-230152
---

# T20261120-105513: Persona idle wake with read-only alert and CI checks (n362 step 5)

## Problem

- **Type**: feature
- With autopilot off and a session open, nothing checks Slack alerts or CI between user turns.
- Schedule one ScheduleWakeup every 30 min that runs only `alerts-due.sh check` and the CI `gh run list`; start a job only for something new.
- Respect the persona size guard (48000 bytes: tiny prose, detail in a doc) and the existing 5-min alerts rate limit; opt-out via config.
- Update agent-pairing README and persona-refresh per repo rules; bats tests. Do not touch versions, tags or releases.
