---
status: Design
estimation: 1d
source: conversation with @shine, 2026-09-23
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260923-584914: Extract /ccxp's Monday IPM ritual into a standalone /ipm skill

## Problem

- **Type**: feature
- `/ccxp/SKILL.md` inlines the entire Monday Iteration Planning Meeting
  ritual as Phase 2a, sub-phased 2a.0 through 2a.6:
  - `ccxp/SKILL.md:582` — 2a.0 Capture this IPM's Scheduled date
  - `ccxp/SKILL.md:597` — 2a.0.1 Sweep stale tasks before scoping
  - `ccxp/SKILL.md:622` — 2a.1 Carry over WIP (Tier 1)
  - `ccxp/SKILL.md:636` — 2a.1.5 Seed carry-over candidates
  - `ccxp/SKILL.md:642` — 2a.2 Pick candidates (Tier 2)
  - `ccxp/SKILL.md:650` — 2a.3 Pre-IPM design pass (interactive only,
    calls `/incept`)
  - `ccxp/SKILL.md:682` — 2a.4 Budget cut
  - `ccxp/SKILL.md:696` — 2a.5 Write ipm-weekly.md + tag Scheduled
  - `ccxp/SKILL.md:816` — 2a.5a Drain previous iteration (HARD GATE)
  - `ccxp/SKILL.md:847` — 2a.5b Update ROADMAP doc (cross-repo)
  - `ccxp/SKILL.md:877` — 2a.6 Slack the focus
- This ritual is only reachable through the full daily/weekly `/ccxp`
  orchestrator (standup → IPM → focus → retro). There's no way to
  re-run iteration planning ad hoc mid-week — e.g. to re-scope tasks
  after a design changes, or re-budget-cut after a priority shift —
  without invoking the whole cron-oriented loop.
- **Done when**: a standalone `/ipm` skill exists covering the 2a.0–2a.6
  logic (cron-mode vs. interactive-mode branching, the 2a.5a hard gate,
  the 2a.5b cross-repo ROADMAP sync, Slack notification all preserved),
  and `/ccxp` Phase 2a is reduced to a call into `/ipm` instead of
  inlining the logic.

## Context

- Companion task T20260923-986928 (rename `/grill-me` to `/incept`,
  vendor `grilling`'s mechanics) landed 2026-09-23: `/ipm`'s 2a.3 call
  site should reference `/incept`, not `/grill-me` — `ccxp/SKILL.md`
  Phase 2a.3 (the section this task extracts from) was updated to
  `/incept` in that same PR, so carry that name forward when writing
  the standalone `/ipm` skill rather than re-copying `/grill-me`.
- Related to T20260922-201976 only in that this session parked driving
  it mid-`/drive` Phase 1 to make room for this planning conversation —
  the two tasks are otherwise unrelated in content.
