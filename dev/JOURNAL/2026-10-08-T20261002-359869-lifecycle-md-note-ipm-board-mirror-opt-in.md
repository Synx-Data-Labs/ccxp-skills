---
status: Done
scheduled: 2026-10-05
estimation: 1
source: Follow-up from T20260924-252293 (decided the IPM ceremony is retired
  as a mandatory cron step)
related: T20260924-252293
---

# T20261002-359869: Note in `lifecycle.md` that IPM / `scheduled:` board-mirroring is opt-in

## Problem

- `lifecycle.md` is this repo's canonical source for task-ID format, status
  flow, and procedures — every consumer repo that adopts these conventions
  points back to it.
- T20260924-252293 (design PR #239, merged) decided the Monday IPM ceremony
  is retired as a *mandatory* step in `/ccxp`; it remains an optional,
  ad-hoc tool for a repo that has a configured GH Project board.
- `lifecycle.md` currently doesn't say this — a consumer repo adopting these
  conventions fresh could reasonably assume the weekly ceremony (and the GH
  Project iteration mirror it feeds) is a required part of the task
  lifecycle, when it isn't.

## Done when

- `lifecycle.md` gets a short note (near wherever `scheduled:` is documented)
  stating: the Monday IPM ceremony and its GH Project iteration mirror are
  **opt-in** — `scheduled:` itself is still written independently (by
  `/drive`'s dependency/follow-up staging via `stamp-scheduled.sh`, with a
  next-Monday fallback) whether or not a repo ever runs `/ipm`.
- Cross-reference T20260924-252293 for the rationale/evidence, without
  duplicating its content here (one-line pointer, not a copy).

## Closed (2026-10-08)

- Folded into the same broader pass as T20261002-219904 / T20261002-245216.
- `lifecycle.md`'s "Iteration assignment" section: replaced the forward-looking
  "Note (2026-07-03)" (which predicted Phase 2a would simplify to "take the
  top N queue entries that fit the budget, no more Tier 1/2/3 partition")
  with a note confirming that reconciliation landed, plus the opt-in
  statement this task asked for — `scheduled:` and the GH Project mirror
  work independently of whether a repo ever runs `/ipm`, cross-referencing
  T20260924-252293 without duplicating its content.
