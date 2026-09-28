---
status: Done
estimation: 2h
source: this conversation, 2026-09-12 — user asked to bring the Hermes grill-me skill into the ccxp suite
scheduled: 2026-09-07
related: T20260610-248248
description: Add /grill-me to the suite and make /ccxp Phase 2a.3 delegate the pre-IPM design pass to it
---

# T20260912-279229: `/ccxp` Phase 2a.3 delegates the pre-IPM design pass to a new `/grill-me` skill

## Problem

- **Type**: feature
- `/ccxp` Phase 2a.3 (pre-IPM design pass) says "write a Design section —
  scope, dependencies, unknowns, decisions" but gives no procedure for
  *eliciting* those from the human — in practice the agent fills the
  section itself and the human rubber-stamps it, which defeats the
  interactive-only rationale of the step.
- The Hermes `grill-me` skill (Rafael Zendron + Matt Pocock's `grilling`)
  has exactly the missing procedure: frontier-round adversarial
  questioning until nothing is silently assumed. It is Hermes-only and
  not shaped for this suite (no task-file output, no lifecycle hooks).
- Done looks like: a `grill-me/` skill in this repo following
  `/skill-conventions`, and 2a.3 rewritten to call it, with claim/status/
  estimation bookkeeping unchanged.

## Design

- **New `grill-me/SKILL.md`** — `Use when…` trigger, `argument-hint:
  "[task-id | free-text plan]"`, dual-invocable.
  - Frontier rounds + synthesis carried over intact from the source.
  - Suite deltas: task-id mode reads/writes `dev/TODO/T<id>-*.md` (Design
    section, `### Test Plan`, `estimation:` revision in the exact
    `Estimation revised from {old} to {new}: {reason}` shape `/retro`
    grades on); never touches `status:`/`claimed_by:`/`scheduled:`; leaves
    edits uncommitted for the caller.
- **`/ccxp` 2a.3** — step 1 becomes `/grill-me T<id>`; steps 2–5 keep
  their numbering (escalate-and-skip, estimate check, claim + status
  correction, no re-grill for Tier 1) so existing cross-refs
  (T20260610-248248, the 2a.2 cron filter) stay valid.
- **Out of scope**: `/drive` Phase 2 (has `/design-score` as its gate;
  could call `/grill-me` too — separate task if wanted); Hermes-side
  install of this suite.

### Test Plan

- Prose-only skill — no BATS per `/skill-conventions` §5.
- `lint-docs.sh --fix` + `lint_tasks.py --changed` clean on the touched
  files; `Markdown Lint` CI green.
- Manual: in a consumer repo, run `/grill-me T<id>` on an `Open` task and
  confirm it stops for answers each round, then writes only the Design
  section + estimation.

## Closed (2026-09-14)

- Shipped directly to `main` in commit `22070b9` (2026-09-12,
  "feat(grill-me): add /grill-me and make /ccxp 2a.3 delegate the pre-IPM
  design pass to it") — no PR trail found for this commit; landed via a
  direct-to-main workflow rather than the usual claim→PR→close cycle,
  which is why the task file itself was never flipped to `Done` at the
  time.
- Caught and closed by `/todo sweep` (2026-09-14, Phase 3 pruning) —
  "already done" signal: `grill-me/SKILL.md` exists, `ccxp/SKILL.md`
  Phase 2a.3 is rewired to call `/grill-me T<id>` exactly per this task's
  Design section, and `README.md` carries the skill table row. All three
  match the commit's own message and this task's "Done looks like"
  criteria verbatim.
- All Done criteria met: `grill-me/SKILL.md` shipped, `ccxp/SKILL.md`
  2a.3 rewired, task-file lifecycle bookkeeping (claim/status/estimation)
  left untouched by the skill as designed.
- No follow-up tasks filed.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — prose-only skill, no
  BATS per `/skill-conventions` §5.
- Verification (`superpowers:verification-before-completion`): yes (at
  close time, via `/todo sweep`) — confirmed `grill-me/SKILL.md`,
  `ccxp/SKILL.md`'s Phase 2a.3 wiring, and `README.md`'s skill-table row
  all exist on `main` before closing, rather than trusting the commit
  message alone.
- Systematic debugging (`superpowers:systematic-debugging`): no.
- Receiving code review (`superpowers:receiving-code-review`): unknown —
  no PR trail found for commit `22070b9`, so whether it went through
  review at implementation time is not recorded here.
