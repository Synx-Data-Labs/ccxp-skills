---
status: Open
scheduled: 2026-10-12
estimation: 2
source: Follow-up from T20260924-252293 (decided the IPM ceremony is retired
  as a mandatory cron step)
related: T20260924-252293
---

# T20261002-245216: Note retro's bump-3x/2x detectors as dormant-by-design; clean up two stale cross-references

## Problem

- T20260924-252293 (design PR #239, merged) retired the mandatory Monday IPM
  ceremony. `retro/SKILL.md` Phase 1 step 10 and `/ipm` step 1's bump-2x
  reassessment both key **exclusively** off reading committed
  `*-ipm-weekly.md` files — with the ceremony retired, those files will
  never exist, so the detectors' existing no-op guard
  (`ccxp/SKILL.md:359`: *"Skip this block if no `*-ipm-weekly.md` exists
  yet"*) becomes **permanent**, not just the current transient state.
- Two separate, pre-existing doc-drift items surfaced while verifying
  T20260924-252293, unrelated to the IPM decision itself but cheap to fix
  alongside this task:
  1. `retro/SKILL.md` Phase 4b references escalating bumped tasks to a
     `priority: High` frontmatter field. `todo/SKILL.md` states plainly:
     *"There is no `priority:` field — position in `queue.md` **is** the
     priority... a prior free-form `Critical/High/.../Low` field... is
     retired."* `retro/SKILL.md` never got updated for this.
  2. `ipm/SKILL.md:104` claims *"The `/todo next` ranking already factors
     deadlines, urgency ratio, and unblocks-others... Do not second-guess
     that ordering here; the IPM trusts it."* This is stale —
     `todo/SKILL.md`'s current `next` workflow is a flat `queue.md` walk
     (skips Done/peer-claimed only) with no scoring. `ipm/SKILL.md` is
     describing a ranking mechanism that doesn't exist in `/todo next` today.

## Done when

- `retro/SKILL.md` Phase 1 step 10 / Phase 2 / Phase 4b note that the
  bump-3x/2x detectors (and the `priority: High` escalation they used to
  drive) are dormant by design absent a running IPM ceremony — not broken,
  just inert, consistent with T20260924-252293's decision.
- The `priority: High` reference in `retro/SKILL.md` Phase 4b is corrected or
  removed to match `todo/SKILL.md`'s retired-field note (decide: drop the
  escalation step entirely, or repoint it at something still live — e.g.
  `/top`-ing the task).
- `ipm/SKILL.md:104`'s claim about `/todo next`'s ranking is corrected to
  match `todo/SKILL.md`'s actual, current `next` behavior (flat queue walk,
  no deadline/urgency/unblocks scoring) — or the whole passage is removed if
  `/ipm` itself becomes optional/ad-hoc per T20261002-219904.
