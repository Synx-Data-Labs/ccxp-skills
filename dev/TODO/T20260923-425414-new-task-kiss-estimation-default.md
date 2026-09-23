---
status: Open
estimation: 1h
source: conversation with @shine, 2026-09-23
---

# T20260923-425414: Give `/new-task` a KISS default estimation instead of always asking

## Problem

- **Type**: chore
- `new-task/SKILL.md:45` lists `estimation` as a required field to gather,
  and `new-task/SKILL.md:54`'s "Never fabricate ... an estimation ... ask
  instead of guessing" rule means the skill asks the user every single
  time, with no default.
- Concretely felt this session (2026-09-23): filing 4 tasks back-to-back
  (T20260923-584914, T20260923-140360, T20260923-292618,
  T20260923-986928) meant 4 separate estimation prompts in one sitting —
  friction the maintainer explicitly flagged as violating KISS.
- Maintainer's proposed resolution (this conversation): pick a sensible
  default estimation automatically instead of asking, and rely on
  `/incept` (the design-interview skill, T20260923-986928) or a later
  re-estimate to correct it if the default turns out wrong — mirroring
  how `/incept`'s own record step already revises `estimation:` with a
  logged reason when an interview changes it.
- **Done when**: `/new-task` no longer blocks task creation on an
  estimation question by default; a sensible default is picked instead,
  and the door stays open to revise it later (via `/incept` or a direct
  edit) rather than forcing accuracy up front.

## Context

- `repo-conventions/templates/task.md:3` already ships `estimation: 2h`
  as its own example/placeholder default — a natural existing anchor for
  whatever default value gets chosen, rather than inventing a new one.
- Applying this task's own principle to itself: this task file was
  itself filed with a self-picked `1h` estimate (a small, well-scoped
  prose edit to one `SKILL.md` file) rather than an asked question — a
  live example of the behavior being proposed, not just a description of
  it.
- Design left to whoever picks this up (deliberately not resolved here,
  consistent with "iterate later" rather than over-designing now):
  - A single fixed default (e.g. `2h` matching the template) vs. a
    per-`Type` default (e.g. `chore` → `30m`, `feature` → `1d`).
  - Whether to still ask when the user's one-line description already
    signals unusual size (e.g. explicitly says "quick fix" or "big
    project").
