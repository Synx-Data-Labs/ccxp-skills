---
status: Open
scheduled: 2026-10-12
estimation: 8
source: split from T20260928-101526
related: [T20260928-101526]
description: Concision pass - ccxp, drive, retro, address-pr to >= 70
---

# T20261010-326861: Concision pass: ccxp, drive, retro, address-pr to >= 70

## Problem

- **Type**: chore
- `ccxp` (90 KB), `drive` (66 KB), `retro` (42 KB), `address-pr` (33 KB) score 53-61; 173 task-ID changelog asides; restated other-skill behavior has drifted (README §2, §3).
- Done looks like: changelog asides moved to JOURNAL, restated algorithms replaced by "run X, apply this judgment", paraphrases of other skills replaced by phase-anchor cites, each of the four >= 70, baseline re-locked with `skill_score.py --write-baseline`.

## Solution

- One skill per PR, re-score after each; start with `drive`, then `address-pr`, `retro`, `ccxp` (split per T20260923-584914).

## Test plan

- [ ] `skill_score.py --check dev/quality/skill-scores.json` passes; no skill < 70.

## Done criteria

- [ ] The four skills >= 70 and the baseline re-locked.
