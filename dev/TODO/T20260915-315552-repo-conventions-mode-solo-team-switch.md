---
status: Design
estimation: 4h
source: maintainer conversation, 2026-09-15
description: Add `/repo-conventions mode {solo|team}` to toggle a repo's Branch and Merge Policy plus actual GitHub branch protection
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260915-315552: Add `/repo-conventions mode {solo|team}` to switch a repo between solo and team branch policy

## Problem

- **Type**: feature
- Today, "solo-repo mode" (direct-to-`main`, no feature-branch PRs) exists
  only as free-text a repo's own `dev/guidelines.md`/`CLAUDE.md` Branch and
  Merge Policy section declares by hand — see `claim/SKILL.md:25-28` and
  `drive/SKILL.md:118`. There's no command that sets or flips this; a
  maintainer has to hand-edit the policy prose and keep `/claim`/`/drive`'s
  parsing of it in sync.
- Add `mode` as a new argument to the `repo-conventions` skill:
  - `/repo-conventions mode solo` — rewrite the target repo's Branch and
    Merge Policy section to the solo-repo wording (no branch/PR required,
    direct push to `main` allowed), matching what `claim/SKILL.md`'s
    "Solo-repo mode" section and `drive/SKILL.md:118` already expect to
    parse.
  - `/repo-conventions mode team` — rewrite it to the team wording (feature
    branch + PR + CI required, matching this repo's own
    `dev/guidelines.md:11-17`), AND actually enable GitHub branch protection
    on `main` via the GitHub API (require PR, no direct pushes) — not just
    update the doc text.
  - Switching solo → team should also verify/prompt for whatever GitHub
    setup team mode assumes (e.g. CI checks configured) before turning
    protection on, so the repo doesn't end up "protected" but unable to
    merge anything.
  - Switching team → solo should disable the branch protection it (or a
    prior manual setup) put in place, so the repo doesn't stay locked out
    of direct pushes after the doc says solo.
- Done: `/repo-conventions mode team` on a solo repo results in (a) the
  Branch and Merge Policy section rewritten to team wording and (b) `main`
  actually protected per GitHub's branch protection API; `mode solo` on a
  team repo reverses both. `/claim` and `/drive`'s existing solo-repo
  detection continues to work unchanged against the rewritten doc text.
