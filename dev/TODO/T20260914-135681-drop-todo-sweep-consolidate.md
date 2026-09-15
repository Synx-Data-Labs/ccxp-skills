---
status: Open
estimation: 30m
source: this conversation, 2026-09-14
---

# T20260914-135681: Simplify `/todo sweep` by dropping the "Consolidate" recommendation

## Problem

- **Type**: chore
- Maintainer feedback (this conversation, 2026-09-14): `/todo sweep`'s Phase 3 pruning
  offers a "Consolidate" recommendation (merge N related tasks into one) alongside
  Park/Close — the maintainer's assessment is that consolidating tasks doesn't bring
  any real benefit, and dropping it simplifies the sweep workflow.
- `todo/SKILL.md`'s Phase 3 currently scores this via a "Consolidatable" signal
  (`todo/SKILL.md`'s Phase 3 step 1: "two or more related tasks that share a theme...
  merge into one") and has a full "Consolidate" procedure under step 4 (create one new
  task combining scope, move originals to JOURNAL, update `queue.md`).
- Done looks like: `todo/SKILL.md`'s Phase 3 only offers **Park** and **Close** as
  prune recommendations — the "Consolidatable" signal, the "Consolidate" recommendation
  row, and its step-4 procedure are removed; the recommendation table and any other text
  referencing "Consolidate"/"consolidation" are updated to match the two-option shape.
