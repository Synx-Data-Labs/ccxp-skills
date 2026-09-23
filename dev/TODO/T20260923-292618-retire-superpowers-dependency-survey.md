---
status: Open
estimation: 1d
source: conversation with @shine, 2026-09-23
---

# T20260923-292618: Survey retiring the `superpowers` plugin dependency

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
  - `grill-me/SKILL.md:125` — one scope-carve-out mention
    (`superpowers:requesting-code-review`)
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
