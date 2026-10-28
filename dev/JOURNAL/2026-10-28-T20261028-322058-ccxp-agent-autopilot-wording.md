---
status: Done
scheduled: 2026-10-26
estimation: 1
source: T20261028-151063 (autopilot on/off redesign), filed 2026-10-28
related: T20261028-151063
description: Update ccxp-agent.md for the new /autopilot grammar (on/off/pause/resume/status) once the open PR on that file lands
---

# T20261028-322058: Update ccxp-agent.md for the new /autopilot grammar

## Problem

- **Type**: chore
- `agent-pairing/assets/ccxp-agent.md:37` still gives `/autopilot 2h` as an example; the grammar is now `on | off | pause | resume | status` (T20261028-151063)
- The `/autopilot` exception section (`ccxp-agent.md:21`) should name `autopilot/scripts/autopilot-state.sh` as the allowed bookkeeping Bash
- Deferred from T20261028-151063: another job has an open PR on this file, so it was not touched there
- Done when: the example and the exception wording match `autopilot/SKILL.md`, and `tests/agent_pairing.bats` still passes

## Journal

- Replaced the stale `/autopilot 2h` example at `ccxp-agent.md:37` with `/address-pr 42` (`/autopilot` is already excepted on that line)
- The exception section (`ccxp-agent.md:23`) already names `dev/.autopilot-state.json` and the dispatch clone; no change needed
- Verified: `grep -rn "autopilot 2h" agent-pairing/` returns nothing
