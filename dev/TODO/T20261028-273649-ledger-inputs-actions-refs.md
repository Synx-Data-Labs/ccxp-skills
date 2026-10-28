---
status: In Progress
estimation: 2
source: Conversation 2026-10-28 (i283)
description: Persist the dispatcher's open Needs input / Needs your action items and ref counters in the HUD ledger
---

# T20261028-273649: Ledger persists inputs, actions and ref counters

## Problem

- **Type**: feature
- The ledger file holds only job rows and parked ids; open questions, user actions and the next `i/a/s/k` refs live only in the dispatcher's context and are lost on restart.

## Solution

- `hud/scripts/ledger.sh` gains `input add|done`, `action add|done`, `ref next|bump`, `show --brief`; new fields `inputs`, `actions`, `ref_counters`.
- Old files keep working; existing subcommands unchanged. `park` bumps `ref_counters.k`.
- Docs: `hud/scripts/ledger.md`; persona wording in `agent-pairing/assets/ccxp-agent.md`.
- Out of scope: plugin version bump, tagging, updating the installed persona copy.
