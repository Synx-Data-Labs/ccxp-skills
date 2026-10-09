---
status: Open
estimation: 1
source: this conversation, 2026-10-09
---

# T20261009-283022: Rename `/incept` to `/iterate`

## Problem

- **Type**: chore
- User's own muscle memory keeps reaching for `/iterate` when they mean
  `/incept` — "I kept using /iterate while I want to improve a task or
  an existing PR etc." — a naming mismatch worth fixing rather than
  fighting the habit.
- Scope is a pure rename: `/incept`'s current behavior (grill/stress-test
  a plan via adversarial questioning before implementation, per
  `incept/SKILL.md`'s description) stays as-is; only the invocation name
  changes. Does **not** widen scope to cover improving an already-open
  PR — that's `/address-pr`'s job today, and conflating the two needs its
  own design discussion if ever pursued (flagged, not taken on here).
- Blast radius — every cross-reference needs updating, not just the skill
  dir name/frontmatter:
  - `ccxp/SKILL.md`, `ipm/SKILL.md`, `retro/SKILL.md`, `todo/SKILL.md`,
    `new-task/SKILL.md`
  - `lifecycle.md`, `repo-conventions/templates/task.md`
  - Several open `dev/TODO/*.md` files reference `/incept` by name
    (e.g. `T20260928-115329`, `T20261005-554581`,
    `T20261005-639913`, `T20261007-104557`) — these should keep working
    after the rename.
  - `dev/JOURNAL/*.md` entries reference `/incept` historically — leave
    those alone (archival, per `lifecycle.md`'s no-mirror rule).
- Done = `incept/` skill directory and all live cross-references (skills,
  `lifecycle.md`, templates, open TODO files) consistently use
  `/iterate`, with no dangling `/incept` reference outside
  `dev/JOURNAL/`.
