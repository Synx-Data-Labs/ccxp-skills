---
status: In Progress
estimation: 1
source: owner request, this conversation, 2026-11-24 (decisions d154, d157)
description: Autopilot max_dop minimum 3 plus a reserved_slots setting (default 2) for urgent tier 1 and 2 work
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261124-182499: Autopilot: max_dop at least 3, add reserved_slots (default 2)

## Problem

- **Type**: feature
- Owner's words: "for the AP slots, the configurable number has to be 3 and above, since we always reserve 2 slots for the tier1 and tier2 tasks. see if you can create a task and put it inside the /autopilot configuration"
- d154: "Autopilot: reserve 2 slots (of max_dop) for urgent tier 1 or tier 2 tasks that pop up; routine picks fill at most max_dop minus 2 slots; the reserved slots are used only for urgent work (a new or /top'd task, CI-failure response)"
- d157: "max_dop must be 3 or more because 2 slots are always reserved, and the reserved count is a config setting reserved_slots default 2"
- Today `max_dop` is 1-16, default 1 (`autopilot/scripts/autopilot-state.sh` `_ap_config_spec`), and no reserved-slot notion exists.
- Done looks like:
  - `config set max_dop <n>` refuses n below 3 (exit 2, nothing written, message names the 2 reserved slots); range 3-16, default 3; an existing file with 1 or 2 is clamped to 3 on read with a one-line notice in `config-show` and `status`, never rewritten silently
  - new key `reserved_slots` (integer, default 2, 0-8, at most max_dop minus 1) works with `config set/reset/show`
  - routine limit (max_dop minus reserved_slots) is shown by `slots`/`status`/`report` (for example `routine 8 of 10, reserved 2`), with a one-call helper for the dispatcher if it helps
  - `autopilot/SKILL.md` (minimal, net-zero size, skill-quality baseline 83), `autopilot/parallel.md`, `hud/README.md` (if it shows slots) and `tests/autopilot_state.bats` updated
  - persona asset `agent-pairing/assets/ccxp-agent.md` untouched; no version bump or release
