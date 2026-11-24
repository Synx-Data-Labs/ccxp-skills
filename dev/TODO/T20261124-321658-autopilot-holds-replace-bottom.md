---
status: In Progress
estimation: 2
blocks: [T20261124-115593]
source: epic split of T20261124-989194 (job 1514), owner request 2026-11-24
related: [T20261124-989194]
type: feature
description: Phase 4 turns a NEEDS-ATTENTION or STUCK cycle into a needs-human or stalled hold instead of a bottom PR, and the HUD queue cell shows the held count
claimed_by: cc1-50ac6891:da50a3e74f488718
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261124-321658: A stalled cycle creates a hold, not a bottom PR; HUD held count

## Problem

- **Type**: feature
- Sub-task 4 of 5 of T20261124-989194 (autopilot cursor and holds).
- Owner's words: "bottom" is replaced by the cursor. Existing queue-order changes stay owner or sweep driven.
- Dependency chain (d158): this task is done before T20261124-115593; queue order follows the chain.

## Done criteria

- [ ] `autopilot/SKILL.md` Phase 3 and 4: a `NEEDS-ATTENTION` report runs `hold-add <id> needs-human <condition> "<reason>"`, a `STUCK` one `hold-add <id> stalled ...`, a `WAITING` one `waiting`; no `/bottom`, no queue.md edit, no housekeeping PR for bottoming; `holds-check` runs at the start of each cycle's pick.
- [ ] `classify`/`plan` output maps to hold kinds; the `bottomed` outcome and its 60 s wake stay, renamed `held` in docs if the tests allow.
- [ ] HUD queue cell appends the held count (for example `7 queued, 2 held`) from the state file, no per-task text; `hud/README.md` documents it; the HUD tests cover zero and non-zero.
- [ ] The visits counter still exists in this step but is no longer consulted for bottoming.
