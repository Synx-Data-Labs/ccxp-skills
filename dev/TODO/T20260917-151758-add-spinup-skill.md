---
status: Open
estimation: 2h
source: this conversation, 2026-09-17
---

# T20260917-151758: Add /spinup skill for repo+skill conventions setup

## Problem

- **Type**: feature
- No single skill checks a repo against both `repo-conventions` and
  `skill-conventions` *and* knows when to dispatch other setup skills
  (e.g. `1password-env-setup`) to fully bring it online.
- Considered renaming `/repo-conventions` to `/repo` first; rejected —
  `skill-conventions` explicitly calls out `/repo-conventions` as the
  canonical noun-ish reference-skill name, and `/repo` reads as a scope,
  not "these are conventions."
- Naming for the new dispatcher skill went through several rejects before
  landing on `/spinup`:
  - `/bp` — abbreviation, forbidden by the skill-conventions naming rule
  - `/config` — collides with Claude Code's own built-in `/config`
    (theme/model settings)
  - `/tink` — invented term
  - `/tune`, `/tweak` — undersell scope; read as a small adjustment, not
    a full repo setup
  - `/spin` — collides with the existing `turnstile-spin` skill's
    "set X up end-to-end" metaphor
- Built-in `/init` (Claude Code's own CLAUDE.md generator) is closed-source
  and narrowly scoped to generating a fresh `CLAUDE.md` — nothing to
  extend. `/spinup` should compose around it (invoke `/init` when
  `CLAUDE.md` is missing) rather than duplicate its logic.
- Done: a working `spinup/SKILL.md` following `skill-conventions`
  (Use-when trigger, `argument-hint`, dispatch logic to
  `repo-conventions`/`skill-conventions`/other applicable setup skills),
  pressure-tested per `superpowers:writing-skills`.
