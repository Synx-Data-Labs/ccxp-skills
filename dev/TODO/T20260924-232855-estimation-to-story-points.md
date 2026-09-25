---
estimation: 1d
status: Design
source: 2026-09-24 conversation — brainstormed after a /todo next run surfaced
  "is estimation even useful", worked through with superpowers:brainstorming
related: T20260808-192220, T20260809-355059, T20260924-252293
---

# T20260924-232855: Replace `estimation:` duration buckets with XP story points

## TLDR

- **Type**: feature
- **Problem**: `estimation:` is a duration-bucket guess (`15m`…`2w`) filed
  before any real analysis, then silently re-guessed by `/incept` — it never
  captures real XP velocity, and `/eta` has no principled way to turn a
  bucket into a trustworthy wall-clock projection.
- **Solution**: switch `estimation:` to Fibonacci-style points (`1`/`2`/`3`/
  `5`/`8`); have `/retro` compute rolling velocity (`points_per_week`, purely
  calendar-based) and a points→hours ratio (`hours_per_point`) from real
  completed-task history into `dev/velocity.json`; have `/eta` read that
  file instead of a static bucket table. (`/ccxp`'s IPM budget-cut machinery
  is explicitly **out of scope** — see Context.)

## Problem

- `estimation:` is filed as a duration guess at `/new-task` time, before any
  design work — `repo-conventions/templates/task.md:3` defaults new tasks to
  `estimation: 2h` with no grounding.
- The defined forward-looking consumer of the *duration* semantics is
  `eta/scripts/eta.sh:121-134` — `eta_bucket_seconds()` maps the bucket
  string straight to a fixed duration for elapsed/remaining math, never
  informed by how long tasks actually took.
- `ccxp/SKILL.md:691-692`'s Phase 2a.4 also sums bucket-durations against a
  fixed **~12h product-budget line**, but this ritual has **never actually
  run** in practice (confirmed: zero `dev/JOURNAL/*-ipm-weekly.md` files
  exist in this repo's history, and the human driving this work confirmed
  the weekly IPM/GH-Project-board cadence has been abandoned generally, not
  just here) — it's documented but dead code. Redesigning it is out of
  scope for this task; see `related: T20260924-252293`.
- `retro/scripts/estimation-revisions.sh:2-18` already reconstructs a
  filed→revised→actual arc per task, i.e. the raw data needed to compute a
  real velocity/duration ratio already exists and is already being read —
  it's just used for retrospective grading (`retro/SKILL.md:461,463`), not
  fed forward into planning.
- Net effect: `/eta` runs on a static guess, while the one component
  computing real historical accuracy (`/retro`) never gets to correct it.

## Context

- **Feature** — this plugs into the existing task lifecycle
  (`lifecycle.md:129-141`, `dev/guidelines.md:36`) and the `/incept`
  grilling flow, which already has the right shape for this: its Synthesis
  step already revises `estimation:` post-grill and its Record step already
  rewrites the frontmatter (`incept/SKILL.md:90,104-105`) — only the *scale*
  of the value changes, not the revision mechanism.
- `/retro` already walks `dev/JOURNAL/` history and already has a Phase
  reading estimation accuracy (`retro/SKILL.md:220-227,247,351`) — this
  design adds a forward-facing computation next to that existing backward
  one, in the same skill.
- This repo tracks its own dev/TODO per `CLAUDE.md` ("work about this repo
  itself … belongs here"), so this task, its design, and its eventual
  implementation task all live in `dev/TODO/`, not a separate spec
  directory.
- **Scope boundary**: velocity here is deliberately **calendar-based**
  (`points_per_week`), not iteration-based — the IPM ritual `/ccxp` Phase
  2a documents (weekly commit, `scheduled:`, GH Project board mirror) turns
  out to be dead in practice, so tying velocity to "iteration boundaries"
  would bind this design to a ceremony nobody runs. Whether `/ccxp`'s IPM
  machinery itself should be simplified or retired is a separate question,
  filed as [T20260924-252293](T20260924-252293-evaluate-ccxp-ipm-ritual-still-needed.md).

## Solution

### 1. Schema & lifecycle

- `estimation:` becomes a bare integer, one of `{1, 2, 3, 5, 8}` — no unit
  suffix.
- `/new-task` (`new-task/SKILL.md:45,54,67`) always writes `estimation: 1`
  at file time; it stops asking the filer for a duration guess.
- `/incept` (`incept/SKILL.md:90,104-105`) keeps its existing "revise
  estimation" mechanism unchanged — it now assigns real point values
  (`2`/`3`/`5`/`8`) instead of a real duration, based on what grilling
  surfaces.
- `repo-conventions/SKILL.md:54,58`'s prose ("`estimation` with a duration
  (`30m`/`2h`/`1d`/`1w`)") switches to the points enum.
  `design-score/scripts/score.sh:150`'s C1 check
  (`^estimation:[[:space:]]*\S`) only tests for a non-empty value — it
  already passes unchanged under points, no code change needed there.
- `lifecycle.md:37,129-141`, `dev/guidelines.md:36`,
  `repo-conventions/templates/task.md:3,37`,
  `repo-conventions/templates/guidelines.md:54`, and
  `repo-conventions/templates/design-doc.md:50` all get their bucket-enum
  prose/examples replaced with the points enum.
- **Alternative rejected**: keep both a `points:` and a legacy `estimation:`
  field side by side during a transition window — rejected because it
  doubles the fields every skill has to read, for a value that's cheap to
  bulk-migrate in one PR (see Migration below).

### 2. `/retro` computes velocity into `dev/velocity.json`

- New/extended step in `retro/SKILL.md` (near the existing
  `estimation-revisions.sh` read at `retro/SKILL.md:220-227`): each run
  recomputes over a **trailing 4-calendar-week window** (Monday–Sunday,
  purely calendar time — no dependency on `scheduled:`, IPM files, or
  whether `/ccxp` ever runs):
  - `points_per_week` — average of (sum of points **closed**) per calendar
    week, binned by each task's **actual close date** (its
    `dev/JOURNAL/` move timestamp).
  - `hours_per_point` — `median(actual_hours / points)` over the same
    window's completed tasks, where `actual_hours` is wall-clock claim
    (`task_claim.sh acquire`) to Done. Median, not mean, to resist one
    outlier task skewing the ratio.
  - Every completed task with a point value contributes to both numbers —
    unlike the earlier iteration-based design, there's no "no iteration to
    bin into" exclusion case, since calendar weeks need no ceremony to
    exist.
- Output, written every run to `dev/velocity.json` (target repo, alongside
  `dev/TODO/`):

  ```json
  {
    "hours_per_point": 3.2,
    "points_per_week": 9,
    "computed_at": "2026-09-24",
    "window_weeks": 4,
    "sample_size": 14,
    "bootstrap": false
  }
  ```

- **Bootstrap case** (zero qualifying samples in the window — freshly
  migrated repo, or a repo that has never run `/retro`): write flat
  defaults instead of computing anything —
  `hours_per_point: 1`, `points_per_week: 10` (5-day work week ×
  2 points/day), `bootstrap: true`, `sample_size: 0`. As soon as the window
  has ≥1 real sample, switch back to the computed values and
  `bootstrap: false`.
- **Alternative rejected**: derive `points_per_week` from `hours_per_point`
  and a fixed hours-per-week constant (`budget_points = H / hours_per_point`)
  — rejected in favor of tracking `points_per_week` directly as its own
  rolling average, matching how real XP tracks velocity (points closed per
  period), and because the two ratios answer genuinely different questions
  (weekly throughput vs. single-task ETA) that don't need to stay
  numerically consistent with each other.

### 3. Consumers read `dev/velocity.json`

- `eta/scripts/eta.sh`'s `eta_bucket_seconds()` (`eta/scripts/eta.sh:121-
  134`) is replaced by `projected_hours = task.points * hours_per_point`,
  read from `dev/velocity.json`; elapsed/remaining/projected-finish math
  (`eta/scripts/eta.sh:136-137,181-182,208`) is otherwise unchanged, just
  fed a computed duration instead of a table lookup.
- **`/ccxp` is explicitly not a consumer in this task.** Its Phase 2a.4
  budget cut keeps reading `estimation:` exactly as it does today (as a
  number now instead of a duration string, which changes its arithmetic
  incidentally) — reworking it to use `points_per_week`/`hours_per_point`
  is deferred to T20260924-252293, since that ritual isn't currently run
  and redesigning unused code isn't this task's job.
- **Missing `dev/velocity.json` entirely** (repo has never run `/retro`
  even once): `/eta` treats this identically to the zero-sample bootstrap
  case (`hours_per_point: 1`, `points_per_week: 10`) rather than erroring.

### 4. Migration (one PR, no compatibility shim)

- Ship a standalone, idempotent migration script (e.g.
  `repo-conventions/scripts/migrate-estimation-to-points.sh`) implementing
  the one-time lossy mapping table: `15m/30m/1h → 1`, `2h/4h → 2`, `1d → 3`,
  `2d → 5`, `1w/2w → 8`. `2w` saturates at the same top bucket as `1w` since
  the 5-value Fibonacci scale has no slot above `8` — an earlier draft of
  this table omitted `2w` entirely (the same omission class as
  `dev/JOURNAL/2026-09-23-T20260922-270158-eta-2w-bucket-and-id-validation.md`,
  caught during PR review here instead). It rewrites `estimation:` in every
  `dev/TODO/*.md` and
  `dev/JOURNAL/*.md` file under a given repo root; only the `estimation:`
  value changes, the actual-hours data JOURNAL entries already carry (used
  to compute `hours_per_point`) is untouched.
- **Scope note**: this task only covers `ccxp-skills` itself (the skill
  source, plus its own `dev/TODO`/`dev/JOURNAL` per `CLAUDE.md`'s "tracks
  its own development as tasks"). This clone has no access to other
  consumer repos' checkouts, so migrating *their* `dev/TODO`/`dev/JOURNAL`
  isn't executable from here — each consumer repo runs the same shipped
  script itself (once) after pulling the schema/lint change, giving
  `/retro` real history immediately in that repo instead of a multi-week
  flat-default bootstrap period there.
- Ship the schema/lint/prose changes (§1) in the same PR as the script and
  this repo's own migration run — no window where old duration strings are
  tolerated in `ccxp-skills`. A leftover old-format value fails lint
  immediately (caught at the next lint run, not silently ignored).

## Test plan

- [ ] Unit: `/retro`'s velocity calc against a fixture completed-task set —
      assert `hours_per_point` (median) and `points_per_week` (mean) match
      hand-computed values, using each task's close-date to bin it into its
      calendar week.
- [ ] Unit: zero-sample bootstrap case — assert flat defaults
      (`hours_per_point: 1`, `points_per_week: 10`, `bootstrap: true`).
- [ ] Unit: migration mapping script against fixture `dev/TODO/` +
      `dev/JOURNAL/` dirs — assert every `estimation:` lands in
      `{1,2,3,5,8}` and no other field/content changes. **Include a `2w`
      fixture** (a recurring omission class — see
      `dev/JOURNAL/2026-09-23-T20260922-270158-eta-2w-bucket-and-id-validation.md`)
      and assert it maps to `8`, same as `1w`.
- [ ] Integration: `design-score` and `repo-conventions` lint both accept
      the new enum and reject a leftover duration string.
- [ ] Manual/dry-run: `/eta` runs cleanly against a missing
      `dev/velocity.json` (bootstrap fallback, no crash).
- [ ] Manual, post-migration: `/todo list`/`next` in this repo lint clean
      end-to-end.

## Done criteria

- [ ] `estimation:` schema and docs describe `{1,2,3,5,8}` — no
      duration-bucket string in any doc/template
      (`repo-conventions/SKILL.md:54,58` and the templates listed below).
      `design-score/scripts/score.sh:150`'s non-empty check needs no code
      change — verify it still passes against an integer value.
- [ ] `/new-task` files new tasks with `estimation: 1`
      (`new-task/SKILL.md:45,54,67`).
- [ ] `/retro` writes `dev/velocity.json` every run with the shape above,
      including the bootstrap path (`retro/SKILL.md` new step, next to
      `retro/scripts/estimation-revisions.sh`).
- [ ] `/eta` (`eta/scripts/eta.sh`) computes projected hours from
      `points * hours_per_point` — `eta_bucket_seconds()` is gone.
- [ ] Migration script exists, is idempotent, and has been run
      successfully against this repo's own `dev/TODO/*.md` and
      `dev/JOURNAL/*.md` — every value now in `{1,2,3,5,8}`.
- [ ] Consumer-repo migration is documented (script location + when to run
      it) but left for each consumer repo to execute on its own — not
      claimed as done here.
- [ ] `/ccxp` Phase 2a.4 is untouched beyond the incidental regex/type
      change (string → integer) — its IPM-ritual redesign is explicitly
      out of scope, tracked instead by T20260924-252293.
- [ ] All Test plan items above pass.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `lifecycle.md` | 37, 129–141 | Canonical bucket enum + Estimation section — rewrite to points |
| `dev/guidelines.md` | 36 | Mirrors the canonical enum — rewrite to points |
| `repo-conventions/templates/task.md` | 3, 37 | Scaffold default + bucket-enum comment — rewrite to `estimation: 1` default + points enum |
| `repo-conventions/templates/design-doc.md` | 50 | Frontmatter example — rewrite to points |
| `repo-conventions/templates/guidelines.md` | 54 | Template copy of the canonical enum — rewrite to points |
| `repo-conventions/SKILL.md` | 54, 58 | Required-field list + duration-pattern validation — rewrite regex |
| `new-task/SKILL.md` | 45, 54, 67 | Filing-time estimation guidance — drop duration prompt, always write `1` |
| `incept/SKILL.md` | 90, 104–105 | Synthesis "Estimate" step + Record rewrite — unchanged mechanism, new scale |
| `ccxp/SKILL.md` | 648, 691–692 | Reads `estimation:` as a bare number now instead of a duration string — no logic change; Phase 2a.4's own redesign is out of scope (T20260924-252293) |
| `eta/SKILL.md` | 3, 8, 48, 54, 69, 82 | Narrative flow description — update to describe points/hours_per_point |
| `eta/scripts/eta.sh` | 7, 121–134, 136–137, 181–182, 208 | `eta_bucket_seconds()` table → `points * hours_per_point` read from `dev/velocity.json` |
| `retro/SKILL.md` | 220–227, 247, 461, 463 | Existing estimation-accuracy grading; add new velocity-computation step |
| `retro/SKILL.md` | 351 | Phase 4 action-item guidance ("use standard buckets (30m, 1h, 2h...)") hardcodes durations — separate site, also needs the points enum |
| `retro/scripts/estimation-revisions.sh` | 2–18, 84–88 | Reused as the source of filed→revised→actual data feeding velocity calc |
| `design-score/SKILL.md` | 50 | C1 frontmatter scoring — still worth 4/20 pts, unchanged (non-empty check only) |
| `design-score/scripts/score.sh` | 150 | Non-empty check (`^estimation:[[:space:]]*\S`) — already point-compatible, no code change |
| `todo/scripts/todo-list.sh` | 52 | Displays `estimation` — no logic change, just now shows a point value |
| `todo/SKILL.md` | 39, 43, 58, 91, 135 | Field-semantics doc — replace "Required for IPM budget arithmetic" (that ritual is dead) with "Required for `/eta` projections" |
| `actions/lint-tasks/README.md` | 7 | CI schema-check description — update to points enum |

## Appendix

- Decisions made during brainstorming (superpowers:brainstorming, 2026-09-24),
  in order:
  1. Actual-time definition for velocity calc: wall clock, claim → Done
     (not blocked-time-adjusted, not session-burst-adjusted — simplest, and
     the finer-grained data those alternatives need isn't captured today).
  2. 1-point default applies at `/new-task` file time only — `/incept` is
     the only place a point value is ever revised upward.
  3. Single global `hours_per_point`/`points_per_week` — not split by
     task Type (bug/feature/infra) — points are meant to already be a
     relative-size abstraction; splitting would multiply the bootstrap
     problem for no confirmed benefit.
  4. Migration mapping table is one-time and lossy by design — old
     durations were rough guesses anyway; `/incept` corrects real ones
     during normal grilling.
  5. Trailing window was originally iteration-count-based (last 4 IPM
     iterations) — **superseded by decision 7 below**: switched to
     calendar-week-based once IPM turned out to be dead in practice.
  6. `dev/velocity.json` chosen over embedding the numbers in the latest
     `/retro` JOURNAL write-up — a dedicated machine-readable file is
     trivial for `/eta` to read, vs. parsing prose-adjacent content.
  7. **Mid-brainstorm discovery**: `/ccxp`'s weekly IPM ritual (Phase 2a
     budget cut, `scheduled:`, GH Project board mirror) has never run in
     this repo (zero `dev/JOURNAL/*-ipm-weekly.md` files exist) and has
     been abandoned generally per the human driving this work. This
     invalidated the iteration-based velocity design (decision 5) —
     renamed `points_per_iteration` → `points_per_week`, rebased on
     calendar weeks so the design doesn't depend on a ceremony nobody
     runs. Also dropped `/ccxp` Phase 2a.4's rework from this task's scope
     entirely — filed as its own question, T20260924-252293.
  8. Budget-cut simplification question (raised before the IPM-is-dead
     discovery): whether Phase 2a.4's three-line product/infra/slack split
     could collapse to a single flat-queue pull now that estimation is in
     points. Moot for this task since Phase 2a.4 isn't being touched here
     — folded into T20260924-252293's scope instead.
  9. **[PR #142](https://github.com/Synx-Data-Labs/ccxp-skills/pull/142) independent review (2026-09-24)** caught and fixed four
     citation/factual errors before merge: wrong `eta_bucket_seconds()`
     line numbers (was `111,114-115`, actually `121-134`); a
     mischaracterized `design-score/scripts/score.sh:150` check (it's a
     non-empty test, not duration-specific — no code change needed there);
     a missing `2w` bucket in the migration mapping table (now `1w/2w → 8`,
     both saturating the scale's top bucket); and an uncited
     `retro/SKILL.md:351` site that also hardcodes duration buckets.
