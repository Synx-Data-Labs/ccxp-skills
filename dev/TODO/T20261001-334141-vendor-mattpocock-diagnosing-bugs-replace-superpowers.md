---
status: Open
scheduled: 2026-10-12
estimation: 3
source: T20260923-292618 survey
related: T20260923-292618
---

# T20261001-334141: Vendor `mattpocock/skills` `diagnosing-bugs` to replace the `superpowers:systematic-debugging` soft gate

## Problem

- `drive/SKILL.md` Phase 3.5 (current `grep -n "superpowers:" drive/SKILL.md`
  line ~361) invokes `superpowers:systematic-debugging` whenever
  implementation gets stuck (test won't go green after 2 attempts, a
  pipeline failure, "trying things rather than forming hypotheses").
- Maintainer preference (T20260923-292618, 2026-09-23 conversation): prefer
  `mattpocock-skills`' leaner equivalents over the generic `superpowers`
  suite where one exists.
- `mattpocock/skills`' `skills/engineering/diagnosing-bugs/SKILL.md` (fetched
  2026-10-01) is a comparable disciplined debugging loop: Phase 1 is
  "build a feedback loop" (a tight pass/fail signal for the specific bug) —
  "This is the skill. Everything else is mechanical" — followed by
  bisection/hypothesis-testing/instrumentation phases, plus a secret-redaction
  rule for any captured output shown along the way. It is not currently
  vendored anywhere in `ccxp-skills`.

## Context

- Same porting pattern as T20261001-289904 (tdd) and the T20260912-279229
  precedent (`grilling` → `incept`) — vendor the substance, drop the
  external-plugin dependency.
- Lower risk than the TDD or verification-before-completion gates: this is a
  single soft-trigger call site (invoked "when the smell appears, not on
  every test failure"), not a hard pre-PR/pre-merge gate.
- Also referenced in the Phase 7.0 "Skills invoked" audit-block template
  (`Systematic debugging (\`superpowers:systematic-debugging\`)`) — update in
  the same PR, same reasoning as T20261001-289904's audit-block note.

## Solution

- Vendor `mattpocock/skills`' `diagnosing-bugs/SKILL.md` content (the
  feedback-loop-first discipline, redaction rule, phased approach) into a
  native skill or inline guidance — scope standalone-skill vs. inline
  decision during implementation.
- Swap `drive/SKILL.md` Phase 3.5's invocation target to the new name.
- Update the Phase 7.0 audit-block template line to match.
- **Alternatives rejected**:
  - *Keep `superpowers:systematic-debugging`* — rejected per maintainer
    preference.
  - *Merge this into the same follow-up PR as T20261001-289904 (tdd)* —
    rejected: each is independently scoped and independently portable; a
    combined PR risks scope creep past the single-swap-per-task convention
    this suite follows (per T20260914-412750's own precedent of filing one
    follow-up per concrete swap).

## Test plan

- [ ] New skill/doc renders correctly (markdown lint, frontmatter valid)
- [ ] `drive/SKILL.md` Phase 3.5 invocation line and Phase 7.0 audit-block
      line both updated and consistent

## Done criteria

- [ ] Vendored skill/doc exists at its chosen path — `file:line` TBD at
      implementation
- [ ] `grep -n "superpowers:systematic-debugging" drive/SKILL.md` returns
      nothing
- [ ] Phase 7.0 audit-block template line matches the new skill name
