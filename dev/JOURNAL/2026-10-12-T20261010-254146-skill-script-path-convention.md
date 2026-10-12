---
status: Done
scheduled: 2026-10-12
estimation: 5
source: split from T20260928-101526
related: [T20260928-101526]
description: One base-dir convention for skill script paths (consumer-repo exit 127)
claimed_by:
claimed_role:
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

- [x] `skill_eval.py todo --record` passes from a consumer-repo fixture.

## Done criteria

- [x] Convention documented in `skill-conventions` §9 and applied repo-wide.

## Closed (2026-10-12)

- **Rule**: `skill-conventions` §9 "Script path rule" — reuse the existing `<skills-root>` placeholder (`ipm`/`ccxp`): `<skills-root>/<skill>/scripts/x.sh`, `<skills-root>/_lib/x.sh`; no repo-root-relative or cwd-relative (`../_gh/...`) paths.
- **Applied**: all command invocations in 29 SKILL.md files (about 150 `../` and repo-root occurrences); each skill carries a one-line `<skills-root>` definition under its H1. Markdown links to `../` files left as is.
- **Evidence**: `skill_eval.py todo` case `next-skips-done-and-is-read-only` 3/3 and `list-uses-script` 3/3 (was red). Overall todo eval 66.7% because `natural-language-trigger` is 0/3 — unrelated, not filed as a task (see note); the `--record` line was not committed since the suite is below 90%.
- **Not covered**: README/`_taskid`/`_slack` README examples (repo-root commands for humans, not skill steps); `lifecycle.md:142` dev command.
- **Follow-up**: `natural-language-trigger` eval failure left for a future task.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class
- Verification (`superpowers:verification-before-completion`): yes — eval run + unit tests, 3.6/7.0
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck
- Receiving code review (`superpowers:receiving-code-review`): no — see PR
