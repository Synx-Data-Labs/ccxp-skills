---
estimation: 1h
status: Design
priority: P3 — fixture exercising the inline-code placeholder exclusion
source: design-score test fixture
related: design-score
---

# T20260101-000099 — Discuss placeholder markers without being penalized

## Problem

The scorer must not dock a design that merely *mentions* the placeholder
markers inside inline code. The markers in question are `TODO`, `FIXME`,
`TBD`, `???`, and `<...>`, written as inline code at `scripts/score.sh:239`.

## Plan

Keep every marker in backticks — e.g. `TODO` and `<...>` — so the prose scan
skips them. See `design-score/scripts/score.sh:68`.

## Done criteria

- [ ] Inline-code markers like `FIXME` are not counted — `scripts/score.sh:239`.

## Closed

_(pending)_
