---
status: Design
estimation: 2h
source: this conversation, 2026-09-17
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-14
---

# T20260917-151758: Add `/spinup` skill for repo+skill conventions setup

## TLDR

- **Type**: feature
- **Problem**: No single skill checks a repo against `repo-conventions` +
  `skill-conventions` and dispatches other setup skills (e.g.
  `1password-env-setup`) to fully bring it online.
- **Solution**: new prose-only `spinup/SKILL.md` dispatcher skill —
  composes around the built-in `/init`, `/repo-conventions`, and any setup
  skill matching a detected signal (`.env.tpl` → `1password-env-setup`),
  authored per `skill-conventions`.

## Problem

- Onboarding a repo onto this suite's conventions is manual today: a human
  has to know to run `/repo-conventions check`, separately remember
  `/1password-env-setup` when the repo uses the `.env.tpl` flow, and there
  is no single entry point tying these together or reporting what's still
  missing.
- Impact: repos onboard inconsistently — conventions get checked ad hoc,
  and secrets-bootstrap setup gets forgotten because nothing surfaces it.

## Context

- Existing setup-shaped skills this composes:
  - `repo-conventions` — `check`/`sync`/`show`, CLAUDE.md/guidelines.md/`dev/`
    layout (`repo-conventions/SKILL.md`).
  - `1password-env-setup` — `.env`/`.envrc` bootstrap from `.env.tpl`
    (`1password-env-setup/SKILL.md`).
  - Built-in `/init` (Claude Code's own `CLAUDE.md` generator) — closed
    source, narrowly scoped, nothing to extend.
- No existing skill composes these into one "bring this repo online" entry
  point.

## Solution

- New skill `spinup/SKILL.md`:
  - `## Argument`: `[path]`, optional, defaults to `.` — same convention as
    `1password-env-setup`.
  - `## Workflow`:
    1. Resolve `<path>` (default `.`); verify it's a git repo.
    2. If `<path>/CLAUDE.md` is missing: report that the built-in `/init`
       should be run first (a skill cannot invoke a built-in slash command
       on the user's behalf), then stop — nothing else in this workflow is
       safe to run without a `CLAUDE.md` to check conventions against. If
       present, continue straight through.
    3. Run `/repo-conventions check` against `<path>`. If it reports
       violations, run `/repo-conventions sync` (which already diffs +
       confirms before overwriting a non-empty file — `/spinup` inherits
       that safety rather than re-implementing it).
    4. If `<path>/.env.tpl` exists, dispatch `/1password-env-setup <path>`.
       Skip silently otherwise — most repos don't use the 1Password-backed
       secrets flow.
    5. Report a summary: what was checked, what was fixed, what's still
       open. Explicitly out of scope: authoring brand-new skills — point at
       `/skill-conventions` + `superpowers:writing-skills` for that instead
       of attempting it here.
  - Step 4's detection is a plain file-existence signal, deliberately
    minimal — adding more setup skills later (new signal → new dispatch
    branch) is future work, not required for this task.
- Alternatives considered and rejected:
  - Renaming `/repo-conventions` → `/repo` first: rejected —
    `skill-conventions` already calls out `/repo-conventions` as the
    canonical noun-ish reference-skill name, and `/repo` reads as a scope,
    not "these are conventions."
  - Name candidates rejected before `/spinup`:
    - `/bp` — abbreviation, forbidden by the skill-conventions naming rule.
    - `/config` — collides with Claude Code's own built-in `/config`.
    - `/tink` — invented term.
    - `/tune`, `/tweak` — undersell scope; reads as a small adjustment, not
      a full repo setup.
    - `/spin` — collides with the existing `turnstile-spin` skill's "set X
      up end-to-end" metaphor.
  - Duplicating `/init`'s `CLAUDE.md`-generation logic inside `/spinup`:
    rejected — `/init` is closed-source and Claude Code's own tool;
    `/spinup` composes around it (detect absence, defer to it) instead of
    reimplementing it.

## Test plan

- [ ] Prose-only skill (no `scripts/` added) — per `skill-conventions` §5,
  no BATS tests required.
- [ ] Pressure-test via `superpowers:writing-skills`'s RED-GREEN-REFACTOR
  subagent process before declaring done.
- [ ] Manual dry run: point `/spinup` at this repo (`ccxp-skills` itself)
  and confirm it reports conventions already satisfied / no `.env.tpl`
  present, making no changes (idempotent on an already-clean repo).
- [ ] `claude plugin validate .` passes (frontmatter well-formed, no schema
  errors).

## Done criteria

- [ ] `spinup/SKILL.md` exists with `name`, `description` (Use-when
  trigger), `argument-hint` frontmatter — test: `claude plugin validate .`
  (test plan item 4).
- [ ] `/spinup` dispatches to `/repo-conventions` and
  `/1password-env-setup` per the Workflow section — test: manual dry run
  (test plan item 3).
- [ ] `spinup/SKILL.md` pressure-tested via `superpowers:writing-skills`'s
  RED-GREEN-REFACTOR subagent process — test plan item 2; pass recorded in
  the Closed section.
- [ ] `README.md:97-117` skill table gets a `spinup` row (Task lifecycle &
  PR automation section) — test: `grep spinup README.md`.
