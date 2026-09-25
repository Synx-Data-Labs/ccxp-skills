---
status: Design
scheduled: 2026-09-21
estimation: 1h
source: T20260910-919422's Closed section, 2026-09-22 — the +/- and comma-spacing corruption itself is not fixed by that task's scoping fix
related: T20260910-919422
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
---

# T20260922-383156: `markdownlint-cli2 --fix` still flips a bare leading `+` to `-` and drops comma-spacing — scoping contains it, doesn't fix it

## Problem

- **Type**: bug
- `T20260910-919422` fixed `_docs/lint-docs.sh` so `--fix` no longer touches
  *unrelated* files, but the underlying corruption of the file it IS asked
  to lint is unchanged: a hard-wrapped prose line beginning with a bare `+`
  (meaning "and/plus", not a list item) still gets rewritten to `-` by
  MD004's dash-style enforcement — confirmed twice in real consumer-repo
  JOURNAL entries (`T20260910-919422`'s Problem/Confirmed-recurrence
  sections have the exact before/after examples and file:line evidence).
- **New, still-unexplained symptom** (same lint pass, 2026-09-22
  recurrence): dropped the space after a comma in 2 lines
  (`*.lyrics.md,*.service.md` from `*.lyrics.md, *.service.md`) — comma-
  spacing normalization isn't a documented `markdownlint-cli2`/MD004
  behavior, so the mechanism isn't yet confirmed to be the same code path
  as the `+`/`-` flip.
- Impact: any file legitimately created/edited via the doc-lint bundle that
  happens to contain a bare-leading-`+` continuation line (or comma-spaced
  text matching whatever triggers the second symptom) still gets silently
  corrupted — now caught by `git diff` review before commit (since scoping
  means it's only ever the one file actually being touched), but not
  prevented.
- Done looks like: either (a) the `+`/`-` flip is confirmed as MD004's
  dash-style rule and a targeted, non-repo-wide-weakening fix is found
  (e.g., a per-invocation rule override for the single scoped `--fix` call,
  not a blanket MD004 config change — see `T20260910-919422`'s Solution
  section for why a repo-wide MD004 reconfiguration was rejected), or (b)
  root-caused as unfixable-safely and the doc-lint bundle's callers are
  told to review the diff before committing rather than trust "fix-then-
  continue" blindly for this rule; separately, the comma-spacing symptom is
  root-caused (same mechanism or different) before deciding how to handle it.

## Context

- `_docs/lint-docs.sh` (the shared doc-lint wrapper) — `T20260910-919422`'s
  `--no-globs` fix already merged; this task is scoped to the remaining
  content-corruption issue that fix explicitly did not address.
- `.markdownlint-cli2.jsonc`'s `MD004: {style: "dash"}` config is what
  drives the `+` → `-` rewrite when MD004 misreads prose as a list.
