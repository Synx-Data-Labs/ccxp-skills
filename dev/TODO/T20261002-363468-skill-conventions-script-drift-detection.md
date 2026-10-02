---
status: Open
scheduled: 2026-10-12
estimation: 2
source: follow-up from T20260924-159109 (skill-to-app design)
related: T20260924-159109, skill-conventions §9
---

# T20261002-363468: Detect drift between a bundled `scripts/` helper and the SKILL.md prose it replaced

## Problem

- `skill-conventions/SKILL.md` §9 ("Deterministic logic → bundled scripts")
  requires a behavior-parity test **before** a script replaces SKILL.md
  prose, but nothing re-checks parity **after** — if a later edit changes
  the SKILL.md workflow step's documented behavior without updating the
  script it delegates to (or vice versa), the two silently diverge and
  nothing catches it.
- `skill_score.py`'s `untested_scripts()` check
  (`skill-conventions/scripts/skill_score.py:109`) verifies a script *has*
  a test, not that the SKILL.md prose and the script still agree on what
  that test should assert.

## Context

- Surfaced during T20260924-159109's design research — no existing check
  does staleness/drift comparison between a `scripts/` file and the
  SKILL.md section that invokes it.
- One real precedent for *realized* drift (not just theoretical risk):
  `dev/JOURNAL/2026-09-22-T20260914-359646-todo-next-as-local-script.md`
  documents function names diverging between the design doc and the
  shipped script during that very port.

## Scope (to resolve during design)

- Cheapest plausible check: a lint that flags a `scripts/*.sh`/`*.py` file
  whose git history shows it changed without the corresponding SKILL.md
  section's heading/anchor changing in the same commit (or vice versa) —
  needs a way to associate a script file with "the SKILL.md section that
  invokes it" (naming convention? an explicit marker comment?).
- Alternative: rely on §5's existing test suite catching behavioral drift
  functionally, and only add a doc-side nudge (e.g. a comment convention
  in the script pointing back at the SKILL.md section) rather than new
  tooling — cheaper, weaker guarantee.
- Out of scope: don't over-build a generic "doc/code sync" framework for a
  handful of current instances (4 skills use §9 today).

## Test plan

- [ ] Design doc picks one approach and states why (lint vs. convention-only).
- [ ] If a lint: a bats/unit test proves it fires on a synthetic drift case
      and stays silent on a normal co-edit.

## Done criteria

- [ ] Design section above resolved into a concrete Solution.
- [ ] Decision recorded even if the conclusion is "convention-only, no new
      tooling" — a deliberate no-build is a valid outcome here too.
