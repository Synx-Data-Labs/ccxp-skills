---
estimation: 1h (S)
status: Design
scheduled: 2026-06-18
priority: P3 — housekeeping; refresh the onboarding glossary before the next hire.
source: retro 2026-06-12 — glossary terms drifted from current naming
related: glossary.md
---

# T20260615-888888 — Refresh the onboarding glossary

## TLDR

- **Type**: chore
- **Problem**: the onboarding glossary lists stale edition names (`glossary.md:12`).
- **Solution**: update the three edition names to match current taxonomy.

## Problem

The onboarding glossary lists stale edition names. New hires read the wrong
taxonomy on day one. The drift is visible at `glossary.md:12`, which still names
a dropped edition.

## Scope

Update the glossary so the three AcmeDB edition names match current taxonomy.

**Alternatives considered and rejected:**

- Inline the definitions into each onboarding doc — rejected: duplicates across
  the fleet and drifts; one canonical glossary is the single source of truth
  (`glossary.md:1`).

## Test plan

- [ ] Local: `markdownlint glossary.md` clean.
- [ ] Review: maintainer confirms the three edition names.

## Done criteria

- [ ] Three editions named correctly — verified against `glossary.md:12`.
- [ ] No broken cross-links — verified against `glossary.md:40`.

## Closed

_(pending)_

## Skills invoked

_(pending — recorded at Phase 7.0)_
