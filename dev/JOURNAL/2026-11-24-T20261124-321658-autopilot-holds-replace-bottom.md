---
status: Done
estimation: 2
blocks: [T20261124-115593]
source: epic split of T20261124-989194 (job 1514), owner request 2026-11-24
related: [T20261124-989194]
type: feature
description: Phase 4 turns a NEEDS-ATTENTION or STUCK cycle into a needs-human or stalled hold instead of a bottom PR, and the HUD queue cell shows the held count
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261124-321658: A stalled cycle creates a hold, not a bottom PR; HUD held count

## Problem

- **Type**: feature
- Sub-task 4 of 5 of T20261124-989194 (autopilot cursor and holds).
- Owner's words: "bottom" is replaced by the cursor. Existing queue-order changes stay owner or sweep driven.
- Dependency chain (d158): this task is done before T20261124-115593; queue order follows the chain.

## Done criteria

- [x] `autopilot/SKILL.md` Phase 3 and 4: a `NEEDS-ATTENTION` report runs `hold-add <id> needs-human <condition> "<reason>"`, a `STUCK` one `hold-add <id> stalled ...`, a `WAITING` one `waiting`; no `/bottom`, no queue.md edit, no housekeeping PR for bottoming; `holds-check` runs at the start of each cycle's pick.
- [x] `classify`/`plan` output maps to hold kinds; the `bottomed` outcome and its 60 s wake stay, renamed `held` in docs if the tests allow.
- [x] HUD queue cell appends the held count (for example `7 queued, 2 held`) from the state file, no per-task text; `hud/README.md` documents it; the HUD tests cover zero and non-zero.
- [x] The visits counter still exists in this step but is no longer consulted for bottoming.

## Closed (2026-11-24)

- Shipped in PR #765 (claim PR #766): `autopilot-state.sh hold-report <file> [--fallback T<id>] [--repo <root>]` turns a cycle's report into holds (NEEDS-ATTENTION to `needs-human`, released when the task file changes else after 24 h; STUCK to `stalled`, after 2 h; WAITING to `waiting`, after 1 h; a run of stuck cycles, `stuck_count` 3 or more, holds nothing); `autopilot/SKILL.md` Phase 3 and 4 rewritten (`holds-check` before each pick, dispatch is `/drive T<id> --auto-selected` with the id `top` names, no `/bottom`, no `queue.md` edit, no housekeeping agent or PR; the `bottomed` outcome name and its 60 s wake stay); `drive/SKILL.md` and `parallel.md` follow; the HUD queue cell shows the hold count as a `hd` token (band `2hd`, details `| 2 on autopilot hold`; `h` stays status-held).
- The visits counter still existed after this step and was no longer consulted; T20261124-115593 removes it.
- Known and accepted: a `file-changed` hold also releases when a pull rewrites the task file; no hold is made while the loop is paused; a held task keeps its claim until this clone's next claim runs `release-others`; `hud/pure.test.ts` could not run with the real runner locally.
- Follow-ups filed: none.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, tests written alongside the code
- Verification (`superpowers:verification-before-completion`): yes, local bats, skill score and plugin validate before every push, plus two independent review rounds on #765
- Systematic debugging (`superpowers:systematic-debugging`): no
- Receiving code review (`superpowers:receiving-code-review`): yes, stale-prose findings fixed, mtime and pause gaps accepted with a note
