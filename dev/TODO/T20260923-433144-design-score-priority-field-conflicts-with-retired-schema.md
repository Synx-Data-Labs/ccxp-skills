---
status: In Progress
scheduled: 2026-09-28
estimation: 1
source: discovered driving T20260923-584914, 2026-09-23
related: T20260923-584914
claimed_by: cc1-50ac6891:ed6da7ef699fc33b
claimed_role: interactive
---

# T20260923-433144: design-score's C1 check scores a `priority:` field that lifecycle.md says is retired

## TLDR

- **Type**: bug (doc/tooling inconsistency)
- **Problem**: `design-score`'s C1 check awards 4/20 points for a
  `priority:` frontmatter field, but three canonical schema docs say
  that field is deliberately retired — the rubric contradicts the spec
  it's supposed to be measuring conformance to.
- **Solution**: remove the `priority:` sub-check from `ds-check-c1`,
  shrink C1's ceiling from 20 to 16 (the normalized-percentage scoring
  already handles an unequal `max_sum` — no redistribution needed), and
  update `design-score/SKILL.md`'s C1 row + `tests/design_score.bats`
  to match.

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

## Solution

**Decision: chosen option (a)** — stop scoring `priority:`, shrink C1's
ceiling. Rationale (decide-don't-wait — this is a defensible call, not
a genuine fork): three independent canonical docs
(`lifecycle.md:53`, `todo/SKILL.md:65`,
`repo-conventions/templates/task.md:21`) unanimously say the field is
retired, each with its own stated reason (duplicates the queue's own
ordering).

**Alternative considered and rejected — option (b), un-retiring the
field**: this would mean reversing a deliberate decision recorded in
three places with no new rationale surfacing here to justify that
reversal; nothing about this task's discovery (`design-score` just
wasn't updated when the field was retired) argues for keeping
`priority:` alive. Rejected because `design-score` is the one artifact
out of sync with the schema it's meant to score against, so it's the
one that moves — not the three docs that already agree with each
other.

- Mechanics (`design-score/scripts/score.sh`):
  - `ds-check-c1()` (`design-score/scripts/score.sh:147-159`): delete
    the `priority`-with-rationale sub-check (lines 154-157), leaving
    `estimation`/`status`/`source`/`related` (4 pts each = 16 total).
    **Also update the descriptive comment directly above the function
    (`:145-146`)** — it currently reads "C1: frontmatter completeness —
    20 (...); priority-WITH-RATIONALE 4 ..." and must drop the
    `priority` clause and the stale "20" so it doesn't describe a
    sub-check that no longer exists (caught in independent review —
    leaving it would also make the `grep -rn priority
    design-score/scripts/score.sh` done-criterion below unreliable,
    since that grep would still hit the stale comment text).
  - `local c1_max=20` (`design-score/scripts/score.sh:336`) → `c1_max=16`.
    `max_sum` (`:337`) is a sum of the per-check max variables, so it
    recomputes automatically (104 → 100); `pct = round(100*raw/max_sum)`
    (`:352`) already normalizes against whatever `max_sum` is — **no
    redistribution of the freed 4 points to the other four fields is
    needed**, matching the file's own stated design principle for
    adding/removing checks (`design-score/SKILL.md`'s "don't need to
    sum to 100" paragraph, same reasoning in reverse for *removing* a
    sub-check).
- Docs (`design-score/SKILL.md`):
  - C1 table row (`:50`): max `20` → `16`; drop the `priority` clause
    from the description, keep the `estimation`/`status`/`source`/
    `related` (4 each) description.
  - The "(20+28+10+6+16+18+6 = 104)" arithmetic sentence (`:64`)
    recomputes to "(16+28+10+6+16+18+6 = 100)" — update the literal
    numbers so the doc doesn't contradict the script's actual ceilings.
- Tests (`tests/design_score.bats` + its fixtures):
  - `"frontmatter completeness: complete fixture earns full C1 (20)"` →
    expect `16`, not `20` (the `complete.md` fixture still carries all
    four scored fields; its `priority:` line becomes inert — present
    but unscored — which is itself a useful regression check that a
    stray `priority:` field doesn't accidentally re-award points).
  - `"frontmatter: bare priority (no rationale) and missing related dock
    C1"` → the assertion `[ "$c1" -lt 20 ]` becomes `[ "$c1" -lt 16 ]`;
    `poor.md` still docks points because it's missing `related:`
    (unaffected by this change), so the test's actual regression
    coverage (a missing required field lowers C1) survives — only the
    numeric ceiling changes. Rename the test description to drop the
    now-inaccurate "bare priority" framing (it was never really testing
    priority once priority stops being scored) — reframe as "missing
    `related:` docks C1".
  - No fixture file edits needed — `complete.md`'s existing `priority:`
    line is suficient to prove it's now a no-op.
- **No changes to `lifecycle.md`, `todo/SKILL.md`, or
  `repo-conventions/templates/task.md`** — those already state the
  correct, now-reconciled position.
- **Out of scope**: `repo-conventions/scripts/lint_tasks.py`'s `ALLOWED`
  set still permitting `priority` (line 21) is a separate, lower-stakes
  inconsistency (a lint allowlist being permissive vs. a scoring rubric
  actively rewarding the retired field) — left alone here to keep this
  fix minimal and single-purpose; worth a follow-up if it recurs.

## Test plan

- [ ] `bats tests/design_score.bats` — full suite green, including the
      two updated C1 assertions.
- [ ] `bash design-score/scripts/score.sh tests/fixtures/design-score/complete.md`
      manually — confirm `C1 16/16` in the breakdown output and total
      percentage shifts consistently with the new 100-point `max_sum`.
- [ ] `bash design-score/scripts/score.sh tests/fixtures/design-score/poor.md`
      manually — confirm C1 is still docked (missing `related:`), just
      against the new 16-point ceiling.
- [ ] CI green on the implementation PR (bats, lint-tasks, skill-quality,
      Markdown Lint, sync-tasks).

## Done criteria

- [ ] `design-score/scripts/score.sh:147-159` (`ds-check-c1`) no longer references `priority:` — verify by content, not line number, since post-fix line numbers shift.
- [ ] `design-score/scripts/score.sh:336` sets `c1_max=16`, and `max_sum` (`:337`) totals 100.
- [ ] `design-score/SKILL.md:50` (C1 row) and `design-score/SKILL.md:64` (arithmetic sentence) both reflect the new ceilings.
- [ ] `tests/design_score.bats:153-163` — both C1-related assertions pass at the new ceiling: run `bats tests/design_score.bats`.
- [ ] `grep -rn priority design-score/scripts/score.sh` — zero hits (the `ds-check-c1` sub-check *and* its descriptive comment at `:145-146` are both gone), plus `design_score.bats` passing (SKILL.md prose may still mention `priority` only to explain it is *not* scored).

## Root cause

- Not a bug introduced by a specific commit regressing working
  behavior — it's a **drift** bug: `design-score` (added later, per its
  own SKILL.md framing as the `/drive` Phase 2→3 hard gate) was written
  against an *earlier* version of the task-file schema that still had a
  `priority:` field, and when that field was later retired
  (`todo/SKILL.md:65`'s "a prior version of this schema had a free-form
  `Critical/High/.../Low` field ... it's retired" — the retirement
  predates this task's `source:` discovery date 2026-09-23),
  `design-score`'s C1 check was never updated to match.
- Deliberate-vs-oversight: **oversight**. Nothing in `design-score/SKILL.md`
  or `design-score/scripts/score.sh` argues for keeping `priority:`
  alive post-retirement; it reads as the rubric simply not having been
  revisited when the schema changed elsewhere in the repo.
- Surfaced live (not from archaeology alone): driving T20260923-584914
  through `/drive` Phase 2, the design-score gate's C1 shortfall led to
  *adding* a `priority:` field purely to clear the check — an
  independent review on that task caught the resurrection of a retired
  field, which is what exposed this inconsistency (see this task's
  `source:` line).

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `design-score/scripts/score.sh` | 145-159 | `ds-check-c1()` + its descriptive comment — remove the `priority`-with-rationale sub-check and the stale "20"/priority mention in the comment above it |
| `design-score/scripts/score.sh` | 336-337 | `c1_max`/`max_sum` — shrink `c1_max` 20→16 |
| `design-score/SKILL.md` | 50 | C1 table row — max 20→16, drop `priority` from description |
| `design-score/SKILL.md` | 64 (the "104 don't need to sum to 100" sentence) | update literal arithmetic to 100 |
| `tests/design_score.bats` | 153-163 | two C1 assertions — ceiling 20→16, retitle the "bare priority" test |
| `tests/fixtures/design-score/complete.md` | 1-7 (frontmatter) | unchanged — existing `priority:` line now proves it's inert |
| `tests/fixtures/design-score/poor.md` | 1-6 (frontmatter) | unchanged — missing `related:` still docks C1 under the new ceiling |
