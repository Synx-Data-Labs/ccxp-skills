---
status: Done
estimation: 3
source: conversation with @shine, 2026-09-23
claimed_by:
claimed_role:
scheduled: 2026-09-28
---

# T20260923-292618: Survey retiring the `superpowers` plugin dependency

## TLDR

- **Type**: research
- **Problem**: `ccxp-skills` hard-gates on `superpowers:*` skills at 8+
  call sites across 8 `SKILL.md` files; maintainer wants to lean more on
  native `ccxp-skills` mechanisms and `mattpocock/skills` equivalents.
- **Solution**: inventoried every call site (confirmed against current
  `main`, 2026-10-01 — several line numbers drifted since filing), checked
  `mattpocock/skills` for real equivalents (not just name-similarity), and
  filed 3 follow-ups for the swaps actually worth doing: T20261001-289904
  (TDD), T20261001-334141 (systematic-debugging), T20261001-995405 (scope
  the verification-before-completion gate, no ready replacement exists).

## Problem

- **Type**: research
- `ccxp-skills` currently calls `superpowers:*` skills as load-bearing gates
  across at least 8 `SKILL.md` files, not just as optional flavor:
  - `drive/SKILL.md:228` — `superpowers:test-driven-development` (hard
    gate, code-class Phase 3.0)
  - `drive/SKILL.md:355` — `superpowers:systematic-debugging` (Phase 3.5)
  - `drive/SKILL.md:359`, `:496` — `superpowers:verification-before-completion`
    (Phase 3.6 and Phase 7.0, both hard gates)
  - `drive/SKILL.md:505-508` — the "Skills invoked" audit block names all
    four of the above by exact string — this is what `/retro` Phase 4c
    (`retro/SKILL.md:379`) greps JOURNAL entries for to grade skill
    compliance
  - `address-pr/SKILL.md:161` — `superpowers:verification-before-completion`
    (pre-gate, every loop iteration)
  - `address-pr/SKILL.md:257` — `superpowers:receiving-code-review`
  - `retro/SKILL.md:380` — `superpowers:writing-skills` (authoring rubric,
    optional/best-effort already)
  - `retro/SKILL.md:388` — `superpowers:brainstorming` (design-pass
    hand-off for "needs real design" downgrades)
  - `new-task/SKILL.md:33`, `skill-conventions/SKILL.md:10,66,80`,
    `repo-conventions/SKILL.md:107`, `spinup/SKILL.md:12,27,40` — softer
    references (analogy, deferred-to-for-generic-authoring)
  - `incept/SKILL.md:134` — one scope-carve-out mention
    (`superpowers:requesting-code-review`; renamed from `grill-me` by
    T20260923-986928, 2026-09-23)
- Maintainer preference (this conversation, 2026-09-23): rely more on
  `ccxp-skills`' own XP-flavored conventions (design-score gate,
  quality-probe, the `/incept` interview skill once it lands) plus
  `mattpocock-skills`' leaner equivalents (`tdd`, `diagnosing-bugs`,
  `code-review`), instead of the heavier generic `superpowers` skills —
  on the view that some of this is already duplicated by
  `ccxp-skills`-native mechanisms.
- **Done when**: every superpowers call site above is inventoried with a
  proposed disposition — keep, replace with a named `mattpocock-skills`
  equivalent, replace with vendored/native `ccxp-skills` prose, or drop
  outright — and each concrete swap worth doing is filed as its own
  follow-up task (mirrors the shape of
  `dev/JOURNAL/2026-09-22-T20260914-412750-learn-from-mattpocock-skills.md`,
  which surveyed `mattpocock/skills` the same way before filing
  follow-ups, not implementing inline).

## Context

- This is a **survey/scoping task, not an implementation task** — same
  shape as T20260914-412750. Do not swap code in this task; the payoff is
  a prioritized, evidence-backed list of follow-up tasks.
- Explicitly out of scope for this task (identified 2026-09-23, do not
  re-litigate here): whether `/incept` itself should vendor
  `mattpocock-skills:grilling` — already decided independently
  (see the `/incept` task filed the same day).
- Key risk to call out in the survey, not resolve: `/retro` Phase 4c's
  compliance grading (`retro/SKILL.md:379`) greps JOURNAL "Skills
  invoked" blocks for the **exact strings** `superpowers:test-driven-development`,
  `superpowers:systematic-debugging`, `superpowers:verification-before-completion`,
  `superpowers:receiving-code-review`. Any rename/replacement must either
  update that grep in the same follow-up, or the historical JOURNAL
  entries and the grading pipeline silently diverge.
- Hard call sites (`verification-before-completion`, TDD) carry more risk
  than soft/analogy references — weight the survey's effort accordingly
  rather than treating all 8 files as equal-sized work.

## Solution

- Re-grep every call site against current `main` (lines drift between
  filing and working a task — confirm, don't trust the filed line numbers).
- For each site, check whether a named `mattpocock-skills` equivalent
  actually matches the function (not just the name) by fetching its real
  `SKILL.md` content via `gh api`, not assuming from the skill name alone.
- Classify each site's disposition: **replace via vendoring** (a real
  equivalent exists and is worth porting), **keep** (no equivalent, or the
  reference is low-risk/soft), or **scope further** (high-value but no
  ready replacement — needs its own research pass).
- File one follow-up task per concrete swap worth doing; do not file a
  follow-up for "keep" dispositions.
- **Alternatives rejected**:
  - *Implement the swaps inline in this task* — rejected: this is a
    survey/scoping task per its own Done-when; each swap is independently
    sized follow-up work (same reasoning as T20260914-412750).
  - *Treat "mattpocock has a skill with a similar name" as sufficient
    evidence of equivalence* — rejected after actually reading
    `mattpocock/skills`' `code-review/SKILL.md`: it's a reviewer-side
    diff-review tool, not a match for `superpowers:receiving-code-review`'s
    function (processing feedback as the author) despite the name overlap.
    Found by fetching the real content, not just scanning the file tree.

## Test plan

- [x] Every call site re-confirmed against current `main` with `grep -n`
      (see Research findings table) — not just copied from the filed task
- [x] Each `mattpocock-skills` candidate's actual `SKILL.md` content
      fetched and read (`gh api repos/mattpocock/skills/contents/...`),
      not assumed from name — see Research findings
- [x] A disposition recorded for every site in the Problem section's
      inventory
- [x] Each disposition needing a concrete swap filed as its own task —
      see `## Closed`

## Research findings

**Re-confirmed call-site inventory** (current `main`, 2026-10-01 —
`grep -n "superpowers:" <file>` per file; line numbers drifted from the
2026-09-23 filing since other edits landed in between):

| File:line | Skill | Weight | Disposition |
|---|---|---|---|
| `drive/SKILL.md:234` | `test-driven-development` | Hard gate, Phase 3.0, every code-class task | **Replace via vendoring** — `mattpocock/skills`' `tdd/SKILL.md` is a real, richer equivalent (seams, anti-patterns, vertical-slicing rule). Follow-up: T20261001-289904 |
| `drive/SKILL.md:361` | `systematic-debugging` | Soft trigger, Phase 3.5 | **Replace via vendoring** — `mattpocock/skills`' `diagnosing-bugs/SKILL.md` is a real equivalent (feedback-loop-first discipline, redaction rule). Follow-up: T20261001-334141 |
| `drive/SKILL.md:365`, `drive/SKILL.md:502`, `address-pr/SKILL.md:161` | `verification-before-completion` | **Highest weight** — 3 hard-gate sites, the most load-bearing reference in the suite | **Scope further** — no `mattpocock/skills` skill matches this function (confirmed by reading the full engineering-bucket inventory from T20260914-412750 plus the maintainer's own named trio); `design-score`/`quality-probe` are native but measure different things (doc structure; trailing code metrics), not completion-assumption gaps. Follow-up: T20261001-995405 |
| `drive/SKILL.md:511-514` | audit-block template naming all 4 skills by exact string | Coupled to whichever of the above rename | **Update inline with each swap's own PR**, not a separate task — each of the 3 follow-ups above includes updating its own audit-block line |
| `address-pr/SKILL.md:257` | `receiving-code-review` | Single call site, feedback-processing loop | **Keep** — `mattpocock/skills`' `code-review/SKILL.md` (actually read, not assumed) is a reviewer-side two-axis (Standards/Spec) diff-review tool, not an author-side feedback-processing skill; the maintainer's suggested mapping doesn't hold up on inspection. No native or mattpocock replacement identified; not worth a scoping follow-up on its own (would duplicate T20261001-995405's shape) |
| `retro/SKILL.md:431` | `brainstorming` (design-pass hand-off) | Soft, single mention | **Keep** — low-risk hand-off reference, not a gate |
| `skill-conventions/SKILL.md:10,70,112`, `repo-conventions/SKILL.md:107`, `spinup/SKILL.md:12,27,40` | `writing-skills` (generic skill-authoring, explicitly deferred to) | Soft, deferred-to-for-authoring | **Keep** — replacing this means vendoring an entire generic skill-authoring guide, a much bigger lift than any hard gate; `skill-conventions/SKILL.md:112` already says "if the two ever conflict on a generic point, superpowers wins" — a deliberate, bounded dependency, not an oversight |
| `new-task/SKILL.md:33` | `brainstorming`'s Spike path (analogy only) | Soft, single mention | **Keep** — pure analogy reference, no invocation |
| `incept/SKILL.md:140` | `requesting-code-review` (scope-carve-out footnote) | Soft, single mention | **Keep** — comparison footnote, not a load-bearing call |

**Notable findings beyond the original filing:**

- **`retro/SKILL.md`'s Phase 4c compliance grep is no longer hardcoded to
  exact skill-name strings.** The task's filing (2026-09-23) flagged this as
  a key risk ("greps ... for the exact strings ... any rename must update
  that grep or the historical JOURNAL entries silently diverge"). Re-read
  2026-10-01: current `retro/SKILL.md:421`/`:424` greps generically for the
  `## Skills invoked` heading and reads whatever skill names appear under
  it — it no longer hardcodes the 4 specific `superpowers:*` strings. The
  risk is lower than originally flagged (automated grading won't silently
  break on a rename), though JOURNAL *prose* itself should still stay
  internally consistent for a human reader, which is why each follow-up
  task above still includes "update the audit-block line" in its own scope.
- **`superpowers:writing-skills` is no longer referenced in `retro/SKILL.md`**
  at all (the 2026-09-23 filing cited `retro/SKILL.md:380`) — it moved or
  was removed between filing and now; not investigated further since it's
  a "keep" disposition either way (still referenced from
  `skill-conventions/SKILL.md`, `repo-conventions/SKILL.md`, `spinup/SKILL.md`).
- **`mattpocock-skills` is not actually installed anywhere in this harness** —
  it exists only as inspiration/attribution text (`incept/SKILL.md:16`
  credits it for `grilling`). "Replace with a mattpocock-skills equivalent"
  always means **port/vendor the content**, the same pattern as
  `grilling` → `incept` (T20260912-279229) — there is no live dependency to
  simply point at instead of `superpowers`.

## Done criteria

- [x] Every superpowers call site inventoried with a proposed disposition — this file's `## Research findings` table (`T20260923-292618-retire-superpowers-dependency-survey.md:124`)
- [x] Each concrete swap worth doing filed as its own follow-up task (`T20261001-289904`, `T20261001-334141`, `T20261001-995405`, each stamped `scheduled: 2026-10-12` via `stamp-scheduled.sh <file> next`) — see `## Closed`
- [x] `mattpocock-skills` candidate equivalence verified against actual fetched `SKILL.md` content, not name alone — "Notable findings" bullet, this file's `## Research findings` section (`T20260923-292618-retire-superpowers-dependency-survey.md:124`)

## Closed (2026-10-01)

- No shipped code PR — this is a research task; its output is this file's
  `## Research findings` section plus three filed follow-up tasks (all
  staged `scheduled: 2026-10-12`, next iteration, per the follow-up
  convention):
  1. **T20261001-289904** — vendor `mattpocock/skills`' `tdd` to replace
     the `superpowers:test-driven-development` hard gate.
  2. **T20261001-334141** — vendor `mattpocock/skills`' `diagnosing-bugs`
     to replace the `superpowers:systematic-debugging` soft gate.
  3. **T20261001-995405** — scope a native replacement for
     `superpowers:verification-before-completion` (the highest-use call
     site, no ready mattpocock equivalent found).
- `superpowers:receiving-code-review`, `superpowers:brainstorming`,
  `superpowers:writing-skills`, and the remaining soft/analogy references
  are kept as-is — see Research findings table for why each doesn't
  warrant a follow-up.
- No blockers encountered; all research was read-only (local `grep` against
  `main` + `gh api` reads of the public `mattpocock/skills` repo), no local
  clone or code changes needed.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — research-class task,
  no executable code
- Verification (`superpowers:verification-before-completion`): yes — every
  disposition cross-checked against actually-fetched `mattpocock/skills`
  content (not name-only assumption) before being recorded; every "Done
  when" item in the original filing re-verified against this file's
  content before checking it off
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck
- Receiving code review (`superpowers:receiving-code-review`): pending —
  addressed as part of this task's own `/address-pr` loop
