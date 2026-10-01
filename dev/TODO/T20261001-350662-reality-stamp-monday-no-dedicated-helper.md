---
status: Open
estimation: 1
source: this conversation, 2026-10-01 — caught by an independent PR review during T20260923-425414's journal-close
---

# T20261001-350662: `lifecycle.md`'s reality-stamp `scheduled:` Monday has no dedicated helper, inviting `stamp-scheduled.sh` misuse

## Problem

- `lifecycle.md`'s three reality-stamp cases (early-pickup re-stamp,
  empty-on-advance, Done-completion) all want **this calendar week's**
  Monday — e.g. "Done = completion-date Monday: ... set `scheduled:` to
  the Monday of the `yyyy-mm-dd` date prefix used in the JOURNAL filename."
  `lifecycle.md` describes this as a manual computation; no script
  implements it.
- `_ipm/stamp-scheduled.sh` looks like the obvious tool to reach for (it's
  cross-referenced by `/rca`, `/retro`, `/address-pr`, `/drive`), but its
  "current" mode's tier-3 fallback computes **next** week's Monday
  (`monday = this_week_monday + 7 days`), not this week's — correct for
  the "stage a newly-discovered dependency/follow-up into an iteration"
  use case every real call site in those four skills actually uses it
  for, but wrong for a reality-stamp.
- Confirmed live: used `stamp-scheduled.sh current` for T20260923-425414's
  Done-close and T20260924-366770's empty-on-advance stamp (Open→Design)
  this session — both got `2026-10-05` (next Monday) instead of the
  correct `2026-09-28` (this week's Monday, matching every other
  `dev/JOURNAL/*.md` file closed the same week). Caught by an independent
  review agent on [PR #198](https://github.com/Synx-Data-Labs/ccxp-skills/pull/198), cross-checked against sibling JOURNAL files as
  evidence; both instances were hand-corrected before merge.
- **Done looks like**: either (a) a small, explicit helper/mode (e.g.
  `stamp-scheduled.sh --this-week <file>`) that computes the current
  calendar week's Monday directly, with no tier fallback semantics
  borrowed from the iteration-staging use case, or (b) at minimum, a loud
  doc note on `stamp-scheduled.sh` itself warning it's the wrong tool for
  `lifecycle.md`'s reality-stamp cases, pointing at the manual computation
  instead.

## Context

- `lifecycle.md`'s "Iteration assignment" section, reality-stamp
  sub-bullets (Invariant paragraph + cases a/b/3).
- `_ipm/stamp-scheduled.sh`'s own docstring and tier-3 fallback comment
  ("next-Monday — computed from today: the Monday that starts next
  week").
- No existing call site in `rca/SKILL.md`, `retro/SKILL.md`,
  `drive/SKILL.md`, or `address-pr/SKILL.md` actually performs a
  reality-stamp with this script — they all stage new tasks (dependency →
  current iteration, follow-up → next iteration), which is a genuinely
  different, correctly-served operation. This is not a bug in their
  usage.
