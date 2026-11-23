---
status: In Progress
estimation: 2
source: Owner request 2026-11-23 (job 1365)
type: feat
description: Make the ccxp-agent CI failure response per-turn job cap configurable, default 6
---

# T20261123-136500: Configurable CI job cap

## Problem

- Owner's words: "make three-jobs-per-turn configurable, and configure it to 6"
- The cap was a hard-coded 3 in the persona's "CI failure response" Limits bullet

## Design

- New read-only `agent-pairing/scripts/ci-job-cap.sh` prints the cap: env `CCXP_CI_JOB_CAP`, else `ciJobCap` in `<profile>/ccxp-hud.json` (the profile's existing ccxp config file), else 6; invalid values fall through
- Persona says "at most N such jobs per turn, N from the script (default 6)"; persona stays under the 48500-byte guard
- `CCXP_ALERTS_CAP` (Slack alerts, default 3) is a separate setting and unchanged
- The owner's profile needs no write: the default already equals 6

## Acceptance criteria

- [x] Script plus bats tests (default, env, invalid, config file)
- [x] Persona, `agent-pairing/SKILL.md`, `hud/README.md` and `alerts.md` updated
