---
status: Open
scheduled: 2026-10-05
estimation: 2h
source: T20260914-412750 (research: learn from mattpocock/skills)
related: T20260914-412750
description: Adopt disable-model-invocation:true for skills that must be human-typed only, instead of relying on prose-only guardrails
---

# T20260922-409644: `disable-model-invocation` is never set to `true` anywhere in ccxp-skills — action-taking skills rely on prose alone to avoid surprise auto-fire

## Problem

- `grep -rl "disable-model-invocation: true" --include="SKILL.md" .` returns
  0 hits across all 34 `SKILL.md` files in this repo — every skill sets
  `disable-model-invocation: false` (or omits it, same default), meaning
  every skill, including clearly action-taking, side-effecting ones
  (`/autopilot`, `/drive`, `/gcpr`, `/land`), is technically model-invocable.
- The only guardrail against a model surprise-firing one of these is prose:
  `skill-conventions/SKILL.md` §1's own wording ("Use when the user
  explicitly asks to …") is a request to the model to self-restrain, not a
  hard mechanism enforced by the harness.
- `mattpocock/skills` (`.agents/invocation.md`) documents a harder pattern:
  a skill that must be human-typed-only sets `disable-model-invocation:
  true` in its `SKILL.md` frontmatter (paired, in their Codex support layer,
  with `policy.allow_implicit_invocation: false` — not applicable here since
  `ccxp-skills` is Claude-Code-only), gated by an explicit test: "could the
  model usefully reach for this autonomously?" If no, it should be
  user-invoked only, not merely discouraged by wording.

## Context

- Discovered via T20260914-412750's research pass comparing
  `mattpocock/skills`' authoring conventions against
  `skill-conventions/SKILL.md` and `dev/guidelines.md`.
- `skill-conventions/SKILL.md`'s §1 "Guardrail" bullet already implicitly
  acknowledges the risk this closes — it just stops at a prose mitigation
  instead of the frontmatter mechanism that already exists and is unused.

## Solution

- Audit all 34 `SKILL.md` files and classify each by the "could the model
  usefully reach for this autonomously?" test from `.agents/invocation.md`:
  - Reference/diagnostic skills (e.g. `/rca`, `/proof-read`,
    `/skill-conventions`) — keep `disable-model-invocation: false`, they're
    genuinely useful for the model to reach for on its own.
  - Deliberate, side-effecting action skills where an unattended/surprise
    invocation would be risky or confusing (candidates: `/autopilot`,
    `/land`, `/gcpr`, possibly `/drive`, `/top`, `/bottom`) — flip to
    `disable-model-invocation: true` and confirm each skill's own
    description no longer needs the prose-only "Use when the user
    explicitly asks" framing to do that job (the frontmatter now does it).
  - Everything else — leave as-is; this is not a blanket flip.
- Update `skill-conventions/SKILL.md` §1 (or add a new numbered convention)
  to document the two mechanisms side by side: prose-only scoping for
  reference skills that stay model-invocable but shouldn't fire eagerly,
  vs. `disable-model-invocation: true` for skills that must never fire
  without a human typing the name.
- **Alternatives rejected**:
  - *Leave it prose-only, it's worked so far* — rejected: the whole point
    of finding this gap is that a real mechanism already exists in the
    frontmatter schema and is simply unused; there's no cost to using it
    for the highest-risk skills, and it removes reliance on the model
    reliably self-restraining from a wording cue alone.

## Test plan

- [ ] After the audit, `grep -rl "disable-model-invocation: true"
      --include="SKILL.md" .` returns at least one hit (the flipped
      skills) — this is a test of the audit outcome, not a script.
- [ ] `skill-conventions/SKILL.md` documents both mechanisms with the
      "could the model usefully reach for this autonomously?" test —
      manual read-through test.

## Done criteria

- [ ] Every action-taking skill judged risky under the invocation test has
      `disable-model-invocation: true` — manual audit test, see Solution.
- [ ] `skill-conventions/SKILL.md` documents when to use each mechanism —
      manual read-through test.
