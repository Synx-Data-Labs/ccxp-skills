---
status: Open
estimation: 2h
source: 2026-09-24 conversation — surfaced while designing T20260924-232855
  (estimation → story points); the human driving this work confirmed the
  weekly IPM/GH-Project-board cadence has been abandoned for a long time
related: T20260924-232855
---

# T20260924-252293: Decide whether `/ccxp`'s weekly IPM ritual should be simplified or retired

## Problem

- `/ccxp` Phase 2a (`ccxp/SKILL.md`) documents an elaborate weekly IPM
  ritual: Tier 1/2 candidate selection, a three-line budget cut (~12h
  product / ~4h infra / ~4h slack out of a 20h week), `dev/JOURNAL/
  YYYY-MM-DD-ipm-weekly.md` commits, the `scheduled:` frontmatter field,
  and a GH Project board mirror (`.github/scripts/sync-tasks-to-issues.py`
  in consumer repos).
- In this repo, that ritual has **never run** — `dev/JOURNAL/` contains
  zero `*-ipm-weekly.md` files despite substantial task-lifecycle history
  (confirmed via `git log --oneline -- dev/JOURNAL/*ipm-weekly*` returning
  nothing).
- The human driving this work confirmed (2026-09-24) this isn't specific
  to this repo — the weekly IPM/GH-Project-board cadence has been
  abandoned generally, in favor of continuous `/todo next` + `/drive`
  pulling straight off the flat `dev/TODO/queue.md` priority order.
- This was discovered mid-design of T20260924-232855, which needed to
  decide what "velocity" should be computed against — it worked around the
  problem by rebasing velocity on calendar weeks instead of IPM iterations,
  but left the underlying question unanswered: **should the IPM machinery
  itself still exist?**
- A related, narrower question raised in the same conversation: even if
  IPM keeps running somewhere, does its Phase 2a.4 three-line
  product/infra/slack budget split still earn its complexity now that
  `dev/TODO/queue.md` is a single flat priority list? (The split exists to
  guard against a real regression — `ccxp/SKILL.md:686-688` cites an infra
  task silently eating a scheduled feature's budget — so simply collapsing
  to "walk the flat queue until points run out" reopens that exact risk.)

## Context

- Not yet designed — needs an `/incept` grill to work through:
  - Is IPM truly dead everywhere this skill is installed, or just
    unused by the human currently driving it? (Scope: this clone can only
    confirm ccxp-skills' own history; other consumer repos aren't
    accessible from here.)
  - If retired: what happens to `scheduled:` (currently read by consumer
    repos' GH Project sync script), and to `/retro`'s bump-3x/bump-2x
    detectors (which key off consecutive Tier-1 IPM commits)?
  - If kept but simplified: does the three-line budget split collapse to
    a flat points-based pull, or does it stay as a proportional split
    (just redenominated), per the two options surfaced in the
    T20260924-232855 conversation?
  - If neither retired nor kept as-is: what does "continuous `/todo
    next`-driven work" need that today's Phase 2a already provides
    (deadline/urgency-aware ranking, unblocks-others weighting) so nothing
    valuable is lost by dropping the ceremony around it?
