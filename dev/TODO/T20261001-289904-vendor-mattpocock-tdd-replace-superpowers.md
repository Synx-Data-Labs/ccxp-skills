---
status: Open
scheduled: 2026-10-12
estimation: 3
source: T20260923-292618 survey
related: T20260923-292618
---

# T20261001-289904: Vendor `mattpocock/skills` `tdd` to replace the `superpowers:test-driven-development` hard gate

## Problem

- `drive/SKILL.md` (Phase 3.0, current `grep -n "superpowers:" drive/SKILL.md`
  line ~234) hard-gates every code-class task on
  `superpowers:test-driven-development` — "invoke ... BEFORE step 1 below. The
  TDD skill owns red → green → refactor."
- Maintainer preference (T20260923-292618, 2026-09-23 conversation): lean on
  `ccxp-skills`-native mechanisms + `mattpocock-skills`' leaner equivalents
  instead of the heavier generic `superpowers` suite.
- `mattpocock/skills`' `skills/engineering/tdd/SKILL.md` (fetched via
  `gh api repos/mattpocock/skills/contents/skills/engineering/tdd/SKILL.md`,
  2026-10-01) is self-contained and arguably richer than a one-line gate
  reference: it defines "seams" (test at the public boundary, confirmed with
  the user up front), a vertical-slicing rule (one seam → one test → one
  minimal impl, never horizontal bulk-test-then-implement), and named
  anti-patterns (implementation-coupled, tautological, horizontal slicing).
  It is not currently vendored or installed anywhere in `ccxp-skills`.

## Context

- This mirrors the T20260912-279229 precedent (`grilling` → `incept`): port
  the external skill's substance into a native `ccxp-skills` skill/doc
  instead of depending on the `superpowers` plugin being installed.
- Hard-gate risk: this is one of the most load-bearing superpowers call
  sites — every code-class `/drive` task currently depends on it firing.
- The audit block drive/SKILL.md Phase 7.0 writes into every JOURNAL entry
  (`## Skills invoked` — currently "TDD (`superpowers:test-driven-development`)")
  names this skill by exact string; `/retro` Phase 4c's current grep targets
  the generic `## Skills invoked` heading, not the specific skill-name string
  (confirmed 2026-10-01 against current `retro/SKILL.md` — no longer a
  hardcoded per-skill-name grep), so renaming here is lower-risk than
  T20260923-292618 originally flagged, but the audit-block *wording* in
  `drive/SKILL.md` Phase 7.0 still must be updated in the same PR.

## Solution

- Vendor `mattpocock/skills`' `tdd/SKILL.md` content (seams, anti-patterns,
  rules of the loop) into a new native skill, or inline it directly into
  `drive/SKILL.md` Phase 3.0 if a standalone skill is overkill — scope this
  decision during implementation, not here.
- Swap `drive/SKILL.md` Phase 3.0's gate from `superpowers:test-driven-development`
  to the new vendored name.
- Update the Phase 7.0 "Skills invoked" audit-block template line
  (currently `TDD (\`superpowers:test-driven-development\`)`) to the new name.
- **Alternatives rejected**:
  - *Keep `superpowers:test-driven-development`* — rejected per explicit
    maintainer preference to reduce the `superpowers` dependency surface.
  - *Write a from-scratch native TDD doc instead of porting mattpocock's* —
    rejected: mattpocock's content is already well-formed and freely
    readable (MIT-style open skills repo); re-deriving it from scratch adds
    no value over porting + attributing.

## Test plan

- [ ] New skill/doc renders correctly (markdown lint, frontmatter valid if a
      standalone `SKILL.md`)
- [ ] `drive/SKILL.md` Phase 3.0 gate line updated and the Phase 7.0 audit
      block line updated to match
- [ ] A test `/drive` dry-run (or manual read-through) confirms the new gate
      text reads the same as the old one's intent (red-before-green,
      verification-pass)

## Done criteria

- [ ] Vendored skill/doc exists at its chosen path — `file:line` TBD at
      implementation
- [ ] `drive/SKILL.md` no longer references `superpowers:test-driven-development`
      — `grep -n "superpowers:test-driven-development" drive/SKILL.md` returns
      nothing
- [ ] Phase 7.0 audit-block template line matches the new skill name
