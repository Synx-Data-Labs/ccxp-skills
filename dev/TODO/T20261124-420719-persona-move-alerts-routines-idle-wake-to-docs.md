---
status: Open
estimation: 1
blocks: [T20261124-315192]
blocked-by: T20261124-147908
source: owner request 2026-11-24 (decision d155), epic E2
related: [T20261124-147908]
description: Replace the persona's Slack alerts, Routines due and Idle wake sections with 2 to 4 line pointers to the existing docs and scripts
---

# T20261124-420719: Persona move 1: alerts, routines due, idle wake become pointers

## Problem

- **Type**: chore
- Epic E2, smallest cluster first. Persona sections: Slack alerts check 1345 B, Routines due 1011 B, Idle wake 471 B (2827 B, 14 lines).
- The procedures already live in `agent-pairing/alerts.md`, `rituals.md`, `idle-wake.md` and the scripts `alerts-due.sh`, `routine-due.sh`, `ritual-due.sh`, `idle-wake.sh`; the persona repeats part of them.
- Move any rule that exists only in the persona into the doc (or script), leave a 2 to 4 line pointer per section that names the doc and the command to run. Target: persona at most 46500 B.
- Add a bats test: asset under the cap, and the key rules (list them from the old text) still appear in persona or doc.
- Check `persona-refresh.md` flow: after the plugin update the hook refreshes the installed persona; confirm the pointers resolve under the installed plugin path.
- Use `retro/scripts/persona-review.sh size` (from T20261124-147908) for the before/after numbers.

## Done criteria

- Persona at most 46500 B, behaviour identical, new bats test green, `bats tests/agent_pairing.bats` green.
