---
status: Open
scheduled: 2026-10-05
estimation: 2h
source: T20260914-412750 (research: learn from mattpocock/skills)
related: T20260914-412750
description: Scope whether ccxp-skills should adopt a maturity tier (promoted vs misc/in-progress/deprecated) so the shipped plugin bundle isn't every skill unconditionally
---

# T20260922-413132: Scope a skill-maturity tiering convention (promoted vs misc/in-progress/deprecated) for the ccxp-skills plugin bundle

## Problem

- `.claude-plugin/plugin.json`'s `"skills": "."` ships every skill in this
  repo unconditionally — there is no concept of a skill being immature,
  rarely-used, or deprecated-but-kept-for-reference that would exclude it
  from the default plugin install.
- `README.md`'s "Skills included" section already informally groups skills
  into categories (Task lifecycle & PR automation, Notification &
  integration, General-purpose utility, Cloudflare developer platform),
  but this is prose-only — it doesn't gate what actually ships, and there's
  no signal for "this one's still rough" vs "this one's battle-tested."
- `mattpocock/skills` solves this with physical bucket folders under
  `skills/`: `engineering/` and `productivity/` are **promoted** (shipped in
  the plugin, listed in the top-level `README.md`, get a human-facing docs
  page); `misc/`, `in-progress/`, and `deprecated/` are explicitly excluded
  from both the plugin manifest and the top-level README (`CLAUDE.md`'s own
  rule: "Skills in `misc/`, `in-progress/`, and `deprecated/` must not
  appear in either").

## Context

- Discovered via T20260914-412750's research pass. `ccxp-skills` currently
  has ~60 skills at the flat repo root (no bucket subdirectories) — several
  visibly still-settling ones exist in the current `dev/TODO/` backlog
  (e.g. skill-authoring cleanup tasks), suggesting some skills here would
  plausibly qualify as "in-progress" under this scheme today.
- This is a **scoping task**, not an implementation task — the estimation
  (2h) covers deciding *whether* and *how* to adopt tiering, not doing the
  migration itself (that would be a separate, larger follow-up once scoped).

## Solution

- Evaluate three shapes, cheapest first:
  1. **No physical move** — just add a `maturity: promoted|in-progress|misc`
     frontmatter-adjacent marker (or a dedicated `MATURITY.md` index) and
     teach `.claude-plugin/plugin.json`'s `skills` field (or a
     pre-publish filter step) to exclude non-promoted entries. Lowest
     migration cost, no directory churn.
  2. **Physical bucket folders**, mirroring `mattpocock/skills` exactly
     (`engineering/`, `productivity/`, `misc/`, `in-progress/`,
     `deprecated/`) — higher migration cost (every skill's directory moves,
     every cross-reference/path updates), but matches the source
     convention exactly and makes the tier visible in the filesystem, not
     just metadata.
  3. **Do nothing** — conclude the "everything ships" model is fine for an
     internal team plugin with a small, trusted user base, and the
     categorization README section is enough signal. Valid outcome if the
     scoping finds no real pain point (nobody has complained about plugin
     bloat or an unwanted skill firing).
- Whichever shape is chosen (including "do nothing"), record the decision
  and reasoning in this task's `## Closed` section — the deliverable of
  *this* task is the decision, not a migration.
- **Alternatives rejected**: none yet — this task's job is to consider them
  live during the scoping pass, not pre-reject before investigating.

## Test plan

- [ ] This task's `## Closed` section states one of the three shapes above
      (or a fourth, if scoping surfaces a better one) with reasoning —
      manual read-through test.
- [ ] If a shape other than "do nothing" is chosen, a follow-up
      implementation task is filed (`dev/TODO/T<id>-*.md`) with its own
      estimation, rather than folding the migration into this scoping task.

## Done criteria

- [ ] A maturity-tiering decision is recorded for `ccxp-skills` — see
      `## Closed` below, this task's own read-through test.
- [ ] Any resulting implementation work is filed as its own follow-up task,
      not implemented inline here — see `## Closed` for the filed task ID,
      or "do nothing, none filed" if that's the outcome.
