---
status: Open
scheduled: 2026-10-05
estimation: 30m
source: discovered driving T20260923-584914, 2026-09-23
related: T20260923-584914
---

# T20260923-433144: design-score's C1 check scores a `priority:` field that lifecycle.md says is retired

## Problem

- **Type**: bug (doc/tooling inconsistency)
- `design-score/scripts/score.sh`'s C1 check (`design-score/SKILL.md`
  table, `design-score/scripts/score.sh:145-159`) awards 4/20 points for
  a `priority:` frontmatter field carrying a rationale (`P2 — <why>`
  style).
- But this repo's own canonical schema docs say the field was
  deliberately retired:
  - `lifecycle.md:53` — "There is no `priority:` field. Priority is a
    task's position in `dev/TODO/queue.md`..."
  - `todo/SKILL.md:65` — "There is no `priority:` field — position in
    `queue.md` **is** the priority. A prior version of this schema had
    a free-form `Critical/High/.../Low` field that duplicated what the
    queue now expresses directly; it's retired."
  - `repo-conventions/templates/task.md:21-23` states the same rule in
    the scaffold every new task is copied from.
- `repo-conventions/scripts/lint_tasks.py`'s `ALLOWED` frontmatter-key
  set still permits `priority` (line 21), so nothing currently blocks a
  task file from carrying it — the only thing discouraging it is prose,
  and `design-score` actively rewards doing the opposite.
- **Found while**: driving T20260923-584914 through `/drive` Phase 2's
  design-score gate — the first design-score fix pass added a
  `priority:` field purely to clear the C1 check, which an independent
  review flagged as resurrecting a retired field. Removed it there
  (C1 lands at 16/20 instead of 20/20, total still 96/100, comfortably
  above the 70 threshold) rather than fix `design-score` itself, since
  that's out of this task's scope.
- **Done when**: `design-score`'s C1 check either (a) stops scoring
  `priority:` and redistributes/shrinks its ceiling accordingly, or (b)
  the retirement docs (`lifecycle.md`, `todo/SKILL.md`,
  `repo-conventions/templates/task.md`) are revised to un-retire the
  field with a rationale — whichever the maintainer decides is correct.
  Either way, `design-score`'s rubric and the canonical schema docs
  agree with each other.

## Context

- Low urgency — the current 70-point threshold is easily clearable
  without the field (a well-formed docs-class design lands ~85-96/100
  either way), so this isn't blocking anyone today. Filed to close the
  inconsistency before it causes a future task to add `priority:` back
  in good faith, believing it's expected schema.
