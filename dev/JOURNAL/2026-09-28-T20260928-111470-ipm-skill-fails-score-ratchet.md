---
status: Done
estimation: 1h
source: this conversation, 2026-09-28 — main branch CI check on `5d5e07f`
related: T20260923-584914
claimed_by:
claimed_role:
scheduled: 2026-09-28
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

## Closed (2026-09-28)

- Shipped in [PR #166](https://github.com/Synx-Data-Labs/ccxp-skills/pull/166).
- Removed all 30 task-ID citations from `ipm/SKILL.md` (changelog_noise
  10/10 → was 0/10), broke all 10 over-60-word paragraphs into bullets
  (prose_density 5/5 → was 0/5), and condensed verbose passages to cut
  body size from ~37.5KB to ~32.7KB (still 0/25 on the size check — full
  marks would need an ~4x cut not attempted here; not required to clear
  the 70 baseline).
- New score: 72/100 (was 57), registered in `dev/quality/skill-scores.json`.
- `invocation` stayed at 2/5 — `ipm` takes no CLI arguments, so
  `argument-hint` was deliberately left unset rather than added
  dishonestly for points.
- Verified: `skill_score.py --check` passes (48/48 skills at/above
  baseline), `lint-docs.sh --fix` clean, `bats tests/` green, and main's
  post-merge `tests` + `Markdown Lint` runs both succeeded on `2cb891e`.
- No follow-up tasks filed — the size gap is cosmetic (score already
  clears baseline) and not worth a separate task.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class (SKILL.md prose edit)
- Verification (`superpowers:verification-before-completion`): yes — score/lint/bats checks before PR, plus an independent review agent dispatch in `/address-pr` §2.d
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck
- Receiving code review (`superpowers:receiving-code-review`): no — review was a clean bill, no pushback needed
