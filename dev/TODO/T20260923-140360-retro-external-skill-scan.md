---
status: Open
estimation: 1d
---

# T20260923-140360: Add an external-skillset scan to /retro

## Problem

- **Type**: feature
- `/retro` Phase 4c (`retro/SKILL.md:373`) already grades *our own*
  skills weekly and drafts a bounded fix for the single worst offender
  — but it only ever looks inward at `ccxp-skills` itself. There's no
  step that looks at other installed/known marketplaces (e.g.
  `mattpocock-skills`, `superpowers`) to see whether one of them has
  already solved a problem we have, or does something leaner/better
  than our own equivalent skill.
- Concretely surfaced 2026-09-23: comparing `ccxp-skills:grill-me`
  against the newly-installed `mattpocock-skills:grilling` showed the
  same frontier-round interview algorithm implemented two ways —
  ours with heavier repo-specific wiring, Matt's leaner and portable.
  We only found this because a human happened to install the plugin
  and ask for a diff; nothing in the suite surfaces this kind of
  comparison on its own.
- **Done when**: `/retro` gains a new phase (e.g. `Phase 4e: External
  skillset scan`, sibling to `4c`/`4d`) that periodically compares our
  skills against other installed marketplaces' skills covering similar
  triggers, and reports (not auto-adopts) candidates worth a follow-up
  design pass — same "downgrade to a filed task when it needs real
  design" discipline `4c` step 3 already uses.

## Context

- Scope this as **report-only** for the first version — surface
  candidates as `Category: quality` action items (mirroring `4c` step
  3's "needs real design" downgrade path) rather than auto-drafting a
  PR. Auto-adopting behavior from an external, independently-versioned
  plugin is a materially different trust model than `4c`'s own-repo
  bounded-edit path, and deserves its own brainstorm before any
  auto-merge is on the table.
- Open design questions for whoever picks this up (deliberately left
  unresolved here, not this task's job to settle):
  - Which marketplaces count as "worth learning from" — all installed
    plugins, or an explicit allowlist?
  - Cadence — every retro, or a slower interval (monthly)?
  - How to diff "does something similar" without just re-reading every
    other skill's SKILL.md in full each run (cost/signal tradeoff).
- Companion task T20260923-986928 (rename `/grill-me` to `/incept`,
  vendor `grilling`'s mechanics) is the first concrete instance of "we
  learned from another skillset and vendored the useful part" — this
  task is about making that discovery repeatable instead of one-off/manual.
