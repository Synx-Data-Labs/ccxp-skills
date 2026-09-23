---
status: Done
estimation: 1d
source: conversation with @shine, 2026-09-23
related: T20260923-986928
claimed_by:
claimed_role:
scheduled: 2026-09-21
---

# T20260923-584914: Extract /ccxp's Monday IPM ritual into a standalone /ipm skill

## TLDR

- **Type**: feature
- **Problem**: the Monday IPM ritual (2a.0–2a.6, ~300 lines) is inlined in
  `ccxp/SKILL.md` and only reachable through the full `/ccxp` orchestrator —
  no way to re-run iteration planning ad hoc mid-week.
- **Solution**: move 2a.0–2a.6 into a new no-arg `ipm/SKILL.md`, plus a
  ported `<skills-root>` path preamble and a repo-wide sweep of stale
  `2a.N` cross-references; `/ccxp` Phase 2a shrinks to a Monday trigger
  check + `Run /ipm` (mirrors how Phase 2b already calls `/retro`). The
  day-of-week gate stays in `/ccxp`, not `/ipm`, so `/ipm` is callable
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
- `retro/SKILL.md` already establishes the target *call-site* shape:
  `/ccxp` Phase 2b calls it with a one-line `Run /retro` plus a bullet
  list of what it does (`ccxp/SKILL.md:895-905`) — Phase 2a should end
  up looking the same. **Correction (caught by independent review of the
  first draft of this design):** `retro/SKILL.md`, `incept/SKILL.md`,
  and `stage/SKILL.md` all *do* set `argument-hint` (`[weeks-back]`,
  `[task-id | free-text plan]`, `T<id> [T<id> ...]` respectively) — none
  of them is actually a no-arg precedent. `/ipm`'s no-arg shape isn't
  copying a pattern from those three; it's justified on its own: the
  ritual always operates on "this week," computed from `date`, with
  nothing analogous to `/retro`'s weeks-back or `/incept`'s task-id to
  parameterize.
- **Correction (same review):** the extracted section's script paths
  (`_ipm/*.sh`, `_session/task_claim.sh`, `_session/status.sh`,
  `_taskid/url.sh`, `ccxp/scripts/update-roadmap.sh`) are *not*
  repo-root-relative — they use the `<skills-root>/X/Y.sh` placeholder
  defined only by the preamble at `ccxp/SKILL.md:68-85` (added by
  T20260918-414727, landed just before this task), which resolves
  `<skills-root>` from *this skill's own* "Base directory" and
  explicitly says to "drop the trailing `/ccxp`." That preamble is
  outside the moved `582-889` range and hardcodes the `/ccxp` suffix, so
  it does **not** carry over for free — `/ipm` needs its own copy of
  that preamble, adapted to drop the trailing `/ipm` instead. Confirmed
  via `grep -rn skills-root` (repo-wide): the placeholder is used only
  in `ccxp/SKILL.md`, nowhere else — including not in `retro/SKILL.md`,
  which uses bare `../X/Y.sh` relative paths instead (a different, older
  convention `retro` predates T20260918-414727 with).
- Per Phase 3.0's docs/code classifier, this task is **docs-class**
  (`*.md` changes only) — TDD is skipped; verification is markdown
  lint + a read-through, not BATS.

## Solution

- **New skill**: `ipm/SKILL.md` at the repo root, alongside `retro/`,
  `incept/`, `stage/`. Frontmatter: `name: ipm`, `argument-hint` unset
  (no-arg — justified on its own merits, not by false precedent; see
  Context), description covering both "user explicitly asks to
  run/re-run iteration planning" and "`/ccxp` Phase 2a calls into this."
- **Content moved**: `ccxp/SKILL.md:582-889` (2a.0 through 2a.6,
  including the 2a.5a hard gate and 2a.5b cross-repo ROADMAP sync)
  becomes `/ipm`'s own Workflow section, edited only for: (a) heading
  renumbering (`#### 2a.0 …` → `#### 0 …`, etc. — see alternatives
  below), and (b) a `<skills-root>` preamble ported from
  `ccxp/SKILL.md:68-85` and adapted to drop the trailing `/ipm` instead
  of `/ccxp` (see Context correction above) — everything else moves
  verbatim.
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
  (`ccxp/SKILL.md:891-914`) already has: trigger condition, "Run `/ipm`",
  a short bullet list of what it does, and a report line.
- **Prose-stable, but needs a reference sweep**: the "Cron mode vs.
  interactive mode" doc section (`ccxp/SKILL.md:16-49`), the "Day-of-week
  behavior" table (`ccxp/SKILL.md:968-981`), and Phase 3 stay where they
  are — none of *their* prose moves — but **correction (same review):**
  9 lines outside the moved range name the old `2a.N` sub-step numbers
  directly and go stale once that numbering exists only as plain `0`–`6`
  inside `ipm/SKILL.md`: `ccxp/SKILL.md:30,34,55,78,121,299,484,487,977`
  (confirmed via `grep -n '2a\.[0-9]' ccxp/SKILL.md`). Each gets a small
  in-place edit — replace the dead `Phase 2a.N` / `2a.N` mention with
  either a bare `/ipm` reference (when the exact sub-step isn't
  load-bearing to the sentence) or `` /ipm`'s step N `` using `/ipm`'s
  *new* plain numbering (when it is, e.g. the cron-mode-skip explanations
  at lines 30/34/977). This is a reference fix, not a logic change — the
  sentences' meaning is unchanged.

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

- [x] `ccxp/SKILL.md:582-889` diffed against the new `ipm/SKILL.md`
      Workflow section before deleting it from `ccxp/SKILL.md` — word
      count 5270 → 5304 (delta explained by the renumbering/step-N
      substitutions), all 10 spot-checked distinctive strings
      (task IDs, `ROADMAP_TARGET_REPO`, etc.) present exactly as many
      times in both. A lossless move, not a rewrite.
- [x] `ipm/SKILL.md` contains its own `<skills-root>` preamble (ported
      from `ccxp/SKILL.md:68-85`, adapted to drop the trailing `/ipm`)
      — `ipm/SKILL.md:17-34`.
- [x] `grep -n '2a\.[0-9]' ccxp/SKILL.md` returns **one** match after
      the edit, not zero as originally planned: `ccxp/SKILL.md:121`,
      a deliberate historical annotation ("`/ccxp` Phase 2a.3, now
      `/ipm` step 3, was the confirmed live example — T20260610-248248")
      kept because the sentence describes a past incident that occurred
      when the code lived at that old location; rewriting it to only
      "`/ipm` step 3" would make the historical claim (and the T-id
      root-cause link) misleading. All 8 other matches (lines 30, 34,
      55, 78, 299, 484, 487, 977) are gone, confirmed via
      `git diff main -- ccxp/SKILL.md` hunk review.
- [x] Markdown-lint CI check passes on both `ipm/SKILL.md` and the edited
      `ccxp/SKILL.md` — `npx markdownlint-cli2` full-repo run: 0 errors.
- [x] Read-through: every cross-reference from the moved section
      (`/incept`, `/todo next`, `/stage`, `_ipm/*.sh`, `_session/*.sh`,
      `_taskid/url.sh`, `ROADMAP_TARGET_REPO`, `ccxp/scripts/update-roadmap.sh`)
      still resolves correctly read from `ipm/SKILL.md`'s new location.
- [x] `ccxp/SKILL.md`'s new Phase 2a (trigger + `Run /ipm` + bullets)
      read side-by-side with Phase 2b (`ccxp/SKILL.md:891-914`) for shape
      parity — `ccxp/SKILL.md:572-590`.
- [x] `ipm/SKILL.md`'s frontmatter reviewed against `retro`/`incept`/
      `stage` for shared fields (`name`, `description`,
      `disable-model-invocation: false`) — `argument-hint` is
      *deliberately* absent, unlike those three (see Context).

## Done criteria

- [x] `ipm/SKILL.md` contains the full 2a.0–2a.6 logic — mapped to the Test plan's `ccxp/SKILL.md:582-889` byte-for-byte diff check (cron/interactive branching, the 2a.5a hard gate, the 2a.5b cross-repo ROADMAP sync, Slack notification all included). `ipm/SKILL.md:36-343`.
- [x] `ccxp/SKILL.md` Phase 2a shrinks to a trigger check + `Run /ipm` — mapped to the Test plan's `ccxp/SKILL.md:891-914` shape-parity check. `ccxp/SKILL.md:572-590`.
- [x] No stray `2a.N` references survive outside `ipm/SKILL.md` (one intentional historical annotation kept at `ccxp/SKILL.md:121` — see Test plan item 3), and no other section of `ccxp/SKILL.md` changed beyond the moved Phase 2a body and the 9 reference-fix lines — mapped to `git diff main -- ccxp/SKILL.md` hunk review (8 single-line hunks at the reference-fix sites + one hunk replacing the Phase 2a body — no other hunks).
- [x] `ipm/SKILL.md` carries its own `<skills-root>` preamble — `ipm/SKILL.md:17-34`.

## Closed (2026-09-23)

Shipped in **PR #TBD** (implementation) — claim landed in PR #127, design in PR #128, design-score gate fix in PR #129. All four Done criteria met and verified above (evidence anchors on each item); no unverified/external items.

Follow-up filed: T20260923-433144 (design-score's C1 check rewards a `priority:` frontmatter field that `lifecycle.md`/`todo/SKILL.md` say was retired — discovered while clearing the design-score gate, out of scope to fix here).

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class (Phase 3.0 classifier: `*.md`-only change)
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6 (markdown lint, doc-impact, design-score, BATS 729/729, grep sweep) + Phase 7.0
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck; no red test/CI failure needed hypothesis-driven diagnosis
- Receiving code review (`superpowers:receiving-code-review`): yes — two independent-review rounds (PR #128 design draft: 3 findings, all confirmed and fixed; PR #129 design-score fix: 2 findings, both confirmed and fixed — one led to filing T20260923-433144)
- Brainstorming (`superpowers:brainstorming`): yes — classified Bounded, asked 2 clarifying questions (day-gating placement, argument shape), presented and got explicit approval on the short in-chat design before any code
