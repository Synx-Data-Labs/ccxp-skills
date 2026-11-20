---
status: Done
estimation: 1
source: Job 1339 analysis B(3) option 1 (L117), owner choice 2026-11-20
description: Persona treats overdue autopilot as a red HUD item and offers a one-line restart
type: feature
related: T20261120-645606
claimed_by:
claimed_role:
scheduled: 2026-11-16
---

# T20261120-154507: Autopilot health, overdue autopilot is red and offers a restart (n362 step 4)

## TLDR

- **Type**: feature
- **Problem**: autopilot was `on` with `next_wake_at` 2 days overdue and nothing flagged it loudly; the persona never said anything.
- **Solution**: `autopilot-state.sh overdue` (one rule), the HUD stalled cell and details line turn red, and the persona says one line per hour offering `/autopilot on` as the restart.

## Problem

- Evidence: r1339 section 0: `dev/.autopilot-state.json` `status: on`, `next_wake_at 2026-11-18T20:27:11Z`; the HUD `stalled 2d` cell existed but was warning-coloured, and the persona's only detection points are turns and wakes.
- Impact: the CI and Slack checks piggyback on autopilot wakes, so a dead loop meant no coverage.

## Context

- HUD: `hud/model.ts` `stalledFor` (10-minute grace), band item `stall`, details line `next loop overdue`.
- Persona budget: `assets/ccxp-agent.md` is capped at 48500 bytes (`tests/agent_pairing.bats`), so existing prose was condensed to make room and the detail lives in `agent-pairing/alerts.md`.

## Solution

- `autopilot/scripts/autopilot-state.sh overdue [grace]`: seconds late beyond the grace; 0 when not stalled (off, paused, cycle running, no wake time); the same rule as `stalledFor`.
- HUD: the `stalled` cell and the details overdue line use the error colour, bold.
- Persona: an "Autopilot health" rule (session start and each user turn: run `overdue`; above 0: say once per hour `Autopilot stalled <span>: say "restart autopilot" and I run /autopilot on.`; never restart unasked); details in `agent-pairing/alerts.md`; the persona-refresh doc notes the size cap.
- Persona CI detection also follows the owner's "red is red" ruling (any default-branch or schedule run, whatever the workflow), and the condensing dropped only duplicated wording (kept: run-id dedupe sentence, ack-only re-emit note).
- Review fixes: `overdue` prints the total lateness (wording corrected), the dedupe sentence was restored, and a test ties the 600 s grace across the persona, the script and `hud/model.ts` and runs `overdue` on a seeded state.
- Alternatives rejected:
  - auto-restarting autopilot: the owner asked for an offer; restarting changes what runs unattended;
  - a second top-row item: the existing cell, now red, is the one stalled signal.

## Test plan

- [x] `bats tests/autopilot_state.bats` (overdue cases), `bats tests/agent_pairing.bats` (rule pinned, size cap).
- [x] `hud/pure.test.ts` updated for the red colour (not runnable outside the Claude Code test runner; reviewed by hand).
- [ ] CI: bats suite green on the PR.

## Done criteria

- [x] Overdue rule in one place: `autopilot/scripts/autopilot-state.sh` `ap-overdue`, `tests/autopilot_state.bats` "overdue".
- [x] Red HUD item: `hud/model.ts` stall item, `hud/pure.test.ts` "next loop" tests.
- [x] One-line restart offer in the persona: `tests/agent_pairing.bats` "Autopilot health rule".
- [x] Persona stays under the size guard: `tests/agent_pairing.bats` Repo freshness test (48500).

## Closed (2026-11-20)

- Shipped in the PR that moves this file to `dev/JOURNAL/` (job 1342).
- Needs a plugin release and a session restart before the persona rule is live (persona-check hook installs it).

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, tests written with the change in one pass
- Verification (`superpowers:verification-before-completion`): yes, local bats runs plus /address-pr gate
- Systematic debugging (`superpowers:systematic-debugging`): no, did not get stuck
- Receiving code review (`superpowers:receiving-code-review`): yes, /address-pr review
