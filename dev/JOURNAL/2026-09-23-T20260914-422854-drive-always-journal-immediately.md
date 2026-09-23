---
status: Done
estimation: 4h
source: this conversation, 2026-09-14 — maintainer asked to retire the deferred-to-Friday-retro default
claimed_by:
claimed_role:
scheduled: 2026-09-21
---

# T20260914-422854: `/drive` always journal-moves a task on close; `/retro` reads both `dev/TODO` and `dev/JOURNAL` for the week's finished tasks

## TLDR

- **Type**: chore
- **Problem**: `/retro`'s Phase 2 "Shipped" classification and Phase 4 skills-audit grep only look in `dev/JOURNAL/`, but `/drive`'s current default leaves a closed task's file sitting in `dev/TODO/` (status: Done) until Friday's batch sweep — so most of the week's just-closed tasks are invisible to `/retro`'s own classification step, which runs *before* that sweep in the same invocation.
- **Solution**: make `/drive`'s immediate journal-move (currently the `--immediate`-only path) the sole close behavior, and teach `/retro`'s classification/audit steps to also check `dev/TODO/*.md` with `status: Done` — Phase 2b becomes a backstop for hand-closed tasks, not the primary mechanism.

## Context

- T20260513-189862 introduced the current deferred-to-Friday default —
  its stated rationale was collapsing N per-task hub PRs into one weekly
  sweep PR (`/drive` Phase 4's own comment, `drive/SKILL.md`). This task
  reverses that trade-off per direct maintainer ask: the retro-visibility
  gap it causes outweighs the PR-count savings.
- Confirmed live in this repo (2026-09-14, when this task was filed):
  four tasks sat `status: Done` in `dev/TODO/`, correctly awaiting the
  Friday sweep per the current design — the exact accumulation
  `retro/SKILL.md`'s own Phase 2b header comment describes as its reason
  to exist. This session's own current run (2026-09-22/23) has since
  independently reproduced the same pattern multiple times (T20260910-872316,
  T20260911-140914, T20260914-412750, T20260914-359646 all closed
  in-place this run, none yet moved to `dev/JOURNAL/`).

## Problem

- **Type**: chore
- Maintainer ask (this conversation, 2026-09-14): once a task is done, `/drive`
  should always move it straight to `dev/JOURNAL/` — don't wait for the Friday
  retro's batch sweep. `/ccxp retro` should find the week's finished tasks from
  **both** `dev/TODO/` (Done-status tasks not yet moved) and `dev/JOURNAL/`
  (already moved), not `dev/JOURNAL/` alone.
- **Current default** (`drive/SKILL.md:405-406`): on close, `/drive` Phase 4
  flips `status:` to `Done` **in-place** in `dev/TODO/` and leaves the file
  there; the `dev/TODO/` → `dev/JOURNAL/` move only happens immediately when
  invoked with `--immediate`, a `P0` status suffix, or a customer-visible task
  (`drive/SKILL.md:18-21`). Otherwise the file waits for `/retro` Phase 2b's
  weekly batch sweep (`retro/SKILL.md:259-284`) to move it.
- **Real gap this already causes**: `retro/SKILL.md:215` classifies a task as
  "Shipped" by checking whether it "moved to `dev/JOURNAL/` as Done" —  but
  Phase 2b (the batch sweep that performs that move) runs `retro/SKILL.md:259`,
  *after* Phase 2's classification step in the same retro invocation. So at
  classification time, most of the week's just-closed tasks are still sitting
  in `dev/TODO/` with `status: Done`, and Phase 2's JOURNAL-only check
  undercounts them as not-yet-shipped. Same gap in the skills-audit grep at
  `retro/SKILL.md:373` ("grep the week's JOURNAL... for `## Skills invoked`") —
  a Done task still in `dev/TODO/` is invisible to that grep too.
- Confirmed live in this repo right now: four tasks (T20260911-347027,
  T20260914-234656, T20260914-384424, T20260914-871616) are `status: Done` and
  still sitting in `dev/TODO/`, correctly awaiting Friday's batch sweep per the
  current design — exactly the accumulation `/retro` Phase 2b's own header
  comment (`retro/SKILL.md:262-264`) describes as the reason it exists.

## Scope

- **`/drive`**: make the immediate journal-move (currently the `--immediate`
  override path, `drive/SKILL.md:406`, `:560`) the **only** behavior — same-repo
  Phase 4 (`drive/SKILL.md:402-406`) and Phase 7 (`drive/SKILL.md:530-536`),
  and cross-repo Phase 4 step 2 (`drive/SKILL.md:413` — "Do NOT move the
  task file to JOURNAL in this PR") / Phase 7 (`drive/SKILL.md:549-566`). Retire the
  in-place-only default and the `--immediate`/`P0`-suffix/customer-visible
  triggers that select between the two paths — there's only one path now.
  Keep the **order-of-operations guard** (`drive/SKILL.md:518`, `git mv` first,
  then edit at the new path — the exact hazard the current `--immediate` path
  already has to defend against) since it becomes the *only* path, not a rare
  one.
- **`/retro`**: Phase 2b (`retro/SKILL.md:259-284`) becomes a **backstop**, not
  the primary mechanism — it should still exist and still sweep any Done task
  found in `dev/TODO/` (a task closed by hand, or by a session that predates
  this change, or any other path that didn't go through `/drive`'s close), but
  it stops being the *expected* weekly volume. Phase 2's "Shipped" detection
  (`retro/SKILL.md:215`) and the skills-audit grep (`retro/SKILL.md:373`) both
  need to check `dev/TODO/*.md` with `status: Done` **and** `dev/JOURNAL/<this
  week>-T*.md`, not JOURNAL alone — so a task `/drive` just journaled seconds
  before retro ran, and a task some other path left sitting in `dev/TODO/`,
  are both counted correctly regardless of which folder holds it.
- **`lifecycle.md`** / any other doc describing the "Done tasks wait for Friday"
  convention should be updated to match — grep for `T20260513-189862` (the
  task that introduced the current deferred default) and update each
  reference, not just the two SKILL.md files.
- Out of scope: whether `/todo sweep`'s own Phase 3 "already done" prune signal
  (used earlier today to close T20260912-279229, a task that shipped directly
  to `main` outside `/drive` entirely) still has a role — it does, for exactly
  that out-of-band case, and isn't touched by this change.
- **Alternatives rejected**:
  - *Fix only `/retro`'s classification to also scan `dev/TODO/`, leave
    `/drive`'s deferred default alone* — rejected: this closes the
    visibility gap but not the root inconsistency the maintainer flagged
    (a "Done" task sitting outside `dev/JOURNAL/` for up to a week is
    itself confusing state, independent of whether `/retro` can see it).
  - *Keep both paths, add a flag defaulting to immediate* — rejected:
    the whole point is retiring the conditional selection
    (`--immediate`/`P0`/customer-visible), not inverting its default;
    two code paths for one behavior is the exact complexity this task
    removes.

## Test plan

- [x] A fresh `/drive` run to close on a task lands the `dev/TODO/` →
      `dev/JOURNAL/` move in the same close commit — verify via `git show
      --stat` showing real insertions, not a pure rename (the existing
      order-of-operations guard's own check). Self-referential: this very
      task's own close applies the new convention immediately — verified
      via `git show --stat HEAD` after committing (see `## Closed` below).
- [x] `/retro` Phase 2's Shipped classification and Phase 4c's skills-audit
      grep both now read as checking `dev/TODO/*.md` with `status: Done` in
      addition to `dev/JOURNAL/` — verified by read-through of the committed
      `retro/SKILL.md` diff (no executable test harness exists for `/retro`,
      a prose orchestration skill, not a script; verification is doc-content
      correctness, same as the design-score gate's own evidence-anchor bar).
- [x] `/retro` Phase 2b's own text now explicitly frames it as a **backstop**
      for hand-closed / pre-change tasks, not the primary mechanism — same
      read-through verification.
- [x] `lint_tasks.py` / `lint-docs.sh` clean on all touched files — ran
      `bash _docs/lint-docs.sh drive/SKILL.md retro/SKILL.md` and
      `repo-conventions/scripts/lint_paragraphs.py --changed drive/SKILL.md
      retro/SKILL.md`, both clean; `bash _docs/doc-impact.sh origin/main`
      reports no stale docs against the committed diff.

## Done criteria

- [x] `drive/SKILL.md` Phase 4/Phase 7 always journal-move on close, conditional selection removed — see `drive/SKILL.md:402-406`, `:530-536`, `:549-566`.
- [x] `retro/SKILL.md` Phase 2 Shipped classification + Phase 4 skills-audit grep both check `dev/TODO/` Done tasks — see `retro/SKILL.md:215`, `:373`.
- [x] `retro/SKILL.md` Phase 2b reframed as backstop, not primary mechanism — see `retro/SKILL.md:259-284`.
- [x] `lifecycle.md` and other `T20260513-189862`-referencing docs updated — see this task's own `## Closed` section for the grep result and files touched.

## Closed (2026-09-23)

- Shipped in **PR #TBD** (`t20260914-422854-impl`) — this task's own
  claim PR (#74) merged first, implementation followed in this PR.
- `grep -rln "T20260513-189862" --include="*.md" .` found only two
  files at implementation time: `retro/SKILL.md` (updated, now
  describes the backstop framing) and this task file itself.
  `lifecycle.md` was **not** among them — it already documented "Done
  means the file is moved" (`lifecycle.md:75`) and never adopted the
  deferred-to-Friday language `drive/SKILL.md` had drifted to; this
  change actually brings `drive/SKILL.md` back into alignment with
  `lifecycle.md`'s original convention, not the other way around. A
  broader grep for the deferred-close phrasing (`batch journal-sweep`,
  `wait for.*Friday`) found no other stale doc beyond `drive/SKILL.md`
  and `retro/SKILL.md`, both fixed here.
- All four Done criteria met — see the checked boxes above, each with
  its file:line anchor.
- Dogfooded the new convention on this very task's own close: `git mv`
  ran first, the `## Closed`/`## Skills invoked` edits landed at the new
  `dev/JOURNAL/` path second, matching the order-of-operations guard
  this task's own diff keeps. `git show --stat HEAD` (after committing)
  showed real insertions, not a pure rename — the Test plan item this
  satisfies.
- No follow-up tasks filed — the maintainer's original ask was fully
  scoped and completed in one pass.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class change
  (skill-doc prose, no executable code)
- Verification (`superpowers:verification-before-completion`): yes —
  design-score gate (81/100), full diff re-read for coherence across
  both SKILL.md files, `doc-impact.sh` clean, and the order-of-operations
  guard self-applied and verified via `git show --stat`
- Systematic debugging (`superpowers:systematic-debugging`): no —
  didn't get stuck
- Receiving code review (`superpowers:receiving-code-review`): pending —
  addressed as part of this implementation PR's `/address-pr` loop
