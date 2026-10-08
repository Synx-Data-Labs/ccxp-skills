---
status: Done
scheduled: 2026-10-05
estimation: 2
source: Follow-up from T20260924-252293 (decided the IPM ceremony is retired
  as a mandatory cron step)
related: T20260924-252293
---

# T20261002-219904: Document `/ccxp`'s Monday IPM ceremony as optional/ad-hoc, not a mandatory cron step

## Problem

- T20260924-252293 decided (design PR #239, merged) to retire `/ccxp`'s
  mandatory Monday IPM budget-cut ceremony — it has never executed in this
  repo's history (`git log --oneline -- "dev/JOURNAL/*ipm-weekly*"` → 0
  commits) — in favor of the continuous `/todo next` + `/drive` loop already
  in actual use.
- `ccxp/SKILL.md` Phase 2a (and its Mon/Fri cron-trigger table, around line
  582) still documents the Monday IPM as something the cron **always**
  invokes. That prose needs to change to match the decision, or every future
  reader re-discovers the same dead-ceremony confusion T20260924-252293 had
  to grill through.

## Done when

- `ccxp/SKILL.md` Phase 2a describes the Monday budget-cut ceremony as
  **optional/ad-hoc** — callable via `/ipm` directly for a deliberate
  iteration re-plan (e.g. in a repo with a configured GH Project board) —
  not as a step the cron unconditionally runs every Monday.
- The Mon/Fri cron-trigger table (`ccxp/SKILL.md` around line 685) is updated
  to reflect that Monday no longer has a mandatory "Run `/ipm`" entry.
- `ipm/SKILL.md`'s own framing (it currently says "`/ccxp` Phase 2a owns the
  Monday cron trigger") is reconciled with the new optional/ad-hoc framing.
- Cross-check: does this change anything about `/incept`'s pre-IPM design
  pass wording, since that pass is described as feeding into the (now
  optional) Monday cut?

## Closed (2026-10-08)

- Folded into a broader pass (prompted by a direct ask to drop `/ipm`'s
  Tier 1/2/3 partition — see T20260924-252293's note that `/ccxp` Phase 2a
  was expected to simplify to "take the top N queue entries that fit the
  budget") that also covered T20261002-245216 and T20261002-359869.
- `ccxp/SKILL.md` Phase 2a rewritten to describe the Monday IPM as
  optional/ad-hoc, not auto-invoked by `/ccxp` in either cron or
  interactive mode (frontmatter description, the intro paragraph, the
  "Cron mode vs. interactive mode" section, the XP Practices Mapping
  "Planning game" row, the day-of-week cron table, "Cron integration", and
  the "Cron does rituals" bullet all updated to match).
- `ipm/SKILL.md`'s own framing ("`/ccxp` Phase 2a owns the Monday cron
  trigger") reconciled — now states it's an optional, ad-hoc tool not
  invoked by `/ccxp`'s cron.
- `/incept`'s pre-IPM design-pass wording needed no change (grepped for
  `Monday`/`budget-cut`/`Tier` in `incept/SKILL.md` — none present).
