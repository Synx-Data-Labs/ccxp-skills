---
name: ipm
description: Use when the user explicitly asks to run or re-run the Iteration Planning Meeting — carry over in-flight work, commit queue-ordered picks into ipm-weekly.md, drain the previous iteration, sync the ROADMAP
disable-model-invocation: false
---

# IPM

The Iteration Planning Meeting commits a slice of the week's focused work. `dev/TODO/queue.md` is already the single ordered priority list (see `/todo`) — this skill does not re-rank it or run a separate scoring pass; it walks that one order top to bottom, auto-including in-flight work and budget-cutting whatever candidates are left. Output is a single `ipm-weekly.md` file that the daily standup grades against and the Friday retro grades final on.

- **Optional, ad-hoc tool — not an automatic step.** T20260924-252293 retired the mandatory Monday budget-cut ceremony: continuous `/todo next` + `/drive` off `queue.md` is the documented day-to-day planning loop, and `/ccxp` no longer invokes this skill automatically (neither cron nor interactive mode day-of-week-triggers it — see `ccxp/SKILL.md` Phase 2a). `/ipm` stays available for a deliberate iteration re-plan — e.g. a repo running a configured GH Project board that wants an explicit weekly commit — invoked directly, any day.
- **Callable ad hoc, any day** — re-scope after a design changes, or re-budget-cut after a priority shift. This skill has no day-of-week check of its own; "Monday" below just names the conventional cadence for a repo that chooses to run it weekly.
- **Missed Monday** (for a repo that does run it weekly) — the next Monday's IPM covers the gap by default (no automatic mid-week catch-up); invoke `/ipm` directly for a deliberate ad-hoc re-plan.
- **Cron vs. interactive mode** — reads `CCXP_CRON_MODE` from the environment (inherited, no argument needed), same branching `/ccxp`'s own "Cron mode vs. interactive mode" section describes. Step 3 (pre-IPM design pass) is interactive-only, skipped when `CCXP_CRON_MODE=1`.

## Workflow

**`<skills-root>` placeholder**, used throughout: every `<skills-root>/X/Y.sh` reference means take
the "Base directory for this skill" value reported at load (e.g. `/home/ci/ccxp-skills/ipm`), drop
the trailing `/ipm`, and substitute that literal absolute path.

- Never run these cwd-relative, never `cd` into `<skills-root>`.
- cwd must stay the **working/target repo** — the `dev/TODO/`, `dev/JOURNAL/`, `git log`, and
  `$(pwd)/dev` commands used elsewhere here assume it. A headless cron session's cwd is commonly
  the target repo, not the ccxp-skills checkout.
- Exception: step 5b's ephemeral roadmap clone `cd`s into its own throwaway directory for that
  phase only.

Before step 0's first command below, verify the substituted path is real and fail loudly if not:

```bash
[ -x "<skills-root>/_gh/gh.sh" ] || { echo "ipm: <skills-root> (<the literal path you substituted>) doesn't look like a ccxp-skills checkout — check the Base directory reported above" >&2; exit 1; }
```

### 0 Capture this IPM's Scheduled date

Snapshot the IPM's Monday date as the `Scheduled` value to stamp on every picked task:

```bash
SCHEDULED=$(date -d 'monday' +%Y-%m-%d 2>/dev/null || date -v-Mon +%Y-%m-%d)
echo "This IPM is Scheduled = ${SCHEDULED}"
```

Every task added (or re-committed) to this IPM — carry-over, new pick, infra/tooling, or mid-week addition — gets `scheduled: ${SCHEDULED}` written into its task-file YAML frontmatter (handled in step 5). The IPM file header (prose document, not a task file) also records `**Scheduled**: ${SCHEDULED}`.

**Source of truth for iteration**: the GH Project (your-org/projects/1) defines iterations with explicit start/end dates.

- The Scheduled date on each task file maps to whichever iteration contains it. A separate mirror workflow — the per-repo `.github/scripts/sync-tasks-to-issues.py` (push-triggered `sync`, plus `reconcile`/`backfill` dispatch modes) — reads `scheduled` and sets the matching Iteration on add, move, **and in-place edit** (an IPM carry-over is a `scheduled:` rewrite on a file that stays in `dev/TODO/`, and in-place edits are honored).
- The skill never computes an iteration integer client-side — `ls | wc -l` would silently desync if a Monday IPM is ever skipped or backfilled.

For mid-week additions, the Scheduled date is the current iteration's Monday (i.e. this week's IPM commit).

### 0.1 Sweep stale tasks before scoping

`/ipm` runs both unattended (via `/ccxp`'s cron) and interactively (see "Cron mode vs. interactive mode" above). Per maintainer guidance: autonomous-only restrictions on `/todo sweep` are no longer needed — git history is the audit trail; the sweep operation runs with the maintainer's standing permission for autonomous-mode invocations:

1. **Inline the stale-blocker auto-fix** — run `/todo sweep`'s Phase 1 recipe verbatim (autonomous, no approval needed: it only strikes resolved blockers in the Status field and links to the JOURNAL entry that closed them). Idempotent — a no-op when no stale blockers exist. Don't duplicate that recipe here; `/todo sweep`'s own "Phase 1: Fix stale blockers" section is the source of truth.

2. **Run the full prune step** (`/todo sweep` Phase 3 — auto-close / park). Same scoring as `/todo sweep` documents — `Done`/superseded tasks auto-close straight to `dev/JOURNAL/` (no approval needed), while indefinitely-blocked / `Revisit`-status legacy tasks are surfaced as Park candidates and only moved to `dev/PARKING/` after the maintainer approves. Git history captures every move; if a sweep was over-eager, revert is one `git revert` away.

3. **Skip cleanly if zero candidates.** Don't add a `## Housekeeping` block if there's nothing to surface; daily summaries shouldn't carry empty sections.

Append the sweep summary (counts of struck-blockers, auto-closed, parked) to the standup `## Housekeeping` section (via `/ccxp` Phase 1) so the maintainer sees what changed each day.

### 1 Carry over WIP

Read all `dev/TODO/*.md` files. Tasks with Status `In Progress` or `Review` are **automatic carry-overs** — they are already in flight and the WIP discipline keeps them in this week's commit until they ship. List them and sum their (revised, if previously estimated) Estimations.

**Claimed tasks carry too, regardless of Status.** A task with a non-empty `claimed_by:` is in-flight by virtue of the claim (a live session — this box or a peer `@…` — committed to it), even when its Status is still `Design` or `Open`. Include every claimed task in the carry-over set here, not just `In Progress`/`Review`.

- Otherwise a `Design`+claimed task is invisible to both this step and step 1.5 (never in a `## Considered but cut` table), its `scheduled:` never advances, and it silently strands on a stale iteration on the board.
- **A claim pins ownership of the work, not the iteration it's tracked in:** the IPM still has full discretion to *defer* a claimed task to a later iteration instead of carrying it (set its `scheduled:` to a future Monday in step 5).
- What it must never do is leave a claimed task's `scheduled:` untouched and let the board drift from the IPM's intent.

**Bump-2x reassessment — force a decision before the third commit.** An unconditionally-carried task becomes a "we'll get to it" comfort blanket that absorbs accountability without shipping. `/retro`'s bump-3x detector catches this, but only retrospectively, after the third wasted week — catch it here, one step earlier. (Both detectors only fire for a repo that actually runs this ceremony — dormant by design, not broken, wherever `/ipm` is never invoked.)

- **Detection** (same file-date join key `/retro` uses, no Project-side iteration mapping): read the last 2 committed `*-ipm-weekly.md` files (`PREV_IPM=$(bash <skills-root>/_ipm/current.sh)` gives the newest; the one before it is the next-older `dev/JOURNAL/*-ipm-weekly.md` by date).
- For each task in this week's carry-over set, check whether it appears as a carried/in-flight row in the committed list of **both** prior IPMs — if so, committing it now would be its 3rd consecutive carry: flag it **"Bumped 2x — reassess"**.
- For each flagged task, force an explicit disposition below — never a silent re-carry.

- **Re-commit** — keep it as a carry-over, but record a one-line "still the right call" reason in the IPM `## Notes` (e.g. "blocker cleared this week, finishing now").
- **Won't fix** — close it (journal-move stub), exactly as a task was after its third bump in a real observed case.
- **Defer** — move it out of this iteration: advance its `scheduled:` to a future Monday and pre-append it to that Monday's stub, identical to the step 5 "Cut candidates — advance, never clear" mechanics.

**Unattended (the cron default): auto-defer + a Slack note.**

- Never silently re-commit, and never hard-block the IPM waiting on a human — a blocking wait would stall the whole unattended commit.
- Auto-defer the flagged task per the bullet above and post one line to `#acme-dev-notifications`: `*IPM bump-2x*: T<id> deferred — carried 3 IPMs without shipping; reassess (re-commit / Won't fix / defer) by reply.`
- `/retro`'s bump-3x detection is unchanged — it remains the safety net for anything that slips through.

### 1.5 Seed carry-over candidates (from last IPM's cuts)

Cuts must not vanish. Read the previous IPM file — `PREV_IPM=$(bash <skills-root>/_ipm/current.sh)`.

- This resolves to **last week's** IPM: step 1.5 runs before step 5, so this week's file still only exists as the pre-IPM staging stub, which the helper excludes (header-sniff) — the newest *committed* IPM is last week's, not a naive `ls -t … | head -1` (which would grab the future-dated staging stub instead).
- Collect the task IDs from its `## Considered but cut` table. Drop any whose task file is no longer in `dev/TODO/` (closed/parked since), and any already captured as a carry-over in step 1 (dedupe — in-flight auto-carry wins).

The survivors are **carry-over candidates** — tasks a prior IPM deliberately deferred. They enter this IPM's candidate pool alongside `/todo next` (step 2), but are **not** auto-committed and their `scheduled:` is **not** advanced by being a candidate.

- The IPM still decides per task in step 4: **accept** (place in the committed list → gets `scheduled` in step 5) or **re-cut** (re-list under `## Considered but cut` with a reason).
- No silent drops — a perpetually-deferred task recurring across consecutive IPM files is exactly the chronic-deferral signal `/retro`'s bump-counter surfaces.

### 2 Pick candidates

Run `/todo next` to get the top 5 ranked tasks (`Design` or `Open`) off `dev/TODO/queue.md`. **There is no separate scoring here** — `queue.md`'s position *is* the priority, and `/todo next` is a flat top-to-bottom walk of it (skipping only `Done`/peer-claimed/legacy-`Revisit` entries); it does not compute deadline, urgency, or unblocks-others weighting itself (see `../todo/SKILL.md` Workflow: `next`). Do not second-guess that ordering here, and do not re-derive a ranking the queue already encodes — if the order is wrong, that's a `/top`/`/stage`/hand-edit fix to `queue.md`, not something to work around in this step.

**Also fold in the staged candidates.** Look for this week's pre-IPM stub directly at `dev/JOURNAL/${SCHEDULED}-ipm-weekly.md` — not via `_ipm/current.sh`, which deliberately skips it (the selector returns the last *committed* IPM, never the still-`Pre-IPM staging` stub).

- If it exists, read its `## Candidates` section — each entry was appended via `/stage` through the week and carries its own one-line rationale ("Why this iteration"), a signal the plain queue walk doesn't carry on its own.
- Merge these into the candidate pool alongside the `/todo next` top-5, dedupe by task ID.
- A staged candidate is a deliberate human/skill nomination, so weight its rationale when ordering — but it still passes through the step 4 budget cut like any other pick.

**Cron-mode eligibility filter.**

- When `CCXP_CRON_MODE=1`, drop any candidate whose `status:` is still `Open` (it hasn't been through an interactive pre-IPM design pass — step 3 is skipped this run). Only `status: Design` candidates with a non-empty `estimation` are eligible for this week's commit.
- If the filtered pool is thinner than the product budget line can absorb, record it under `## Notes` (e.g. "3 candidates skipped — still `Open`, awaiting a pre-IPM pass") rather than reaching into `Open` tasks to fill the gap.
- Interactive runs (`CCXP_CRON_MODE` unset/`0`) skip this filter and proceed straight to step 3.

### 3 Pre-IPM design pass — interactive only (skipped when `CCXP_CRON_MODE=1`)

**This step never runs unattended** — it's where business priorities get weighed and a candidate becomes ready to implement, a judgment call reserved for a human (see "Cron mode vs. interactive mode" above).

- `CCXP_CRON_MODE=1` → skip straight to step 4 with whatever step 2 left in the pool.
- Otherwise, the rest of this step describes the interactive pairing-session flow:

For each candidate, time-box ~10–15 min. **The design pass is `/incept`** — run `/incept T<id>` (see `incept/SKILL.md`), which interviews the human in frontier rounds and, on confirmation, writes the Design section + Test Plan and any estimation revision into the task file. This phase wraps that call with the lifecycle bookkeeping `/incept` deliberately does not touch:

1. **Grill it.** `/incept T<id>`. It reads the task's Problem (and any existing Design section — a refresh re-validates the assumptions rather than starting cold), asks the frontier rounds, and stops at its synthesis for a go/no-go. Do not run the rounds yourself or summarize on the user's behalf — the whole point is the human answering.
2. **Escalate and skip when a decision can't be made here.** If the synthesis leaves an *Open* item that blocks implementation and needs someone not at the keyboard, file a Slack escalation via the existing protocol (`#acme-dev-notifications`) and **skip this task for this week** — do not claim it. It re-enters the candidate pool next IPM. (Non-blocking *Open* items are fine — they stay recorded in the Design section and get resolved in `/drive` Phase 2.)
3. **Confirm the estimate landed.** `/incept` step 4 rewrites `estimation:` and appends `Estimation revised from {old} to {new}: {reason}` to the Design section when the estimate moved — check the frontmatter before the budget cut (step 4) consumes it. A free-text grill (no task file) writes nothing: file the task via `/new-task` first, then re-run.
4. **Claim the task before touching its status** — mirroring to the board alone leaves it
   unclaimed mid-pass and pickable by a peer session's `/todo next`:

   ```bash
   bash <skills-root>/_session/task_claim.sh release-others <task-id>
   bash <skills-root>/_session/task_claim.sh acquire <task-id>
   ```

   `acquire` sets `claimed_by` **and** `status: In Progress` as a side effect. A
   grilled-but-not-yet-implemented task belongs in `Design`, so correct the
   status back — same two-step pattern `/drive` Phase 1 uses for "a design
   PR will still run":

   ```bash
   bash <skills-root>/_session/status.sh <task-id> Design
   ```

   Both calls are best-effort; the frontmatter is the source of truth.
5. Carry-overs do **not** get a re-grill — once a task is In Progress, the design is presumed adequate. If implementation has revealed the design is wrong, that's a separate "stop and re-scope" event handled outside the IPM ritual.

The grilled task files (Design sections, estimation revisions, claims) are left uncommitted by `/incept`; they land together with the IPM file in step 5's commit PR, not one PR per candidate.

### 4 Budget cut

1. Set the weekly budget — start with **20h** of focused-work capacity (≈ half of a 40h week; the other half is PR review, CI watching, RCA, Slack, standup, IPM/retro overhead). **Split it into three explicit lines** so the trade-off is visible instead of absorbed silently:
   - **~12h product** (carry-over + new picks) — the feature/bug/release work below.
   - **~4h infrastructure / tooling** — internal `/drive` + `/ccxp` skill iteration, task-mirror / Project-board plumbing, CI / test scaffolding, and other process work that ships no product artifact but recurs nearly every week. Budgeting it as a first-class line surfaces the trade-off rather than letting it eat slack or preempt the product line invisibly.
   - **~4h slack** — nightly RCA churn, Slack escalations, and the unexpected. This line **is** the ~20% buffer; mid-week additions eat from it.

   The retro grades estimate-vs-actual across all three lines and feeds back into next week's budget.
2. Subtract step 1's carry-over set from the **~12h product** line first — it's unconditional, not subject to the walk below.
3. Walk the candidate pool from step 2 top-down, in its existing queue order (with revised estimations), accumulating against the remaining product budget. The cut line is: "next task would exceed the ~12h product line."
4. **Pick the infrastructure / tooling line explicitly** — treat it the same as the product-line walk above: name the commitments (task file IDs, estimation, "why now") in the IPM file's `## Infrastructure / tooling` table, rather than letting them happen invisibly. Skill-iteration / plumbing / CI-scaffolding tasks tracked in `dev/TODO/` are eligible; if the foreseeable work isn't filed as tasks, file it so it enters the board. Don't pre-commit the full ~4h — leave part open for the week's emergent tooling needs, but record what you *do* foresee so it's planned, not preemptive.
5. If after all candidates fit the product line still has ≥ 10h headroom, expand the candidate pool (re-run `/todo next` excluding already-picked tasks) and keep packing until the product line is reasonably committed.
6. Don't pad to 100% — the **~4h slack line is the buffer (≈20%)**. Aim for ~80% commit (product + infra/tooling = ~16h), ~20% slack.

### 5 Write ipm-weekly.md + tag committed task files with Scheduled

Write `dev/JOURNAL/YYYY-MM-DD-ipm-weekly.md`.

- **Revise-in-place if a `/stage` stub already exists at this path** — `/stage` may have already created `dev/JOURNAL/${SCHEDULED}-ipm-weekly.md` during the prior week, header `**Status**: Pre-IPM staging` plus a populated `## Candidates` section. Don't create cold (it'd clobber the staged rationale): edit in place, populate the Committed table, and **drop the `**Status**: Pre-IPM staging` marker line** so `_ipm/current.sh` starts selecting it as committed. Create cold only when no stub exists.
- Deliverables: (a) the committed list — carry-over + new picks + infra/tooling, one table, in `queue.md` order (see template below), (b) cuts with reasons, (c) recommended execution order, (d) notes/escalations, (e) a disposition for every carry-over candidate from step 1.5 (accepted into the committed list, or re-cut under `## Considered but cut`). The execution order is what `/drive` consumes day-to-day; without it, the IPM is just a wishlist.

**Render every task reference as a clickable markdown link.** In every table below (Committed this iteration, Carry-over candidates, Mid-week additions, Considered but cut, Recommended execution order), the `Task` column is a link, not bare text — `[T<id>](<issue-url>)`, built via the same map-free resolver the daily standup uses (`/ccxp` Phase 1.4):

```bash
source <skills-root>/_taskid/url.sh
taskid-mdlink T<id>      # -> [T<id>](https://github.com/…/issues/…)
```

`taskid-mdlink` defaults to `--issue` mode (unlike `taskid-slacklink`'s blob-mode default): an IPM file is written once and never regenerated, so an issue URL is the right choice — a blob-mode link baked in at write time can rot if the referenced task later moves (`dev/TODO/` → `dev/JOURNAL/` on close), the issue URL never does.

In the same step, for each task in the committed list (carry-over, new pick, or infra/tooling), edit the task file in `dev/TODO/` to set `scheduled: ${SCHEDULED}` in its YAML frontmatter.

- **Always overwrite**, never skip — when a task moves between IPMs (carried over, or a business-priority shift pulling it from a later iteration), the new IPM's Monday becomes the authoritative scheduled date. The task file's git log preserves the full `scheduled` history; retro's bump-counter walks the IPM files themselves rather than the task file's current value.
- **Applies to claimed / peer-owned tasks too** — being claimed does not exempt a task from `scheduled:` advancement. Editing only that field is an IPM planning action (re-tracking the iteration), not a touch on the peer's branch/PR/work — not a collective-ownership violation.
- The board's Iteration field is *derived* from `scheduled:` (via the per-repo `sync-tasks-to-issues.py`) — a carry-over whose `scheduled:` is left stale stays pinned to the old iteration on the board even though the IPM prose "carried" it. Carrying a task in the prose and advancing its `scheduled:` are one action, not two: do both, every claimed task included.

**Cut candidates — advance, never clear.** For every task placed under this IPM's `## Considered but cut`, set `scheduled:` in its `dev/TODO/` frontmatter to **next** Monday — never delete the field (`scheduled` is update-forward-only). Compute next Monday from `${SCHEDULED}`:

```bash
NEXT_MON=$(date -d "${SCHEDULED} +7 days" +%F 2>/dev/null || date -j -v+7d -f %Y-%m-%d "${SCHEDULED}" +%F)
```

Then **pre-append** each cut task to next-Monday's pre-IPM stub `dev/JOURNAL/${NEXT_MON}-ipm-weekly.md` under `## Candidates`, as a `### Re-surfaced YYYY-MM-DD (cut at IPM)` sub-section (the same shape `/stage` uses for duplicates).

- If that stub doesn't exist yet, create it from the `/stage` header template first.
- This keeps the board (`iteration:@next`) and the doc stub consistent between now and next Monday.
- Step 1.5 re-folds the same cut at next IPM and **dedupes by task ID**, so a pre-appended cut is not double-listed.

```markdown
# Weekly Focus: YYYY-MM-DD (Mon) → YYYY-MM-DD (Fri)

**Scheduled**: {SCHEDULED}
**Budget**: 20h focused-work
**IPM duration**: ~{N} min ({start time}–{end time})

## Committed this iteration

*One list, in `queue.md` order — no separate carry-over/new-pick tables. `Status` shows what's auto-carried (`In Progress`/`Review`/claimed — never cut by the budget walk) vs. a new pick (`Design`/`Open` — went through the step 4 budget cut). `Line` shows which budget line it counts against (step 4).*

| # | Task | Status | Line | Est | Cumulative | Deadline | Why |
|---|------|--------|------|-----|------------|----------|-----|
| 1 | T... | In Progress | Product | 2h | 2h | 2026-04-30 | Carry-over |
| 2 | T... | Open | Product | 1h | 3h | — | Unblocks T... |
| 3 | T... | Design | Product | 8h (1d) | 11h | 2026-05-08 | ARM deadline next week |
| i1 | T... | Design | Infra/tooling | 2h | 13h | — | `/ccxp` Phase-X fix surfaced by last retro |

**Cut line at 11h product** — leaves the ~12h product line ~1h spare; the infra/tooling + slack lines (step 4) make up the rest of the 20h.

*Infra/tooling rows (step 4 item 4) are named here explicitly at IPM commit so they're planned, not preemptive — leave part of the ~4h open for emergent needs rather than pre-committing all of it. Empty is fine on a light week — but record it as a deliberate `(none foreseen)` row, not a silent omission.*

## Carry-over candidates (deferred at {prev IPM date})

*Seeded in step 1.5 from last IPM's `Considered but cut`. Each must be dispositioned: accepted into the committed list above (gets `scheduled`) or re-cut below. Omit the section if there were no prior cuts.*

| Task | Prior cut reason | Disposition this IPM |
|------|------------------|----------------------|
| T... | {reason from last IPM} | Committed / re-cut: {reason} |

## Mid-week additions (appended after IPM commit)

*Initialize empty at IPM commit. Tasks added throughout the week — via `/rca` red-pipeline auto-promotion (see `/rca` Step 6), `/stage` skill, or manual append — land here.*

| # | Task | Est | Added | Why this iteration |
|---|------|-----|-------|--------------------|
| (none yet) | | | | |

**Mid-week addition budget rules**:
- No fixed budget — these eat from the slack reserved at IPM (typical: 4h of slack on a 20h budget after ~80% commit across the committed list + the infra/tooling line).
- Hard cap: if cumulative mid-week hours exceed the slack reserve, the additions are stretch goals — flag in retro that they pushed committed work into next week.
- Red-pipeline auto-promotions (from `/rca` Step 6) are exempt from the cap — recurring pipeline failures compound; they always belong in the current iteration regardless of budget.

## Recommended execution order

Sequenced by **dependency unblock + business priority + parallelism (labrun async ↔ foreground)**. Carry-over and new picks are interleaved so customer-facing / high-business-priority work starts early; tech-debt items land after the high-priority track is moving. List the tasks 1..N across the week, day-by-day, with a one-line "why this slot" each.

### Mon (Day 1) — {theme} (~Xh focused)

| # | Task | Est | Why this slot |
|---|------|-----|---------------|
| 1 | T... | 30m | Unblocks tasks 3, 7 — small, fast |
| 2 | T... | 2h  | Depends on #1 |

### Tue (Day 2) — {theme} (~Xh)

| # | Task | Est | Why this slot |
|---|------|-----|---------------|
| 3 | T... | 3h  | Foreground while #4 labrun runs async |
| 4 | T... | 2h  | Long labrun — dispatch early to amortize |

(Continue through Wed / Thu / Fri.)

### Parallelism that makes the budget fit

| Slot | Async (labrun running) | Foreground |
|---|---|---|
| Mon PM | T...A labrun (~2h) | T...B foreground |

### Critical-path checkpoints

| Day | Checkpoint | If missed |
|---|---|---|
| End of Mon | T... merged; T... dispatched | Slip everything 1 day |

## Considered but cut

| Task | Reason |
|------|--------|
| T... | Design pass revealed 3d effort, breaks budget — re-rank next IPM |
| T... | Blocked on customer reply — waiting |

## Notes

- Design pass on T... raised ABI compatibility question → escalated to Slack thread {url}
```

### 5a Drain the previous iteration (HARD GATE — the IPM commit is not final until this is green)

Step 5 advances `scheduled:` for the committed list (carry-overs + new picks) and for cut candidates. But a third class slips through **both** paths: an `Open`/`Design` task with an **empty** claim that was scheduled into the *previous* iteration and neither got picked this IPM nor cut.

- Step 1's carry covers in-flight (`In Progress`/`Review`) + `claimed_by` tasks; step 5's cut-advance covers what this IPM explicitly cuts.
- An unclaimed not-started task that nobody touched is caught by **neither** and silently strands on the now-closed iteration on the board.

The maintainer rule: **at IPM end, every previous-iteration board item that is not terminal (`Done`/`Parked`) must be migrated out.** Enforce it with the hard gate `<skills-root>/_ipm/ipm-iteration-drain-check.sh`. Run **after** step 5 (so the picks' `scheduled:` are already advanced) and **before** the IPM is considered committed:

1. **List the strand-class offenders.** Query the board for items still on the previous iteration whose status is non-terminal — the gate does this for you (run it; on a non-zero exit it *prints* each offender).
   - The previous iteration is resolved by the board's iteration **start-date window** (the current iteration is the latest `startDate` ≤ today; the previous is the next-earlier distinct `startDate`) — **never** a client-side counter (`ls | wc -l` desyncs the instant a Monday IPM is skipped or backfilled). Same date-window discipline as `_ipm/current.sh`.
   - The gate **partitions** offenders by repo: **same-repo** offenders (the `--home-repo`, auto-detected from this clone's `git remote get-url origin`) are **blocking** (exit 1 — the IPM can drain them by editing their task files); **cross-repo** offenders (e.g. `hub-repo` items the build-pipeline clone cannot edit) are printed as **non-blocking `⚠` warnings** so the unattended commit is never deadlocked on items it has no way to drain.
   - **Lint-frozen sub-partition:** a same-repo offender whose task file fails the changed-mode `Lint task frontmatter` check (pre-existing non-allowlisted fields) can't have `scheduled:` advanced without an unrelated lint red. The gate probes each with `lint_tasks.py --changed` and downgrades lint-frozen ones to the same non-blocking `⚠` (fail-safe: unclassifiable stays blocking). An IPM whose only remaining same-repo offenders are lint-frozen reaches exit 0 instead of deadlocking.
2. **Drain each offender** — applies to the **clean** same-repo (blocking) offenders; cross-repo and lint-frozen warnings are surfaced for the maintainer, not drained here. For every listed same-repo task, decide and act exactly like step 5's per-task disposition:
   - **carry** it (advance its task-file `scheduled:` to this IPM's `${SCHEDULED}` and add it to the committed list), or
   - **defer** it (advance `scheduled:` to a future Monday and pre-append it to that Monday's `## Candidates` stub, per step 5's "Cut candidates — advance, never clear").
   - Either way `scheduled:` moves **forward** — never deleted. The board's Iteration field is *derived* from `scheduled:` via the per-repo `sync-tasks-to-issues.py`, so bumping `scheduled:` is what actually re-tracks the item off the closed iteration.
3. **Gate the commit.** Re-run the check; the IPM is **not committed** until it exits **0**:

   ```bash
   # Runs in ccxp's home clone; reads the live board via `gh project item-list`.
   # Default terminal set is "Done|Parked"; --home-repo/--owner auto-detected
   # from this clone's git remote `origin` — no repo/org hardcoded in the script itself.
   bash <skills-root>/_ipm/ipm-iteration-drain-check.sh
   #   exit 0 → previous iteration clean of CLEAN (drainable) SAME-REPO offenders (cross-repo AND lint-frozen offenders, if any, were printed as ⚠ warnings and do NOT block) — proceed to step 5b
   #   exit 1 → it printed CLEAN (editable) same-repo offenders still pinned to the previous iteration — drain them (step 2) and re-run
   #   exit 2 → usage error (bad flag/arg, or --home-repo/--owner could not be auto-detected and none was given)
   ```

   Defaults are correct for a normal Monday run (previous-iteration window, home-repo, and project number are all auto-detected from this clone's `git remote get-url origin`). Run `bash <skills-root>/_ipm/ipm-iteration-drain-check.sh --help` for the override flags (forcing the date window, the terminal-status regex, a non-default repo/project) — rarely needed.

   The gate is **non-destructive** (read-only — it lists, it doesn't edit); the draining in step 2 is what mutates `scheduled:`. A clean previous iteration (or the very first IPM, when no previous iteration exists) is a no-op exit 0.

### 5b Update the ROADMAP doc in the configured hub repo (cross-repo)

The multi-IPM ROADMAP doc lives at `dev/ROADMAP.md` in a separate hub repo.

- The hub is **required config, not a hardcoded repo name** (`ROADMAP_TARGET_REPO="<owner>/<repo>"`, resolved the same way as every other `~/.claude/.env`-backed var in this suite: already-exported wins, else `~/.claude/.env`).
- After writing this week's IPM file, propagate the commit forward into the ROADMAP via an ephemeral clone of that hub repo (same pattern as `/drive` Phase 1.5 cross-repo dispatch). The `/ipm` run never touches the maintainer's working clone of the hub repo.

```bash
TARGET=$(bash <skills-root>/ccxp/scripts/update-roadmap.sh clone)
cd "$TARGET"
```

`update-roadmap.sh clone` clones `ROADMAP_TARGET_REPO` into a fresh `/tmp` directory on a dated `roadmap/ipm-*` branch and prints its path — the `/ipm` run never touches the maintainer's working clone of that repo. It exits with a clear error (no clone attempted) if `ROADMAP_TARGET_REPO` is unset.

If `dev/ROADMAP.md` doesn't yet exist (first run, before the ROADMAP doc exists), create it from the template in the task file's "Initial content shape" section, then proceed. Otherwise, apply these updates in place:

1. **Promote this week's commitments** from "Deferred / on watch" → "Near-term" (or shift them within the near-term table if already there). Pull the task list from step 4's budget cut output (the committed list — carry-over + new picks).
2. **Demote anything cut** in step 4 → "Deferred / on watch" with a 1-line "why cut" reason (mirrors the "Considered but cut" section of the IPM file).
3. **Advance the "Last updated" line** to today's date + link to this IPM's commit PR (resolve the PR URL after step 5's IPM file is pushed and PR'd in build-pipeline).
4. **Archive shipped entries**: near-term entries whose week is past AND whose tasks shipped (per `dev/JOURNAL/<date>-T<id>-*.md` evidence) move to a `## Recently shipped` section at the bottom of ROADMAP.md. Keep only the last 4 weeks there — older entries roll off the live table; git blame plus the unchanged per-week JOURNAL entries preserve the rest. A display budget, not a data-loss window.

After edits, once this IPM's build-pipeline commit PR is up and its URL known:

```bash
bash <skills-root>/ccxp/scripts/update-roadmap.sh commit-pr --target "$TARGET" --bp-pr-url "<build-pipeline IPM PR URL>"
```

Runs the doc-lint guard (shared script, runs for real here too now), commits, pushes, opens the PR against the configured `ROADMAP_TARGET_REPO`, and removes the ephemeral clone.

This is a small, focused PR (~5-10 lines changed per IPM). Auto-mergeable per `dev/guidelines.md` carve-out — pure status-shift content, no design decisions inside.

If any step fails (clone, edit, commit, push, PR-create): slack the maintainer `*IPM 5b*: ROADMAP update aborted — {step} failed: {error}`. The IPM file in build-pipeline is already committed; the ROADMAP can be hand-updated later or retried via a re-run of just step 5b.

### 6 Slack the focus

Send to `#acme-dev-notifications` via MCP `slack_send_message`. On send failure, apply the same
webhook fallback as `/ccxp` Phase 1.4 — this is a weekly, guaranteed-to-fire send in
the same failure-prone path:

```
*Weekly Focus* (YYYY-MM-DD)
- Budget: 20h, committed: {N}h
- Carry-over: {M} tasks ({list})
- New picks: {K} tasks ({list})
- Top deadline: {task} due {date}
```
