---
status: Design
estimation: 1d
source: conversation with @shine, 2026-09-23
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260923-584914: Extract /ccxp's Monday IPM ritual into a standalone /ipm skill

## TLDR

- **Type**: feature
- **Problem**: the Monday IPM ritual (2a.0–2a.6, ~300 lines) is inlined in
  `ccxp/SKILL.md` and only reachable through the full `/ccxp` orchestrator —
  no way to re-run iteration planning ad hoc mid-week.
- **Solution**: move 2a.0–2a.6 verbatim into a new no-arg `ipm/SKILL.md`
  (mirrors `/retro`'s precedent); `/ccxp` Phase 2a shrinks to a Monday
  trigger check + `Run /ipm` (mirrors how Phase 2b already calls `/retro`).
  The day-of-week gate stays in `/ccxp`, not `/ipm`, so `/ipm` is callable
  any day.

## Problem

- **Type**: feature
- `/ccxp/SKILL.md` inlines the entire Monday Iteration Planning Meeting
  ritual as Phase 2a, sub-phased 2a.0 through 2a.6:
  - `ccxp/SKILL.md:582` — 2a.0 Capture this IPM's Scheduled date
  - `ccxp/SKILL.md:597` — 2a.0.1 Sweep stale tasks before scoping
  - `ccxp/SKILL.md:622` — 2a.1 Carry over WIP (Tier 1)
  - `ccxp/SKILL.md:636` — 2a.1.5 Seed carry-over candidates
  - `ccxp/SKILL.md:642` — 2a.2 Pick candidates (Tier 2)
  - `ccxp/SKILL.md:650` — 2a.3 Pre-IPM design pass (interactive only,
    calls `/incept`)
  - `ccxp/SKILL.md:682` — 2a.4 Budget cut
  - `ccxp/SKILL.md:696` — 2a.5 Write ipm-weekly.md + tag Scheduled
  - `ccxp/SKILL.md:816` — 2a.5a Drain previous iteration (HARD GATE)
  - `ccxp/SKILL.md:847` — 2a.5b Update ROADMAP doc (cross-repo)
  - `ccxp/SKILL.md:877` — 2a.6 Slack the focus
- This ritual is only reachable through the full daily/weekly `/ccxp`
  orchestrator (standup → IPM → focus → retro). There's no way to
  re-run iteration planning ad hoc mid-week — e.g. to re-scope tasks
  after a design changes, or re-budget-cut after a priority shift —
  without invoking the whole cron-oriented loop.
- **Done when**: a standalone `/ipm` skill exists covering the 2a.0–2a.6
  logic (cron-mode vs. interactive-mode branching, the 2a.5a hard gate,
  the 2a.5b cross-repo ROADMAP sync, Slack notification all preserved),
  and `/ccxp` Phase 2a is reduced to a call into `/ipm` instead of
  inlining the logic.

## Context

- Companion task T20260923-986928 (rename `/grill-me` to `/incept`,
  vendor `grilling`'s mechanics) landed 2026-09-23: `/ipm`'s 2a.3 call
  site should reference `/incept`, not `/grill-me` — `ccxp/SKILL.md`
  Phase 2a.3 (the section this task extracts from) was updated to
  `/incept` in that same PR, so carry that name forward when writing
  the standalone `/ipm` skill rather than re-copying `/grill-me`.
- Related to T20260922-201976 only in that this session parked driving
  it mid-`/drive` Phase 1 to make room for this planning conversation —
  the two tasks are otherwise unrelated in content.
- `retro/SKILL.md` already establishes the target shape: a standalone,
  no-arg skill (`argument-hint` unset/empty) that `/ccxp` Phase 2b calls
  with a one-line `Run /retro` plus a bullet list of what it does
  (`ccxp/SKILL.md:895-905`) — Phase 2a should end up looking the same.
- Every script path the extracted section references
  (`<skills-root>/_ipm/*.sh`, `_session/task_claim.sh`,
  `_session/status.sh`, `_taskid/url.sh`, `ccxp/scripts/update-roadmap.sh`)
  is resolved relative to the repo root already, not to `ccxp/`'s own
  directory — moving the prose to `ipm/SKILL.md` changes nothing about
  those paths.
- Per Phase 3.0's docs/code classifier, this task is **docs-class**
  (`*.md` changes only) — TDD is skipped; verification is markdown
  lint + a read-through, not BATS.

## Solution

- **New skill**: `ipm/SKILL.md` at the repo root, alongside `retro/`,
  `incept/`, `stage/`. Frontmatter: `name: ipm`,
  `argument-hint` unset (no-arg, like `/retro`), description covering
  both "user explicitly asks to run/re-run iteration planning" and
  "`/ccxp` Phase 2a calls into this."
- **Content moved verbatim**: `ccxp/SKILL.md:582-889` (2a.0 through 2a.6,
  including the 2a.5a hard gate and 2a.5b cross-repo ROADMAP sync)
  becomes `/ipm`'s own Workflow section, unedited apart from heading
  renumbering (`#### 2a.0 …` → `#### 0 …`, etc. — see alternatives below).
- **Mode branching preserved as-is**: `/ipm` reads `CCXP_CRON_MODE`
  directly from the environment (already inherited by any skill
  invocation in the same session — no plumbing needed), exactly as the
  inlined logic does today.
- **Day-of-week gate stays in `/ccxp`**: the "only Mondays" trigger prose
  (`ccxp/SKILL.md:574-580`) stays in `/ccxp` Phase 2a, which becomes:
  check the trigger, and if true, `Run /ipm`. `/ipm` itself has no day
  check, so a human can invoke it ad hoc any day — the task's motivating
  use case.
- **`ccxp/SKILL.md` Phase 2a shrinks** to the same shape Phase 2b
  (`ccxp/SKILL.md:891-914`) already has: trigger condition + "Run `/ipm`"
  + a short bullet list of what it does + a report line.
- **Unchanged**: the "Cron mode vs. interactive mode" doc section
  (`ccxp/SKILL.md:16-49`), the "Day-of-week behavior" table
  (`ccxp/SKILL.md:968-981`), and Phase 3 — they reference the IPM but
  aren't part of the ritual itself, and none of their prose needs to move.

**Alternatives considered and rejected**:

- *Keep the `2a.N` numbering inside `/ipm`* — rejected: the `2a.` prefix
  is `/ccxp`'s own phase numbering (Phase 2a of its Workflow); inside a
  standalone `/ipm` skill it's meaningless context a reader has to decode.
  Renumber to plain `0`–`6` (`2a.5a`/`2a.5b` → `5a`/`5b`) inside `/ipm`.
- *Give `/ipm` a `--cron`/`--interactive` override argument* — rejected
  (asked and confirmed with the maintainer): adds an argument surface and
  parsing block the current inlined logic doesn't have; `CCXP_CRON_MODE`
  read straight from the environment is simpler and matches how the logic
  already works today.
- *Have `/ipm` also enforce the Monday-only gate itself (with a force
  flag for ad hoc use)* — rejected (asked and confirmed): the caller
  (`/ccxp`) already needs the trigger check to decide *whether* to
  invoke `/ipm` at all; duplicating it inside `/ipm` would require a
  bypass flag for the exact ad-hoc-invocation use case this task exists
  to enable. Caller-only keeps `/ipm` itself unconditional.

## Test plan

- [ ] `ccxp/SKILL.md:582-889` diffed byte-for-byte against the new
      `ipm/SKILL.md` Workflow section before deleting it from
      `ccxp/SKILL.md` (apart from the `2a.N` → plain-number renumbering) —
      confirms a lossless move, not a rewrite.
- [ ] Markdown-lint CI check passes on both `ipm/SKILL.md` and the edited
      `ccxp/SKILL.md`.
- [ ] Read-through: every cross-reference from the moved section
      (`/incept`, `/todo next`, `/stage`, `_ipm/*.sh`, `_session/*.sh`,
      `_taskid/url.sh`, `ROADMAP_TARGET_REPO`, `ccxp/scripts/update-roadmap.sh`)
      still resolves correctly read from `ipm/SKILL.md`'s new location.
- [ ] `ccxp/SKILL.md`'s new Phase 2a (trigger + `Run /ipm` + bullets)
      read side-by-side with Phase 2b (`ccxp/SKILL.md:891-914`) for shape
      parity.
- [ ] `repo-conventions` skill-conventions check (if any) — confirm
      `ipm/SKILL.md`'s frontmatter matches the `retro`/`incept`/`stage`
      pattern (`name`, `description`, `disable-model-invocation: false`,
      no `argument-hint`).

## Done criteria

- [ ] `ipm/SKILL.md` exists and contains the full 2a.0–2a.6 logic
      (cron/interactive branching, the 2a.5a hard gate, the 2a.5b
      cross-repo ROADMAP sync, Slack notification) — verified by the
      byte-for-byte diff test-plan item above.
- [ ] `ccxp/SKILL.md` Phase 2a is reduced to a trigger check + call into
      `/ipm` — verified by reading the merged `ccxp/SKILL.md` diff.
- [ ] No other section of `ccxp/SKILL.md` changed beyond the Phase 2a
      body and (if needed) the `/ipm` skill's own doc-lint fixes —
      verified by the merged PR's diff scope.
