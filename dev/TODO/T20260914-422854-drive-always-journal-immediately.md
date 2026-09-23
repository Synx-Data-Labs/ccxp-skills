---
status: Coding — Design approved in-conversation (maintainer dictated the exact scope with precise file:line targets when filing this task, per source:)
estimation: 4h
source: this conversation, 2026-09-14 — maintainer asked to retire the deferred-to-Friday-retro default
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
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

- [ ] A fresh `/drive` run to close on a task lands the `dev/TODO/` →
      `dev/JOURNAL/` move in the same close commit — verify via `git show
      --stat` showing real insertions, not a pure rename (the existing
      order-of-operations guard's own check)
- [ ] `/retro` run against a fixture week where a task is `status: Done` in
      `dev/TODO/` (not yet swept) correctly classifies it as Shipped and picks
      up its `## Skills invoked` block
- [ ] `/retro` Phase 2b still sweeps a hand-closed `dev/TODO/` Done task left
      over from before this change (backstop path still works)
- [ ] `lint_tasks.py` / `lint-docs.sh` clean on all touched files

## Done criteria

- [ ] `drive/SKILL.md` Phase 4/Phase 7 always journal-move on close, conditional selection removed — see `drive/SKILL.md:402-406`, `:530-536`, `:549-566`.
- [ ] `retro/SKILL.md` Phase 2 Shipped classification + Phase 4 skills-audit grep both check `dev/TODO/` Done tasks — see `retro/SKILL.md:215`, `:373`.
- [ ] `retro/SKILL.md` Phase 2b reframed as backstop, not primary mechanism — see `retro/SKILL.md:259-284`.
- [ ] `lifecycle.md` and other `T20260513-189862`-referencing docs updated — see this task's own `## Closed` section for the grep result and files touched.
