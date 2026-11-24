---
status: Open
estimation: 1
source: owner request 2026-11-24 (job 1524), epic E4
related: [T20261121-412600]
description: After the decision-to-code moves land, shrink the persona text to free room under the size cap; propose with persona-review.sh, apply with owner agreement
type: chore
---

# T20261124-209545: Persona trim after the decision moves (d155)

## Problem

- **Type**: chore
- Implements decision d155 (2026-11-24): keep the persona small by moving logic into skills and scripts; `/retro` improves the persona from the decisions log.
- Depends on (text, no blocked status): T20261124-395783 (CI-failure skill) and T20261124-290097 (merge-gate snippet) landing first; the d140 task-per-job rule is already mechanical (T20261121-412600) so its persona bullet and the ledger start-line text can shrink to a pointer.
- Run `retro/scripts/persona-review.sh size` for before and after bytes; replace each moved section with a 2 to 4 line pointer naming the skill and command; add or extend the bats key-rule test so every kept rule still appears in persona, skill or script.
- Persona edits only with the owner's agreement (the retro step proposes, never applies); the persona cap stays, headroom is the result.
- Retire when shipped: nothing; the owner or dispatcher may retire d140 after confirming the pointer.

## Done criteria

- Persona smaller than at task start by a stated byte count, `bats tests/agent_pairing.bats` green, key-rule test green.
