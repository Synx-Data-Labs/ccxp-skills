---
status: "Blocked by T20260923-584914 — PR #132 still open, unmerged"
scheduled: 2026-09-21
estimation: 1h
source: discovered driving T20260923-584914, 2026-09-23
related: T20260923-584914
claimed_by:
claimed_role:
---

# T20260923-553033: Sweep repo-wide stale `2a.N` references left after the `/ipm` extraction

## Problem

- **Type**: bug (doc drift)
- T20260923-584914 (design merged; **implementation [PR #132](https://github.com/Synx-Data-Labs/ccxp-skills/pull/132) still open,
  unmerged as of 2026-09-24**) extracts `/ccxp`'s inlined Monday IPM
  ritual (`2a.0`–`2a.6`) into a standalone `ipm/SKILL.md`, renumbering the
  sub-phases to plain `0`–`6` (`5a`/`5b`). That task's own reference
  sweep is scoped — by its design's Solution section — to
  `` grep -n '2a\.[0-9]' ccxp/SKILL.md `` only: 9 lines inside that one
  file, to be fixed when #132 merges.
- An independent review of the (still-open) implementation [PR #132](https://github.com/Synx-Data-Labs/ccxp-skills/pull/132) ran
  the same grep **repo-wide** and found the old `Phase 2a.N` numbering
  cited, as if current, in several *other* live skill files (not just
  historical `dev/JOURNAL/` records, which are correctly frozen and out
  of scope) — **this task cannot execute until #132 merges** (its own
  `ccxp/SKILL.md` fix would otherwise conflict with, or be overwritten
  by, #132's landing):
  - `incept/SKILL.md` — frontmatter `description`, plus lines 19, 106,
    109, 119, 127 (`` /ccxp Phase 2a.3 ``, `` /ccxp 2a.3 step 3/4 ``)
  - `retro/SKILL.md:53` — `` set by ccxp Phase 2a.5 ``
  - `retro/SKILL.md:529` — `` ccxp/SKILL.md Phase 1.4 / 2a.6 ``
  - `skill-conventions/SKILL.md:54` — cites `Phase 2a.5` as a worked
    example of a "stable anchor" (ironic, since it's now a dangling one)
  - `lifecycle.md:50,90,111,115` — `` /ccxp Phase 2a.5 ``, `` Phase
    2a.3 ``, `` Phase 2a.1.5 ``
  - `README.md:74,107` — `` ccxp Phase 2a.5b ``, `` /ccxp Phase 2a.3 ``
  - `_session/README.md:86,107` — `` Phase 2a.3 ``
  - `glossary.md:21` — `` /ccxp Phase 2a.5 ``
- None of these are functionally broken (nothing dereferences a literal
  markdown anchor), but they're now factually wrong pointers — a reader
  following `incept/SKILL.md`'s own description ("`/ccxp` Phase 2a.3
  runs a pre-IPM design pass") to find that logic in `ccxp/SKILL.md`
  won't find it there anymore; it's `ipm/SKILL.md` step 3.
- **Done when**: every live (non-`dev/JOURNAL/`) skill/doc file's
  `2a.N` / `Phase 2a.N` reference either (a) is updated to point at
  `/ipm`'s new plain-number step, or (b) is a deliberately-kept
  historical annotation (same pattern as `ccxp/SKILL.md:121`), noted as
  such inline.

## Context

- Low urgency — nothing is mechanically broken, this is pointer
  staleness a human would notice while reading, not a functional bug.
- `dev/JOURNAL/*.md` entries are excluded by design — they're frozen
  historical records of what was true when written; rewriting them
  would falsify the record. Only live/current docs are in scope.
- Scope is bigger than a single-file grep this time (8 files across the
  repo) — worth timeboxing to ~1h and doing as its own focused sweep
  rather than folding into another task's diff.
