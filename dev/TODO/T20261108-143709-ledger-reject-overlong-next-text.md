---
status: Open
estimation: 1
source: this conversation, 2026-11-08
---

# T20261108-143709: ledger.sh rejects over-long Next text instead of cutting it silently

## Problem

- **Type**: bug
- `hud/scripts/ledger.sh` clips `next add`, `next set --text` and `reply --tldr` at 300 chars with `ledger-clip` (`jq '.[0:$n]'`).
  - The cut is silent, permanent and mid-sentence, so stored items end damaged (endings seen: "...Autopilot gh calls fail until", "...send th").
  - `decision add` already uses `ledger-bounded`, which rejects over-long text with an error.
- Done: those three inputs use `ledger-bounded` with a 400 cap (exit 2, nothing written); titles, ids and paths keep their deliberate clip.
  - Docs, the `ccxp-agent` persona item rule and the bats tests state and pin the new limit.
- Out of scope: repairing items already stored damaged (a separate job).
