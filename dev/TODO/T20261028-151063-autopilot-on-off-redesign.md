---
status: Design
estimation: 1
source: Conversation 2026-10-28 (user spec for the /autopilot redesign)
description: Redesign /autopilot as on/off/pause/resume/status with no duration; loops /drive until off, notifies once when idle
claimed_by: cc1-50ac6891:628a122d26bbecbf
claimed_role: interactive
scheduled: 2026-10-26
---

# T20261028-151063: Redesign /autopilot as an on/off background /drive loop

## Problem

- **Type**: feature
- Today `/autopilot <duration>` runs a time-boxed /drive loop and stops at `elapsed` or `queue-empty` (`autopilot/SKILL.md`)
- User wants only `/autopilot on`, `/autopilot off`, `/autopilot pause|resume`, `/autopilot status` — no duration argument
- While on, it keeps running `/drive`; when nothing is drivable it sends a Slack notification, waits, and retries
- Goal: keep tasks moving in the background whenever it is on
- Approved baseline (conversation 2026-10-28):
  - `on` runs until `off`; no `until <ISO>` resume token; an old state file is treated as `off`
  - Eligibility guardrails: skip SUPERVISED/human-needed tasks and tasks needing real builds, publishes, tags, customer-visible posts or HashData action
  - Idle: notify once on going idle, retry every 30-60 min, keep the stuck back-off
  - Mandatory soft daily cap kept in a small config, not an argument
  - Slack via `/slack` when configured, else state file and HUD fallback that never errors
  - One `/drive` at a time; `ccxp-hud` AP on/off display keeps working
- Done looks like: new SKILL.md, tests, and docs/HUD references to `/autopilot <duration>` and `until`/`stuck=` updated
