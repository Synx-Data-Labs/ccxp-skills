---
status: Open
scheduled: 2026-10-12
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
