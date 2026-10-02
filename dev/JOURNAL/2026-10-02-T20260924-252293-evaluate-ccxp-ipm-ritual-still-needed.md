---
status: Done
estimation: 2
source: 2026-09-24 conversation — surfaced while designing T20260924-232855
  (estimation → story points); the human driving this work confirmed the
  weekly IPM/GH-Project-board cadence has been abandoned for a long time
related: T20260924-232855
claimed_by:
claimed_role:
scheduled: 2026-09-28
---

# T20260924-252293: Decide whether `/ccxp`'s weekly IPM ritual should be simplified or retired

## TLDR

- **Type**: research — a decision to record, not code to ship; any mechanical
  follow-through is filed as separate task(s).
- **Problem**: `/ccxp`'s Monday IPM ceremony (budget-cut, three-line
  product/infra/slack split, `*-ipm-weekly.md` commits) has never executed in
  this repo, and the maintainer confirms the cadence is abandoned generally.
- **Solution**: retire the *mandatory* weekly ceremony from `/ccxp`'s cron
  path; keep continuous `/todo next` + `/drive` off `queue.md` as the sole
  planning loop; keep `scheduled:` and the Project-board mirror mechanics
  unchanged (already work independently of the ceremony); file follow-ups for
  the mechanical skill-doc edits and for retro's now-permanently-dead
  bump-3x/bump-2x detectors.

## Problem

- `/ccxp` Phase 2a (`ccxp/SKILL.md`) documents an elaborate weekly IPM
  ritual: Tier 1/2 candidate selection, a three-line budget cut (~12h
  product / ~4h infra / ~4h slack out of a 20h week), `dev/JOURNAL/
  YYYY-MM-DD-ipm-weekly.md` commits, the `scheduled:` frontmatter field,
  and a GH Project board mirror (`.github/scripts/sync-tasks-to-issues.py`
  in consumer repos).
- In this repo, that ritual has **never run** — `dev/JOURNAL/` contains
  zero `*-ipm-weekly.md` files despite substantial task-lifecycle history
  (confirmed via `git log --oneline -- dev/JOURNAL/*ipm-weekly*` returning
  nothing).
- The human driving this work confirmed (2026-09-24) this isn't specific
  to this repo — the weekly IPM/GH-Project-board cadence has been
  abandoned generally, in favor of continuous `/todo next` + `/drive`
  pulling straight off the flat `dev/TODO/queue.md` priority order.
- This was discovered mid-design of T20260924-232855, which needed to
  decide what "velocity" should be computed against — it worked around the
  problem by rebasing velocity on calendar weeks instead of IPM iterations,
  but left the underlying question unanswered: **should the IPM machinery
  itself still exist?**
- A related, narrower question raised in the same conversation: even if
  IPM keeps running somewhere, does its three-line product/infra/slack
  budget split (`/ccxp` Phase 2a.4, now `/ipm` step 4) still earn its
  complexity now that `dev/TODO/queue.md` is a single flat priority list?
  (The split exists to guard against a real regression — an infra task
  silently eating a scheduled feature's budget — so simply collapsing to
  "walk the flat queue until points run out" reopens that exact risk.)

## Context

- **Verified in this repo** (2026-10-02, this task):
  - `git log --oneline -- "dev/JOURNAL/*ipm-weekly*"` → 0 commits, ever. The
    ceremony's sole artifact has never been produced here.
  - `PROJECT_OWNER`/`PROJECT_NUMBER` are unconfigured in this clone's env —
    every `_session/status.sh` call this very task's own claim/PR flow made
    logged `Project board mirror disabled`. The GH-Project-board half of the
    ritual (iteration mapping, `sync-tasks-to-issues.py`) has no board to
    mirror to from this repo.
  - `/todo`'s own `next`/`list` workflows (`todo/SKILL.md`) already dropped
    scored prioritization: *"There is no `priority:` field — position in
    `queue.md` **is** the priority... a prior free-form
    `Critical/High/.../Low` field... is retired."* `next` walks `queue.md`
    top-to-bottom and explicitly refuses to re-sort by deadline or
    estimation.
  - **Direct check against `ipm/SKILL.md:104`** (the line this task's own Q4
    sub-question echoes): it claims *"The `/todo next` ranking already
    factors deadlines, urgency ratio, and unblocks-others... Do not
    second-guess that ordering here; the IPM trusts it."* That claim is
    **stale relative to `todo/SKILL.md`'s current, authoritative behavior**
    (previous bullet) — `/todo next` is a flat queue walk today, no scoring.
    So `ipm/SKILL.md` is *also* describing a ranking mechanism that doesn't
    exist in the current `/todo next` — meaning IPM isn't even consuming a
    real deadline/urgency signal today, let alone computing one itself. Q4's
    answer holds, but via this direct contradiction, not merely the retired
    `priority:` field: there is no deadline/urgency-aware ranking anywhere in
    the current system (not in IPM, not in `/todo next`) for retiring IPM to
    put at risk. (This cross-skill doc drift — `ipm/SKILL.md:104` vs.
    `todo/SKILL.md`'s `next` — is itself a candidate for the follow-up
    doc-cleanup task below.)
  - `scheduled:` is already written **outside** any IPM commit: `/drive`'s
    "Important Notes" and Phase 3/Phase 7 call `_ipm/stamp-scheduled.sh`
    directly for every dependency/follow-up task, resolving the Monday via
    "committed IPM file → Project API → next-Monday fallback" — the
    next-Monday fallback already covers the no-IPM-ever-ran case, so this
    mechanic needs no change.
  - `retro/SKILL.md`'s bump-3x detector (Phase 1 step 10) and `/ipm` step 1's
    bump-2x reassessment both key **exclusively** off reading the last 2-3
    committed `*-ipm-weekly.md` files. `ccxp/SKILL.md:359` already guards
    this: *"Skip this block if no `*-ipm-weekly.md` exists yet"* — i.e. the
    detectors already no-op gracefully today; retiring the ceremony makes
    that no-op **permanent**, not newly broken.
  - `retro/SKILL.md` Phase 4b also references escalating bumped tasks to a
    `priority: High` frontmatter field — but per `/todo`'s own docs (above)
    that field is retired. This is a **pre-existing, separate drift** (not
    introduced by this decision) worth a follow-up cleanup regardless of the
    IPM outcome.
- **Assumed, not verified from this clone** (scope limit stated in the task):
  whether any *other* consumer repo's `/ccxp` install still runs a live
  Monday IPM against a real, configured GH Project board. The maintainer's
  2026-09-24 statement ("abandoned generally") is taken as the standing
  signal here; this design does not hard-delete any mechanic another repo
  might still be reading (`scheduled:`, the Project iteration mirror) — see
  Solution.
- Original framing, preserved — needs an `/incept`-style grill to work
  through:
  - Is IPM truly dead everywhere this skill is installed, or just
    unused by the human currently driving it? (Scope: this clone can only
    confirm ccxp-skills' own history; other consumer repos aren't
    accessible from here.)
  - If retired: what happens to `scheduled:` (currently read by consumer
    repos' GH Project sync script), and to `/retro`'s bump-3x/bump-2x
    detectors (which key off consecutive Tier-1 IPM commits)?
  - If kept but simplified: does the three-line budget split collapse to
    a flat points-based pull, or does it stay as a proportional split
    (just redenominated), per the two options surfaced in the
    T20260924-232855 conversation?
  - If neither retired nor kept as-is: what does "continuous `/todo
    next`-driven work" need that today's Phase 2a already provides
    (deadline/urgency-aware ranking, unblocks-others weighting) so nothing
    valuable is lost by dropping the ceremony around it?

## Solution

**Decision: retire the mandatory Monday IPM ceremony; keep its load-bearing
side-mechanics unchanged.** Not a full deletion of every `/ipm`/`/retro`
reference in one PR — that's a separate, properly-scoped mechanical task (see
follow-ups) — but the decision this task exists to make:

- `/ccxp` Phase 2a's Monday budget-cut (the three-line product/infra/slack
  split, the `ipm-weekly.md` commit) stops being part of the mandatory cron
  path. Continuous `/todo next` + `/drive` pulling off the flat
  `queue.md` priority order — what every actual commit in this repo's
  history already does — becomes the documented planning loop, not a
  workaround around an unused ritual.
- `/ipm` and `/incept` remain available as **optional, ad-hoc** tools — a
  human can still invoke `/ipm` for a deliberate iteration re-plan (e.g.
  release-boundary planning) in a repo that *does* have a configured GH
  Project board. Nothing about the mechanism is broken; it's demoted from
  "the cron always runs this" to "callable when wanted."
- **Unaffected, by design** (confirmed load-bearing elsewhere, not safe to
  touch here): `scheduled:` frontmatter + `_ipm/stamp-scheduled.sh`'s
  Monday-resolution fallback chain, and the GH Project iteration mirror
  (`sync-tasks-to-issues.py`) for any consumer repo that does have a board
  configured. These already function independently of whether the weekly
  ceremony itself runs (see Context verification above).
- **Narrower question (3-line budget split) answered as moot**: since the
  split only ever applied *inside* the ceremony being retired, it doesn't
  need a standalone redenomination decision. The risk the split guarded
  against (an infra task silently eating a feature's budget) is handled the
  same way every other reprioritization is handled today — `/top`
  (immediate) — which is the mechanism already in use, per `/todo`'s own
  retired-scoring-field note.
- **Alternatives considered and rejected**:
  - *Keep as-is* — rejected: zero executions in this repo's entire history
    is not "lightly used," it's inert; the ceremony's own skill docs (721 +
    373 lines) are pure unexercised maintenance burden.
  - *Keep but collapse the 3-line split to a flat points pull* — rejected as
    a half-measure: it still requires the weekly ceremony to exist and run,
    which the evidence says doesn't happen; simplifying a ritual nobody
    performs doesn't address the actual problem.
  - *Full immediate deletion of `/ipm`, `/retro`'s bump detectors, and every
    Phase 2a reference in one shot* — rejected for this task: that's a
    multi-file mechanical edit disproportionate to this task's own
    `estimation: 2`, and `/retro`'s bump detectors have a real (if currently
    unused) purpose for any consumer repo that *does* run IPM — deleting
    them is a separate, independently-reviewable change with its own
    blast-radius, not a decision-task's job to bundle in.
- **Mechanical follow-through, not decided here** — filed as separate
  task(s) at Phase 7 close (per the template's `## Closed` convention, not a
  standalone section in this design):
  1. Update `ccxp/SKILL.md` Phase 2a + the Mon/Fri cron table to describe
     the Monday ceremony as optional/ad-hoc rather than a mandatory cron
     step.
  2. Note in `retro/SKILL.md` (Phase 1 step 10 / Phase 4b) that the
     bump-3x/bump-2x detectors and the `priority: High` escalation they
     drive are dormant by design when no repo runs `/ipm`; separately flag
     the stale `priority: High` field reference and the stale
     `ipm/SKILL.md:104` claim about `/todo next`'s ranking (both
     pre-existing drift, unrelated to this decision, surfaced above).
  3. `lifecycle.md` (canonical source other repos point back to): add a
     line noting IPM/`scheduled:` board-mirroring is opt-in, so a consumer
     repo adopting this repo's conventions doesn't assume the weekly
     ceremony is required.

## Test plan

- [x] Confirm via `git log` that zero `*-ipm-weekly.md` files exist in this
      repo's history (command + output anchored in Context above).
- [x] Confirm `scheduled:`'s Monday-resolution fallback chain does not
      require a committed IPM file (`_ipm/stamp-scheduled.sh`'s documented
      "next-Monday fallback", cited in Context).
- [x] Confirm `retro`/`ccxp`'s bump detectors already guard the
      no-ipm-weekly-file case (`ccxp/SKILL.md:359`, cited in Context).
- [x] N/A automated test — this is a decision record, no code/script changed.

## Done criteria

- [x] Decision recorded with rationale and rejected alternatives (`##
      Solution` above).
- [x] Each of the task's four original sub-questions answered explicitly
      (Context + Solution: dead-everywhere-confirmed-here / assumed
      elsewhere; `scheduled:` and bump-detectors unaffected; 3-line split
      moot; `/todo next` already dropped the scoring the ceremony used to
      add).
- [x] Follow-up mechanical tasks filed for the skill-doc edits (see
      `## Solution`'s "Mechanical follow-through" list) — T20261002-219904,
      T20261002-245216, T20261002-359869 (below).

## Closed (2026-10-02)

- Design merged in **PR #239** (`t20260924-252293-design`), claim merged in
  **PR #238** (`t20260924-252293-claim`).
- Decision: retire `/ccxp`'s mandatory Monday IPM budget-cut ceremony;
  continuous `/todo next` + `/drive` off `queue.md` is the documented
  planning loop going forward. `/ipm`/`/incept` remain available as
  optional, ad-hoc tools. `scheduled:` frontmatter and the GH Project
  iteration mirror are unaffected — they already work independently of the
  ceremony.
- Independent review (dispatched via `Agent` tool) caught one substantive
  gap (Q4's evidence chain didn't engage `ipm/SKILL.md:104`'s own stale
  claim about `/todo next`'s ranking) and two minor structural nits — all
  fixed in a follow-up commit on the design PR before merge.
- **Follow-up tasks filed** (mechanical skill-doc edits, not decided here,
  staged into the next iteration):
  - T20261002-219904 — document the IPM ceremony as optional/ad-hoc in
    `ccxp/SKILL.md`.
  - T20261002-245216 — note retro's bump-3x/2x detectors as dormant-by-design,
    and clean up two stale cross-references (`priority: High`,
    `ipm/SKILL.md:104`).
  - T20261002-359869 — note in `lifecycle.md` that IPM/`scheduled:`
    board-mirroring is opt-in.
- What's external/unverified: whether any *other* consumer repo's `/ccxp`
  install still runs a live Monday IPM against a configured GH Project
  board — out of scope for this clone to confirm; the decision deliberately
  leaves every mechanic another repo might depend on (`scheduled:`, the
  Project iteration mirror) unchanged, so this is not a hard blocker on the
  decision itself.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class (decision
  record, no code/script changed).
- Verification (`superpowers:verification-before-completion`): yes —
  evidence re-checked directly against live files (`git log`,
  `todo/SKILL.md`, `ccxp/SKILL.md:359`, `ipm/SKILL.md:104`) before and after
  the independent review pass.
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't get
  stuck; no test failures or contradictory behavior to diagnose.
- Receiving code review (`superpowers:receiving-code-review`): yes —
  dispatched an independent review agent on the design PR diff; one
  substantive finding (stale evidence chain on Q4) was fixed rather than
  argued with, after confirming the finding was correct against
  `ipm/SKILL.md:104` and `todo/SKILL.md` directly; two minor structural nits
  fixed alongside.
