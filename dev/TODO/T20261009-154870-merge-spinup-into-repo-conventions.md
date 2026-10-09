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
  non-default path). Its workflow (`spinup/SKILL.md:20-27`): verify git
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

  Policy arg defaults to `team` when omitted *and the repo has no
  existing policy configured* — vs. today's `mode.sh <solo|team>`
  requiring an explicit choice always. On an **already-configured** repo
  (solo or team), omitting the arg preserves the current policy instead
  of overriding it (see steps 3/7's default-resolution below) — true
  idempotent convergence, not a silent flip. `solo` is still the explicit
  escape hatch a caller can pass on a fresh repo that wants it.
- **`mode {solo|team}` is removed as its own verb** — drop its
  `## Argument` line (`:15`) and its `### mode {solo|team}` Workflow
  section (`:147-170`) from `repo-conventions/SKILL.md`. `setup`'s
  Workflow section absorbs that step by calling
  `repo-conventions/scripts/mode.sh` directly.
- **`repo-conventions/scripts/mode.sh` is NOT touched** — same CI-presence
  hard-refuse (no `.github/workflows/*.yml` → refuse unless
  `--skip-ci-check`), same confirm-unless-`--yes` gate, same no-op when
  already in the requested policy. `setup` just forwards its resolved
  policy arg (see steps 3/7's default-resolution logic below) and passes
  `--skip-ci-check`/`--yes` straight through.
- **New `### setup [team|solo]` Workflow section**, replacing `### mode
  {solo|team}` at the same position, absorbing `/spinup`'s steps (cwd-based,
  no `[path]`):
  1. Verify cwd is a git repo.
  2. If `CLAUDE.md` is missing: report that `/init` generates one first,
     then stop (unchanged from `spinup/SKILL.md:21`).
  3. **New — snapshot the current branch policy BEFORE anything below can
     change it** (see the four-round review history at the end of this
     step for why this has to run first, not inline in step 7, and why
     the snapshot must pin a doc path, not just a value): if no explicit
     `team|solo` arg was given to `setup`, detect the repo's *current*
     policy right now, using `mode.sh`'s own doc-resolution order and
     heuristic (`mode.sh:49-67` — `dev/guidelines.md` first if it has a
     `## Branch and Merge Policy` section, else `CLAUDE.md`, then
     `grep -qi "no ci"` + `grep -qi "direct.to.main"`) against the repo
     **as it exists right now, before step 4's `sync` can run**. Store
     **both** the result (`solo`, `team`, or `none` if neither doc has the
     section yet) **and which file it came from** (`dev/guidelines.md` or
     `CLAUDE.md`, when a value was found) — step 7 uses both, not a
     re-detection after `sync`.
  4. Run `check`; on a CLAUDE.md-present-but-empty or guidelines.md-missing/
     empty violation, run `sync` (now same-skill subroutine calls instead
     of cross-skill composition — unchanged behavior,
     `spinup/SKILL.md:22-24`).
  5. **New** — if `dev/TODO/*.md` files exist but `dev/TODO/queue.md` is
     missing: dispatch `/todo sweep` (closes the gap this task's Problem
     section flagged; conditional, mirroring the `.env.tpl`-presence-gated
     pattern in the next step rather than running unconditionally).
  6. If `.env.tpl` exists: dispatch `/1password-env-setup` (unchanged from
     `spinup/SKILL.md:25-26`, cwd implied) — documented accurately per the
     Context note above (no false "confirm-before-overwrite" claim).
  7. Apply branch policy, using step 3's snapshot:
     - If `setup` was given an explicit `team`/`solo` arg, that always
       wins — use it, ignoring the snapshot.
     - Otherwise, use step 3's snapshotted value:
       - `solo` or `team` snapshotted (from doc `<snapshotted-doc>`) →
         default to that value, **and pass `--doc <snapshotted-doc>`
         explicitly** — `bash ../repo-conventions/scripts/mode.sh
         <resolved> --doc <snapshotted-doc> [--skip-ci-check] [--yes]`.
         The explicit `--doc` is required, not cosmetic: `mode.sh` always
         re-resolves its target doc itself when `--doc` is omitted
         (`mode.sh:49-57`, `dev/guidelines.md` first), and by the time
         step 7 runs, step 4's `sync` may have created a *new*
         `dev/guidelines.md` that out-ranks the `CLAUDE.md` the snapshot
         actually came from — without pinning, `mode.sh` would read
         `CURRENT` from that freshly-created file instead of the
         snapshotted one, defeating the whole point of snapshotting
         early. Pinning makes this a true convergence no-op: `mode.sh`
         re-checks the *same* file the snapshot read, sees its own
         resolved arg matches what it detects there (`mode.sh:70-73`),
         and makes no GitHub API call.
       - `none` snapshotted (neither doc had the section at snapshot
         time) → default to `team`, **no `--doc` override** (let `mode.sh`
         resolve naturally — there is no snapshotted doc to pin to). In
         the common case this is the genuinely-fresh-repo path: step 4's
         `sync` creates a team-worded `guidelines.md`, `mode.sh` resolves
         to it naturally, and `mode.sh team` no-ops against it. In the
         **rare edge case** — `guidelines.md` exists, is non-empty, but
         simply lacks the section (so step 4's `sync`, which only fires
         on missing/empty, doesn't touch it, and `check`'s own lint list,
         `SKILL.md:121-128`, doesn't flag it either) — `mode.sh team`
         hard-errors with its existing message ("no '## Branch and Merge
         Policy' section found — run /repo-conventions sync first",
         `mode.sh:55`); `setup` reports this as an open item in step 8,
         same as any other out-of-scope `check` finding, rather than
         treating it as a `setup` failure. Teaching `mode.sh` to *create*
         a missing section is a pre-existing gap, explicitly out of this
         task's scope.
     - **Known accepted residual**: when the snapshot pins `CLAUDE.md`
       (legacy repo, no pre-existing `dev/guidelines.md`) and step 4's
       `sync` creates a fresh `dev/guidelines.md` from the generic
       team-worded template, the repo ends up with two policy docs that
       disagree in wording (`CLAUDE.md` correctly says `solo`;
       `dev/guidelines.md` says `team`, unused by this `setup` run because
       of the `--doc` pin). This is a documentation-consistency
       side-effect, not a safety issue — no unwanted mutation occurs — and
       is accepted rather than solved here, same spirit as the `mode.sh`
       section-creation gap above: out of this task's scope.
  8. Report a summary: what was checked/fixed/applied; what's still open
     and why (unchanged shape from `spinup/SKILL.md:27`).
  - Idempotent — re-running on an already-onboarded repo is a no-op at
    every step (check/sync clean, `queue.md` already present, no
    `.env.tpl`, `mode.sh` already in the resolved policy per step 7's
    default-resolution) — same guarantee `spinup/SKILL.md`'s own Important
    Notes made, now extended to cover branch policy too.
  - **Review history on steps 3/7** (four independent review rounds on
    this PR, each catching a real issue in the prior fix): round 1 —
    naively defaulting to `team` unconditionally would silently flip an
    existing solo repo; round 2 — the "no section → default team" fix
    didn't account for `sync` pre-seeding a team-worded section before
    detection ran, nor that `mode.sh` only rewrites an existing section
    and never creates one; round 3 — even with current-policy detection
    in place, running that detection *after* step 4's `sync` still let a
    legacy repo whose policy lived only in `CLAUDE.md` get silently
    overridden the moment `sync` created a fresh team-worded
    `guidelines.md` ahead of detection — fixed with step 3's early
    snapshot, taken before `sync` can touch anything; round 4 — even with
    an early value snapshot, invoking `mode.sh <resolved>` with no
    `--doc` let `mode.sh` independently re-resolve its target doc at
    step-7 time and land on the same freshly-`sync`-created
    `guidelines.md` round 3 was guarding against, defeating the snapshot
    — fixed by also snapshotting *which file* the value came from and
    passing `--doc <that-file>` explicitly at step 7.
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
- [ ] **Independent-review-flagged (PR #286 review finding, round 1):**
  manual dry run on a throwaway repo already in **solo** policy (has a
  `## Branch and Merge Policy` section with the solo wording in
  `dev/guidelines.md`) — a bare `/repo-conventions setup` with no arg
  must leave it in `solo` and make **no** GitHub branch-protection API
  call, confirming steps 3/7's default-resolution preserves existing
  policy instead of flipping it to `team`.
- [ ] Companion case: a genuinely fresh throwaway repo (`CLAUDE.md`
  present with no Branch and Merge Policy section, `guidelines.md`
  missing entirely) — step 3 snapshots `none`, step 4's `sync` seeds the
  team-worded section from
  `repo-conventions/templates/guidelines.md:11-20`, and step 7 applies
  the snapshotted `team` default, so `mode.sh` no-ops against the
  freshly-seeded text — confirms the realistic path to a "team" outcome
  on a fresh repo, not the originally-assumed-but-unreachable "no section
  found at step 7 → default team" branch.
- [ ] **Edge case (PR #286 review finding, round 2):** a throwaway repo
  with a non-empty `guidelines.md` that lacks the `## Branch and Merge
  Policy` section specifically (so step 3 snapshots `none`, and step 4's
  `sync` doesn't touch it since it's non-empty) — a bare `/repo-conventions
  setup` defaults to `team`, `mode.sh` hard-errors with its existing "no
  section found" message, and `setup`'s step 8 summary reports it as an
  open item rather than silently swallowing or mis-reporting it as
  success.
- [ ] **Legacy-policy-in-CLAUDE.md case (PR #286 review finding, round
  3, deepened in round 4):** a throwaway repo with `CLAUDE.md` carrying a
  solo-worded `## Branch and Merge Policy` section and **no**
  `dev/guidelines.md` at all — step 3 must snapshot `solo` + doc path
  `CLAUDE.md` *before* step 4's `sync` creates a fresh team-worded
  `dev/guidelines.md`; step 7 must then invoke `mode.sh solo --doc
  CLAUDE.md`, leaving the repo in `solo` with no GitHub API call, even
  though `dev/guidelines.md` now exists and reads "team". Explicitly
  confirm `mode.sh` is invoked **with** `--doc CLAUDE.md` in this case —
  round 4 found that round 3's snapshot alone (value only, no doc pin)
  wasn't sufficient: omitting `--doc` lets `mode.sh` re-resolve to the
  freshly-created `dev/guidelines.md` on its own and flip the repo to
  `team` with a real GitHub API call.
- [ ] `grep -n "argument-hint" repo-conventions/SKILL.md` shows
  `"[check|sync|show|setup {team|solo}]"`.
- [ ] `grep -rn "spinup" --include='*.md' .` outside `dev/JOURNAL/` and
  `dev/quality/skill-review-2026-09-28/` (archival, left alone per
  `lifecycle.md`'s no-mirror rule) returns no hits.
- [ ] `grep -n "mode {solo|team}" repo-conventions/SKILL.md` returns no
  hits — confirms the standalone verb and its Workflow section are gone.
- [ ] `bash design-score/scripts/score.sh dev/TODO/T20261009-154870-*.md
  --kind docs` scores ≥ 70 (Phase 2 gate; `--kind docs` because the actual
  change touches only `*.md` files — the auto-detector's body-text
  heuristic otherwise misreads this design doc's own script-path
  citations as a code-class signal).

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
- [ ] A bare `setup` on an already-solo repo preserves solo and makes no
  GitHub API call — test plan's solo-preservation dry run (above).
- [ ] A bare `setup` on a repo with policy documented only in `CLAUDE.md`
  (no `dev/guidelines.md` yet) preserves that policy — `mode.sh` invoked
  with an explicit `--doc CLAUDE.md` pinned from step 3's snapshot — even
  though `sync` creates a fresh `dev/guidelines.md` moments later — test
  plan's legacy-policy-in-CLAUDE.md dry run (above).
- [ ] Idempotent re-run on this already-onboarded repo makes zero
  unwanted changes — test plan's manual dry run (above).
