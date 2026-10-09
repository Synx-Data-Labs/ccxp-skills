---
status: Design
scheduled: 2026-10-12
estimation: 3
source: this conversation, 2026-10-09
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
---

# T20261009-154870: Merge /spinup into /repo-conventions, resolve the mode/setup naming collision

## TLDR

- **Type**: feature
- **Problem**: `/spinup` is a thin standalone orchestrator; its planned
  `setup` naming collides with `/repo-conventions mode`'s candidate rename.
- **Solution**: fold `mode` and `/spinup`'s whole workflow into one new
  `/repo-conventions setup [team|solo]` verb; delete `/spinup`.

## Problem

- **Type**: feature
- `/spinup` (`spinup/SKILL.md`) is mostly a thin orchestrator around
  `/repo-conventions check` + `sync`, plus one dispatch branch
  (`.env.tpl` present → `/1password-env-setup`) — thin enough that a
  separate standalone skill for it is questionable value over folding it
  into `/repo-conventions` as a new verb (e.g. `bootstrap` or `setup`).
- Separately, `/repo-conventions mode {solo|team}` is a candidate rename
  target to `setup` (so it reads as "set this repo up for solo/team
  convention") — but `setup` as a name would collide with the merged
  orchestration verb above if both land. Needs one coherent verb scheme,
  not two different things both called "setup."
- Default-mode question: should `team` become the implicit default, with
  `solo` scoped explicitly as the escape hatch for legacy repos (vs.
  today's `mode.sh <solo|team>` requiring an explicit choice either way)?
  `mode.sh`'s existing CI-presence check (refuses to enable branch
  protection with no `.github/workflows/*.yml` present) needs to degrade
  gracefully here rather than hard-block a fresh repo if team becomes the
  default path.
- Gap: neither `/spinup` nor `/repo-conventions` ever initializes or syncs
  `dev/TODO/queue.md` on a fresh repo — only `/todo sweep` does
  (`todo/SKILL.md`'s "adds missing, strikes closed/parked"). A repo spun
  up with existing `dev/TODO/*.md` files but no `queue.md` is left
  uninitialized. Closing this means deciding whether the merged
  verb dispatches `/todo sweep` as a step.
- Open design question carried into `/incept`: does `/spinup` disappear
  entirely, or survive as a one-line alias for discoverability (people
  reaching for "spin up a repo" as a verb)?
- Done = a design (via `/incept`/`/drive`) that lands one coherent verb
  scheme in `/repo-conventions` covering: convention check/sync, the
  solo/team branch-policy switch (replacing today's `mode`), the former
  `/spinup` orchestration (CLAUDE.md/guidelines.md bring-online +
  `.env.tpl` dispatch), and the `/todo sweep` queue.md gap — with
  `/spinup` either removed or reduced to a pointer.

## Context

- Today's four verbs live in `repo-conventions/SKILL.md`: `check` (:12,
  :111-130), `sync` (:13, :132-141), `show` (:14, :143-145), `mode
  {solo|team}` (:15, :147-170, backed by `repo-conventions/scripts/mode.sh`).
  None of `check`/`sync`/`mode` take a path argument — all three operate
  implicitly on cwd (`mode.sh` has a `--doc PATH` *override* flag, not a
  positional path).
- `/spinup` (`spinup/SKILL.md`) is a separate skill: `[path]` arg
  (defaulting to `.` — the one piece of generality nothing else in the
  suite uses, per a live grep across every call site: `_test-nested-invoker`
  :12 name-drops it illustratively, the original add-spinup JOURNAL entry
  and the skill-review notes discuss it, but nothing invokes it with a
  non-default path). Its workflow (`spinup/SKILL.md:50-71`): verify git
  repo → if `CLAUDE.md` missing, stop and tell the user to run `/init`
  first → run `check`, `sync` on violations → if `.env.tpl` exists,
  dispatch `/1password-env-setup` → report a summary.
- `/spinup`'s own prose (`spinup/SKILL.md:32`) claims
  `/1password-env-setup` has "confirm-before-overwrite" behavior for
  `.envrc`. Verified false while reading this skill to port it:
  `1password-env-setup/SKILL.md:74-77` says it replaces any non-identical
  `.envrc` with **no** confirmation prompt (only a byte-identical file is
  left alone) — already flagged as a self-contradiction in
  `dev/quality/skill-review-2026-09-28/batch4.md:44,104`. That underlying
  doc bug in `1password-env-setup/SKILL.md` itself is tracked under the
  existing `T20260928-101526` skill-review backlog item — out of this
  task's scope; this task just avoids repeating the false claim in the
  new prose.
- Design decisions below were reached via `/incept`-style grilling (4
  rounds) plus two follow-up corrections from the maintainer after
  independent verification of blast-radius claims (confirmed: no live
  caller passes `/spinup` a non-default path; confirmed: nothing outside
  `repo-conventions/SKILL.md` itself — only archival `dev/JOURNAL/` and
  skill-review notes — references `/repo-conventions mode` as a live
  command).

## Solution

- **One verb, cwd-scoped, no path argument** (matching `check`/`sync`/
  `mode`'s existing convention — `/spinup`'s `[path]` generality does not
  carry over, per the Context grep):

  ```
  /repo-conventions setup [team|solo] [--skip-ci-check] [--yes]
  ```

  Policy arg defaults to `team` when omitted (vs. today's `mode.sh
  <solo|team>` requiring an explicit choice). `solo` is the explicit
  escape hatch for legacy repos.
- **`mode {solo|team}` is removed as its own verb** — drop its
  `## Argument` line (`:15`) and its `### mode {solo|team}` Workflow
  section (`:147-170`) from `repo-conventions/SKILL.md`. `setup`'s
  Workflow section absorbs that step by calling
  `repo-conventions/scripts/mode.sh` directly.
- **`repo-conventions/scripts/mode.sh` is NOT touched** — same CI-presence
  hard-refuse (no `.github/workflows/*.yml` → refuse unless
  `--skip-ci-check`), same confirm-unless-`--yes` gate, same no-op when
  already in the requested policy. `setup` just forwards its resolved
  policy arg (defaulting to `team`) and passes `--skip-ci-check`/`--yes`
  straight through.
- **New `### setup [team|solo]` Workflow section**, replacing `### mode
  {solo|team}` at the same position, absorbing `/spinup`'s steps (cwd-based,
  no `[path]`):
  1. Verify cwd is a git repo.
  2. If `CLAUDE.md` is missing: report that `/init` generates one first,
     then stop (unchanged from `spinup/SKILL.md:52-56`).
  3. Run `check`; on a CLAUDE.md-present-but-empty or guidelines.md-missing/
     empty violation, run `sync` (now same-skill subroutine calls instead
     of cross-skill composition — unchanged behavior,
     `spinup/SKILL.md:57-60`).
  4. **New** — if `dev/TODO/*.md` files exist but `dev/TODO/queue.md` is
     missing: dispatch `/todo sweep` (closes the gap this task's Problem
     section flagged; conditional, mirroring the `.env.tpl`-presence-gated
     pattern in the next step rather than running unconditionally).
  5. If `.env.tpl` exists: dispatch `/1password-env-setup` (unchanged from
     `spinup/SKILL.md:61-67`, cwd implied) — documented accurately per the
     Context note above (no false "confirm-before-overwrite" claim).
  6. Apply branch policy: `bash ../repo-conventions/scripts/mode.sh
     <team|solo — from setup's own arg, default team> [--skip-ci-check]
     [--yes]`.
  7. Report a summary: what was checked/fixed/applied; what's still open
     and why (unchanged shape from `spinup/SKILL.md:68-71`).
  - Idempotent — re-running on an already-onboarded repo is a no-op at
    every step (check/sync clean, `queue.md` already present, no
    `.env.tpl`, `mode.sh` already in the requested policy) — same
    guarantee `spinup/SKILL.md`'s own Important Notes made.
- **Delete `spinup/SKILL.md` entirely.** Update cross-references:
  - `README.md` — drop the `spinup` row, update the `repo-conventions` row
    to mention `setup`.
  - `_test-nested-invoker/SKILL.md:12` — its illustrative (non-functional)
    `/spinup` example swaps to `/repo-conventions setup`, so it doesn't
    dangle.
  - `argument-hint` frontmatter (`repo-conventions/SKILL.md:5`) updates to
    `"[check|sync|show|setup {team|solo}]"`.
- **Alternatives considered and rejected:**
  - `setup` as a *separate* verb alongside a renamed/kept `mode` (e.g.
    `bootstrap`): rejected by the maintainer — `setup` is idempotent and
    branch policy is just one more thing it converges, so forcing the
    caller to invoke a second command for it is unnecessary friction.
  - Keeping `/spinup`'s `[path]` argument: rejected — no existing call
    site uses a non-default path, and every other verb in this skill is
    already cwd-only; carrying it over would be unused generality.
  - Degrading `mode.sh`'s CI-presence check to warn-and-proceed for the
    new team-implicit-default path: rejected — keeps `mode.sh` itself
    completely unchanged, and a fresh repo with no CI still gets an
    explicit, actionable refusal instead of a silently-weaker gate.

Estimation revised from 1 to 3: touches `repo-conventions/SKILL.md` (new
verb absorbing `/spinup` + `mode`), a skill deletion, two cross-reference
updates, and a design-score gate — not a 1-pointer, not large enough to be
a 5.

## Test plan

- [ ] `claude plugin validate .` passes — frontmatter well-formed on
  `repo-conventions/SKILL.md` after edits, `spinup/SKILL.md` cleanly
  removed.
- [ ] `git diff --stat main -- repo-conventions/scripts/mode.sh` shows no
  changes — confirms `mode.sh` itself is untouched.
- [ ] Manual dry run: `/repo-conventions setup` against this repo
  (ccxp-skills itself, already onboarded) — zero unwanted changes
  (CLAUDE.md/guidelines.md already clean, `queue.md` already present, no
  `.env.tpl`, already in `team` policy so `mode.sh` no-ops).
- [ ] Manual dry run in a throwaway scratch repo with no `CLAUDE.md`:
  `/repo-conventions setup` stops at step 2 and tells the user to run
  `/init` first (mirrors `/spinup`'s own original dry-run coverage).
- [ ] `grep -rn "spinup" --include='*.md' .` outside `dev/JOURNAL/` and
  `dev/quality/skill-review-2026-09-28/` (archival, left alone per
  `lifecycle.md`'s no-mirror rule) returns no hits.
- [ ] `grep -n "mode {solo|team}" repo-conventions/SKILL.md` returns no
  hits — confirms the standalone verb and its Workflow section are gone.
- [ ] `bash design-score/scripts/score.sh dev/TODO/T20261009-154870-*.md`
  scores ≥ 70 (Phase 2 gate).

## Done criteria

- [ ] `setup [team|solo] [--skip-ci-check] [--yes]` documented in
  `repo-conventions/SKILL.md`'s `## Argument` list and has its own
  `### setup` Workflow section — test: `grep -n "setup \[team|solo\]"
  repo-conventions/SKILL.md`.
- [ ] `spinup/SKILL.md` deleted — test: `test ! -e spinup/SKILL.md`.
- [ ] `README.md` has no `spinup` row; the `repo-conventions` row mentions
  `setup` — test plan's repo-wide spinup grep (above) plus manual
  inspection.
- [ ] `_test-nested-invoker/SKILL.md` no longer references `/spinup` —
  test: `grep -n spinup _test-nested-invoker/SKILL.md` → no match.
- [ ] `mode.sh` unchanged — test plan's `git diff --stat` item (above).
- [ ] Idempotent re-run on this already-onboarded repo makes zero
  unwanted changes — test plan's manual dry run (above).
