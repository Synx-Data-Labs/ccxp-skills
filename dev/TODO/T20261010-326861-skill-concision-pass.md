---
status: Design
scheduled: 2026-10-12
estimation: 8
source: split from T20260928-101526
related: [T20260928-101526]
description: Concision pass - ccxp, drive, retro, address-pr to >= 70
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
---

# T20261010-326861: Concision pass: ccxp, drive, retro, address-pr to >= 70

## TLDR

- **Type**: chore
- **Problem**: `ccxp`, `drive`, `retro`, `address-pr` score 54-61 (below the 70 new-skill floor); each is 33-72 KB with dozens of task-ID changelog asides.
- **Solution**: one PR per skill, order `drive`, `address-pr`, `retro`, `ccxp`: strip task-ID asides, break long paragraphs, cut restated other-skill behaviour; re-score after each; re-lock the baseline in the last PR.

## Problem

- Verified 2026-10-12 with `/opt/homebrew/bin/python3 skill-conventions/scripts/skill_score.py --repo . drive address-pr retro ccxp` (bare `python3` is killed here, exit 137):
  - `ccxp` 54, `drive` 60, `retro` 60, `address-pr` 61.
  - All four score 0/25 on size (bodies 33-72 KB vs the 8 KB full-marks line), 0-1/10 on changelog noise, 0/5 on prose density.
  - `ccxp` also loses 5/15 on one broken in-repo ref.
- Impact: every invocation loads 10-18k tokens of history the model does not need, and prose that restates other skills drifts (README section 2, section 3).

## Context

- Score formula: `skill-conventions/scripts/skill_score.py:130` (size linear 8-32 KB for 25 pts; noise = 10 minus task IDs beyond 2; prose = 5 minus paragraphs over 60 words).
- CI ratchet: `skill_score.py --check dev/quality/skill-scores.json`; a score may rise but never fall.
- Assumed: most changelog asides can be deleted without changing behaviour, since history already lives in `dev/JOURNAL/`.

## Solution

- Per skill, one PR each, in the order above:
  - Delete task-ID changelog asides; keep at most 2 IDs where an ID is the only pointer to a rule's rationale.
  - Break paragraphs over 60 words into bullets.
  - Replace restated algorithms of other skills with "run X" plus a phase-anchor cite.
  - Fix the `ccxp` broken ref.
  - Preserve every behavioural rule: wording removal, not a policy change.
- Reach: noise removal alone lifts `drive` and `address-pr` to 70; prose density and size cuts give margin (target >= 75).
- Re-score after each PR; the final PR runs `skill_score.py --write-baseline dev/quality/skill-scores.json`.
- Alternatives rejected:
  - One mega-PR for all four: unreviewable; the parent split already says one skill per PR.
  - Moving content into `references/` files to shrink the body: hides the same text from review; deferred to the parent task.

## Test plan

- [ ] After each skill PR: `/opt/homebrew/bin/python3 skill-conventions/scripts/skill_score.py --repo . <skill>` shows >= 70.
- [ ] `skill_score.py --repo . --check dev/quality/skill-scores.json` passes (no regression anywhere).
- [ ] `bats tests/` passes (some tests grep SKILL.md prose).
- [ ] Diff review per PR: no rule removed, only history and restatement.

## Done criteria

- [ ] `drive`, `address-pr`, `retro`, `ccxp` all >= 70, shown by `skill_score.py` output (`skill-conventions/scripts/skill_score.py:130`) in each PR.
- [ ] Baseline re-locked in the final PR (`dev/quality/skill-scores.json:1`): the four entries >= 70.
- [ ] CI `skill-quality` check green on every PR (PR #337 showed it running).

## Closed

- Pending: written at Phase 7 once all four PRs merge.

## Skills invoked

- Pending: filled at Phase 7.0.
