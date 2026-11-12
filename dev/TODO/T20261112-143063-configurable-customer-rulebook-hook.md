---
status: Open
estimation: 1
source: Owner chat 2026-11-12
related: T20261103-139722
description: Configurable customer-provided rule book for the ccxp-agent plugin - config key, pending-export hook, generic renderer, dispatcher rule
---

# T20261112-143063: Configurable customer-provided rule book (config key, pending-export hook, generic renderer)

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

## Problem

- **Type**: feature (umbrella)
- Owner ask: point the plugin at a customer-provided rule book, so the ccxp-agent persona and hooks follow it; generic users stay unaffected.
- Today the decisions log (`ccxp-decisions.json`, see `agent-pairing/decisions.md`) is exported to a rule book by hand: the dispatcher is hand-dispatched after every rule change, one export per burst. Nothing reminds it.
- The renderer is company-specific and lives outside this plugin: [Synx-Data-Labs/synxdb-team](https://github.com/Synx-Data-Labs/synxdb-team) `scripts/render-rulebook.sh`, with `tests/render_rulebook.bats` and fixture `tests/fixtures/rulebook-decisions.json` (PR #791 there). Other teams cannot reuse it.

### Scope (three slices)

- **1. Config key**
  - A plugin config key holds the rule book path: repo-relative or absolute file, read by the ccxp-agent persona and the hooks.
  - Default none; with it unset nothing changes for generic users.
- **2. Pending-export hook**
  - When the decisions log changes (decision add, supersede, retire), the hook records "rulebook export pending".
  - It surfaces that on the next session start / reply, so the dispatcher dispatches the export (replaces today's hand dispatch; one export per burst).
  - The marker clears when an export completes; no-op when the config key is unset.
- **3. Generic renderer + persona rule**
  - Ship a generic renderer in the plugin: `ccxp-decisions.json` to a markdown rule book grouped by tier codes.
  - Add a ccxp-agent persona rule (dispatcher): run the export job after rule changes.
  - The company repo keeps only its own tiers/titles config; port its bats test and fixture as the plugin's tests.

### Done looks like

- Config key documented; unset means zero behavior change (tested).
- Changing the decisions log yields a pending marker that shows up at next session start / reply and clears after export.
- Renderer output is deterministic and covered by bats tests with a synthetic fixture (no company or customer data).

### Notes

- Umbrella: may split into the three slices at `/incept` time; not split now.
- Release is cut later at the owner's decision (6.4.0 candidate, MINOR: new backward-compatible capability); this task does not publish anything.
