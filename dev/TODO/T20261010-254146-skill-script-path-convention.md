---
status: Open
scheduled: 2026-10-12
estimation: 5
source: split from T20260928-101526
related: [T20260928-101526]
description: One base-dir convention for skill script paths (consumer-repo exit 127)
---

# T20261010-254146: One base-dir convention for skill script paths (consumer-repo exit 127)

## Problem

- **Type**: bug
- `bash todo/scripts/todo-next.sh` exits 127 from a consumer repo; paths only resolve from the ccxp-skills root (README §1 `todo` row, `todo/SKILL.md:83,126`).
- `todo/evals/evals.json` case `next-skips-done-and-is-read-only` stays red until fixed.
- Done looks like: one rule in `skill-conventions` §9, applied to every skill calling `scripts/` or `_lib`, and `skill_eval.py todo --record` passes (>= 90%).

## Solution

- Pick the base-dir rule (candidate: resolve from the skill's own base directory, as the harness announces it), record it in §9, then sweep all skills.

## Test plan

- [ ] `skill_eval.py todo --record` passes from a consumer-repo fixture.

## Done criteria

- [ ] Convention documented in `skill-conventions` §9 and applied repo-wide.
