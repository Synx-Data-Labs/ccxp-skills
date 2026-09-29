---
status: Open
estimation: 1h
source: this conversation, 2026-09-28 — main branch CI check on `5d5e07f`
related: T20260923-584914
---

# T20260928-111470: `ipm` skill fails the skill-score ratchet CI check, main is red

## Problem

- **Type**: bug
- Main's `tests` workflow is failing on `5d5e07f` ("Merge
  replant/t20260923-584914: extract /ccxp Phase 2a into /ipm") — run
  `36504819110`, job `skill-quality` (`skill_score.py --check
  dev/quality/skill-scores.json`):

  ```
  ❌ ipm: 57 < 70
      invocation 2/5 (argument-hint + explicit disable-model-invocation)
      size 0/25 (37164 bytes (~9291 tokens), 339 lines)
      changelog_noise 0/10 (30 task-ID mentions (history belongs in dev/JOURNAL))
      prose_density 0/5 (10 paragraphs over 60 words)
  ```

- The newly split-out `ipm/SKILL.md` (from the `/ccxp` Phase 2a extraction)
  is too large, carries changelog-style task-ID history that belongs in
  `dev/JOURNAL/` instead, has overlong prose paragraphs, and is missing
  `argument-hint`/an explicit `disable-model-invocation` line.
- Done looks like: `ipm/SKILL.md` scores ≥ 70 on
  `skill-conventions/scripts/skill_score.py`, and the `tests` workflow is
  green on main again.

## Context

- `ipm/SKILL.md` — the file to trim.
- `skill-conventions/scripts/skill_score.py` — the scoring rubric (size,
  changelog_noise, prose_density, invocation checks).
- `dev/quality/skill-scores.json` — the ratchet baseline this check reads.
