---
status: Done
estimation: 1
source: Job 1339 analysis B(3) option 2 (L119), owner choice 2026-11-20
description: Persona idle wake every 30 min running only the read-only alerts and CI checks
type: feature
related: T20261120-230152
claimed_by:
claimed_role:
scheduled: 2026-11-16
---

# T20261120-105513: Persona idle wake with read-only alert and CI checks (n362 step 5)

## TLDR

- **Type**: feature
- **Problem**: with autopilot off and a session open, nothing checks Slack alerts or CI between user turns.
- **Solution**: `idle-wake.sh plan` tells the persona when to schedule ONE `ScheduleWakeup` (30 min); the wake runs only the alerts check and the CI failure detection, starting a job only for something new; opt-out via env or config.

## Problem

- Evidence: r1339 section 2 limit 1: checks only run at turns and autopilot wakes ("no overnight coverage; autopilot wakes give partial cover").
- Impact: a red CI or an alert waits for the owner's next message.

## Context

- Existing rate limits: `alerts-due.sh check` already refuses a second check within 5 minutes.
- Persona cap 48500 bytes: the rule is a few lines and the detail is in `agent-pairing/idle-wake.md`.

## Solution

- `agent-pairing/scripts/idle-wake.sh plan|status`: records the pending wake time in `<profile>/ccxp-idle/next-at`; prints `schedule <seconds>` only when enabled, autopilot is not on and no wake is pending (pending until due plus 2 minutes); interval default 30 min, never below 5; opt-out `CCXP_IDLE_WAKE=0` or `config.json` `{"enabled": false}`.
- Persona "Idle wake" rule and `agent-pairing/idle-wake.md` (what runs, cost, limits); SKILL.md lists the doc.
- Alternatives rejected:
  - running the checks inside the script: the Slack read is MCP-only and jobs belong to the persona;
  - a cron or launchd poller: owner decision d115 rejects it, and it needs tokens.

## Test plan

- [x] `bats tests/idle_wake.bats` (schedule, pending, re-schedule after due, autopilot on, opt-out, interval, garbage, state failure).
- [x] `bats tests/agent_pairing.bats` (rule pinned, size cap).
- [ ] CI: bats suite green on the PR.

## Done criteria

- [x] One wake per 30 minutes, never stacked: `tests/idle_wake.bats` "plan schedules a 30-minute wake" and "after the wake is due".
- [x] Autopilot on means no idle wake: "autopilot on means no idle wake".
- [x] Opt-out via config: "opt-out".
- [x] Persona prose small, detail in a doc, under the cap: `tests/agent_pairing.bats` size test and the Idle wake rule test.

## Closed (2026-11-20)

- Shipped in the PR that moves this file to `dev/JOURNAL/` (job 1342).
- Limit: only while a session is open; a closed terminal is not covered (documented in `agent-pairing/idle-wake.md`).
- Needs a plugin release and a session restart before the persona rule is live.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, tests written with the change in one pass
- Verification (`superpowers:verification-before-completion`): yes, local bats runs plus /address-pr gate
- Systematic debugging (`superpowers:systematic-debugging`): no, did not get stuck
- Receiving code review (`superpowers:receiving-code-review`): yes, /address-pr review
