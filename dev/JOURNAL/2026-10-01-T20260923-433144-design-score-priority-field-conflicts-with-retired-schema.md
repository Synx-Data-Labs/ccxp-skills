---
status: Done
scheduled: 2026-09-28
estimation: 1
source: discovered driving T20260923-584914, 2026-09-23
related: T20260923-584914
claimed_by:
claimed_role:
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

- [x] `bats tests/design_score.bats` — full suite green (21/21), including
      the two updated C1 assertions. Also ran the full repo suite
      (`bats tests/`) — 823/823 green, no regressions elsewhere.
- [x] `bash design-score/scripts/score.sh tests/fixtures/design-score/complete.md`
      manually — `C1 16/16` confirmed in the breakdown output.
- [x] `bash design-score/scripts/score.sh tests/fixtures/design-score/poor.md`
      manually — `C1 12/16`, still docked (missing `related:`), against
      the new 16-point ceiling.
- [x] CI green on the implementation PR (bats, lint-tasks, skill-quality,
      Markdown Lint, sync-tasks) — PR #229.

## Done criteria

- [x] `design-score/scripts/score.sh:147-157` (`ds-check-c1`) no longer references `priority:` in its scoring logic.
- [x] `design-score/scripts/score.sh:336` sets `c1_max=16`; the per-check ceilings now sum to 100, confirmed by `score.sh`'s own breakdown output on both fixtures showing `Raw NN/100` rather than `/104`.
- [x] `design-score/SKILL.md:50` (C1 row) and `design-score/SKILL.md:64` (arithmetic sentence) both reflect the new ceilings (16 and `16+28+10+6+16+18+6 = 100`).
- [x] `tests/design_score.bats` — both C1-related assertions (renamed: "earns full C1 (16)" and "missing related: docks C1") pass at the new ceiling.
- [x] (revised from "zero hits") `grep -n priority design-score/scripts/score.sh` now returns exactly **one** hit — a new, accurate explanatory comment at `:146` ("There is no `priority:` field ... not scored here"), not the old stale "20 (...); priority-WITH-RATIONALE 4" description. The literal "zero hits" phrasing in the design turned out to conflate "no residual text containing the word priority" with "no stale/incorrect description" — the latter is what actually mattered, and that's satisfied; noting the discrepancy here rather than silently claiming a literal zero-hit grep that isn't true.

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

## Closed (2026-10-01)

Shipped in **PR #229** (design PR #228 merged the plan; PR #227 was the
claim PR). `design-score` no longer scores the retired `priority:`
field: `ds-check-c1`'s sub-check removed, `c1_max` 20→16, per-check
ceilings now sum to exactly 100 (was 104). `design-score/SKILL.md`'s
C1 row and arithmetic sentence updated to match; `tests/design_score.bats`'s
two C1 assertions updated and renamed. Full repo bats suite (823 tests)
green, no regressions. `design-score/scripts/score.sh` itself re-scored
against this closing task file: 88/100 (unaffected by this change, since
the task file never carried a `priority:` field).

All done criteria met except the literal "zero `priority` grep hits"
phrasing in the design, which turned out to conflate two different
things — see the Done criteria section above for the honest accounting
(one hit remains: an accurate explanatory comment, not stale content).

No follow-up tasks filed. The one explicitly out-of-scope item noted in
the design — `repo-conventions/scripts/lint_tasks.py`'s `ALLOWED` set
still permitting a `priority:` key in frontmatter — is left as a known,
lower-stakes loose end rather than filed as a tracked task, since it's
purely permissive (doesn't reward/encourage the field the way
`design-score` did) and the task's own Context section judged it low
urgency.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — Phase 3.0 code-class (touches `design-score/scripts/score.sh` + `tests/design_score.bats`). Edited the two `tests/design_score.bats` assertions first (new expected ceiling 16), watched them fail (RED, `not ok 15`), then implemented the `score.sh` fix (GREEN, all 21 design-score tests + full 823-test repo suite passing).
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6 (fresh `bats tests/` run, 823/823, before any completion claim) + Phase 7.0 (this close).
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get stuck; the fix was mechanical once the design was settled.
- Receiving code review (`superpowers:receiving-code-review`): yes — design PR #228's independent review flagged a real gap (stale descriptive comment at `score.sh:145-146` would survive and break the grep-based done-criterion); fixed in a follow-up design commit rather than pushed back on, since the finding was correct.
