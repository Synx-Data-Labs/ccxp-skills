---
status: Open
estimation: 1
source: owner request 2026-11-24 (decision d155), job 1525
related: [T20261124-147908]
description: Retro persona review gets a script-or-hook bucket, one task per conversion with dedupe, and an enforced-by field on decisions
---

# T20261124-607534: Retro distill pipeline: decisions to persona to skill to script

## Problem

- **Type**: feature
- Owner: "in our /retro do we review list of decisions, and then follow the distill pipeline, e.g. decisions -> agent persona -> skill -> scripts?" then "go".
- Phase 4f has no bucket for what a script, gate, lint or hook can enforce, and proposals name no target stage or repo.
- Conversions are proposed in the report only; nothing files them as tasks, so they can be filed twice or forgotten.
- Nothing records that a decision is already enforced in code, so retire candidates are never surfaced.
- Done when:
  - `persona-review.sh bucket` has `script-or-hook` and prints target stage and repo per row.
  - `persona-review.sh tasks` lists proposed conversions with a dedupe check against open tasks naming the decision ref.
  - `ledger.sh decision enforce <ref> <path or task>` stores `enforced_by`, shown in `decision list` and the `.md`.
  - `persona-review.sh retire-enforced [--apply]` retires a decision itself (owner update: no approval step) when `enforced-by` is a merged PR or a file on origin/main and a task names the ref; open, missing or bare-task targets stay pending; retro logs each retirement.
  - `retro/SKILL.md` Phase 4f and `agent-pairing/decisions.md` updated, bats green, SKILL.md score kept.
