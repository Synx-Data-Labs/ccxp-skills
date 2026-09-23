---
name: ipm
description: Use when the user explicitly asks to run or re-run the Monday Iteration Planning Meeting — carry over WIP, budget-cut Tier 1/2 picks into ipm-weekly.md, drain the previous iteration, sync the ROADMAP — or when /ccxp Phase 2a calls into this on Mondays
disable-model-invocation: false
---

# IPM

The Iteration Planning Meeting commits the week's focused work. Tier 1 (in-flight) WIP from last week carries over automatically; Tier 2 (not-started) picks are designed-and-estimated before the cut. Output is a single `ipm-weekly.md` file that the daily standup grades against and the Friday retro grades final on.

Callable ad hoc any day — e.g. to re-scope tasks after a design changes, or re-budget-cut after a priority shift — not just on the Monday `/ccxp` normally invokes it on. `/ccxp` Phase 2a owns the "only on Mondays" cron trigger and calls into this skill; this skill itself has no day-of-week check. If a Monday is missed (holiday, off day), the next Monday's IPM covers the gap by default — there is no *automatic* mid-week catch-up run — but a human can always invoke `/ipm` directly for a deliberate ad-hoc re-plan.

**Cron mode vs. interactive mode:** this skill reads `CCXP_CRON_MODE` directly from the environment (inherited from whatever session invoked it — no argument needed) to decide cron-mode vs. interactive-mode branching, exactly as `/ccxp`'s own "Cron mode vs. interactive mode" section describes. Step 3 (the pre-IPM design pass) is interactive-only and is skipped whenever `CCXP_CRON_MODE=1`.

## Workflow

**`<skills-root>` placeholder, used throughout this document (T20260918-414727):**
every `<skills-root>/X/Y.sh` reference below means: take the "Base
directory for this skill" value reported when this skill loaded (e.g.
`/home/ci/ccxp-skills/ipm`), drop the trailing `/ipm`, and substitute
that literal absolute path — never run these cwd-relative, and never
`cd` into it. cwd must stay the **working/target repo** for the
`dev/TODO/`, `dev/JOURNAL/`, `git log`, and `$(pwd)/dev` commands used
elsewhere in this document — an `/ipm` session's cwd is not guaranteed
to sit anywhere inside the ccxp-skills checkout (a headless cron
session's cwd is commonly the target repo instead). (The one deliberate
exception is step 5b's ephemeral roadmap clone, which `cd`s into its own
throwaway directory for that phase only — not a case this preamble
governs.) Before step 0's first command below, verify the substituted
path is real and fail loudly if not:

```bash
[ -x "<skills-root>/_gh/gh.sh" ] || { echo "ipm: <skills-root> (<the literal path you substituted>) doesn't look like a ccxp-skills checkout — check the Base directory reported above" >&2; exit 1; }
```

### 0 Capture this IPM's Scheduled date

Snapshot the IPM's Monday date as the `Scheduled` value to stamp on every picked task:

```bash
SCHEDULED=$(date -d 'monday' +%Y-%m-%d 2>/dev/null || date -v-Mon +%Y-%m-%d)
echo "This IPM is Scheduled = ${SCHEDULED}"
```

Every Tier 1 / Tier 2 / Tier 3 task added (or re-committed) to this IPM gets `scheduled: ${SCHEDULED}` written into its task-file YAML frontmatter (handled in step 5). The IPM file header (prose document, not a task file) also records `**Scheduled**: ${SCHEDULED}`.

**Source of truth for iteration**: the GH Project (your-org/projects/1) defines iterations with explicit start/end dates. The Scheduled date on each task file maps to whichever iteration contains it. Mapping is done by a separate mirror workflow — the per-repo `.github/scripts/sync-tasks-to-issues.py` (push-triggered `sync`, plus `reconcile`/`backfill` dispatch modes) reads `scheduled` and sets the matching Iteration on add, move, **and in-place edit** (in-place was a no-op until T20260526-277041, which is why an IPM carry-over — a `scheduled:` rewrite on a file that stays in `dev/TODO/` — silently never reached the board). The skill never computes an iteration integer client-side — `ls | wc -l` would silently desync if a Monday IPM is ever skipped or backfilled.

For mid-week Tier 3 additions, the Scheduled date is the current iteration's Monday (i.e. this week's IPM commit).

### 0.1 Sweep stale tasks before scoping

`/ipm` runs both unattended (via `/ccxp`'s cron) and interactively (see "Cron mode vs. interactive mode" above). Per maintainer guidance: autonomous-only restrictions on `/todo sweep` are no longer needed — git history is the audit trail; the sweep operation runs with the maintainer's standing permission for autonomous-mode invocations:

1. **Inline the stale-blocker auto-fix** (`/todo sweep` Phase 1 — autonomous; no approval needed because all it does is strike resolved blockers in the Status field and link to the JOURNAL entry that closed them):

   ```bash
   for f in dev/TODO/*.md; do
     # If the file's Status mentions "Blocked by T{id}" and T{id} is no longer
     # in dev/TODO/ (moved to JOURNAL or PARKING), strike that blocker line and
     # update Status accordingly. Implementation lives in /todo's sweep
     # workflow Phase 1; copy that recipe here verbatim.
     # (Idempotent — running daily is a no-op when no stale blockers exist.)
     :  # placeholder; the actual recipe is the awk/sed loop from /todo sweep
   done
   ```

   (The actual recipe is the same logic /todo sweep documents in its "Phase 1: Fix stale blockers" section. Don't duplicate that prose; reference it as the source of truth.)

2. **Run the full prune step** (`/todo sweep` Phase 3 — auto-close / park). Same scoring as `/todo sweep` documents — `Done`/superseded tasks auto-close straight to `dev/JOURNAL/` (no approval needed), while indefinitely-blocked / `Revisit`-status legacy tasks are surfaced as Park candidates and only moved to `dev/PARKING/` after the maintainer approves. Git history captures every move; if a sweep was over-eager, revert is one `git revert` away.

3. **Skip cleanly if zero candidates.** Don't add a `## Housekeeping` block if there's nothing to surface; daily summaries shouldn't carry empty sections.

Append the sweep summary (counts of struck-blockers, auto-closed, parked) to the standup `## Housekeeping` section (via `/ccxp` Phase 1) so the maintainer sees what changed each day.

### 1 Carry over WIP (Tier 1)

Read all `dev/TODO/*.md` files. Tasks with Status `Coding` or `Review` are **automatic carry-overs** — they are already in flight and the WIP discipline keeps them in this week's commit until they ship. List them and sum their (revised, if previously estimated) Estimations.

**Claimed tasks carry too, regardless of Status.** A task with a non-empty `claimed_by:` is in-flight by virtue of the claim (a live session — this box or a peer `@…` — committed to it), even when its Status is still `Design` or `Open`. Include every claimed task in the carry-over set here, not just `Coding`/`Review`. Otherwise a `Design`+claimed task is invisible to *both* this step *and* step 1.5 (it was never in a `## Considered but cut` table), its `scheduled:` never advances, and it silently strands on a stale iteration on the board — the recurring leak that left T20260611-324774 and T20260610-028036 pinned to Iteration 10. **A claim pins ownership of the work, not the iteration it's tracked in:** the IPM still has full discretion to *defer* a claimed task to a later iteration instead of carrying it (set its `scheduled:` to a future Monday in step 5). What it must never do is leave a claimed task's `scheduled:` untouched and let the board drift from the IPM's intent.

**Bump-2x reassessment — force a decision before the third commit.** A Tier-1 carry-over carried forward unconditionally becomes a "we'll get to it" comfort blanket: it absorbs IPM accountability week after week without shipping. `/retro`'s bump-3x detector catches this, but only *retrospectively* — after the third wasted week. Catch it here, up front, one step earlier. **Detection (same file-date join key `/retro` uses — no Project-side iteration mapping):** read the **last 2 committed** `*-ipm-weekly.md` files (`PREV_IPM=$(bash <skills-root>/_ipm/current.sh)` gives the newest committed IPM; the one before it is the next-older `dev/JOURNAL/*-ipm-weekly.md` by date), and for each task in *this* week's Tier-1 carry-over set check whether it appears in the **Tier-1 table of both** prior IPMs. If it does, committing it now would be its **3rd consecutive** Tier-1 commit → flag it **"Bumped 2x — reassess"**. For each flagged task, force an explicit disposition — never a silent re-carry:

- **Re-commit** — keep it in Tier 1, but record a one-line "still the right call" reason in the IPM `## Notes` (e.g. "blocker cleared this week, finishing now").
- **Won't fix** — close it (journal-move stub), exactly as a task was after its third bump in a real observed case.
- **Defer** — move it out of this iteration: advance its `scheduled:` to a future Monday and pre-append it to that Monday's stub, identical to the step 5 "Cut candidates — advance, never clear" mechanics.

**Unattended (the cron default): auto-defer + a Slack note.** Do not silently re-commit, and do not hard-block the IPM waiting on a human (a blocking wait would stall the whole unattended commit). Auto-defer the flagged task per the bullet above and post one line to `#claude-notification`: `*IPM bump-2x*: T<id> deferred — carried 3 IPMs without shipping; reassess (re-commit / Won't fix / defer) by reply.` This keeps the IPM moving while taking the zombie off auto-pilot. `/retro`'s bump-3x detection is unchanged — it remains the safety net for anything that still slips through.

### 1.5 Seed carry-over candidates (from last IPM's cuts)

Cuts must not vanish. Read the previous IPM file — `PREV_IPM=$(bash <skills-root>/_ipm/current.sh)`. This resolves to last week's IPM because step 1.5 runs **before** step 5: this week's file still exists only as the pre-IPM staging stub, which the helper excludes (header-sniff), so the newest *committed* IPM is last week's (see T20260604-194697 — a naive `ls -t … | head -1` instead grabbed the future-dated staging stub). Collect the task IDs from its **`## Considered but cut`** table. Drop any whose task file is no longer in `dev/TODO/` (closed/parked since) and any already captured as Tier 1 in step 1 (dedupe — in-flight auto-carry wins).

The survivors are **carry-over candidates**: tasks a prior IPM deliberately deferred. They enter this IPM's Tier 2 candidate pool *alongside* `/todo next` (step 2) — but they are **not** auto-committed, and their `scheduled:` is **not** advanced by being a candidate. The IPM still decides per task in step 4: **accept** (place in a Tier → gets `scheduled` in step 5) or **re-cut** (re-list under this IPM's `## Considered but cut` with a reason). No silent drops — a perpetually-deferred task then recurs across consecutive IPM files, which is exactly the chronic-deferral signal `/retro`'s bump-counter surfaces.

### 2 Pick candidates (Tier 2)

Run `/todo next` to get the top 5 ranked Tier 2 tasks (`Design` or `Open`). The `/todo next` ranking already factors deadlines, urgency ratio, and unblocks-others — see `../todo/SKILL.md` Workflow: `next`. Do not second-guess that ordering here; the IPM trusts it.

**Also fold in the staged candidates.** Look for this week's pre-IPM stub at `dev/JOURNAL/${SCHEDULED}-ipm-weekly.md` directly — *not* via `_ipm/current.sh`, which deliberately skips it (the selector returns the last *committed* IPM, never the still-`Pre-IPM staging` stub). If it exists, read its `## Candidates` section. Each entry was appended via `/stage` throughout the week and **carries its own one-line rationale** ("Why this iteration") — the signal `/todo next`'s mechanical ranking can't reconstruct. Merge these into the Tier 2 candidate pool alongside the `/todo next` top-5; dedupe by task ID. A staged candidate is a deliberate human/skill nomination, so weight its rationale when ordering — but it still passes through the step 4 budget cut like any other pick.

**Cron-mode eligibility filter.** When `CCXP_CRON_MODE=1`, drop any candidate whose `status:` is still `Open` (i.e., it hasn't been through an interactive pre-IPM design pass — step 3 is skipped below, so nothing promotes it to `Design` this run). Only `status: Design` candidates with a non-empty `estimation` are eligible for this week's Tier 2. If the filtered pool is thinner than the product budget line can absorb, that's expected — record it under `## Notes` (e.g. "3 candidates skipped — still `Open`, awaiting a pre-IPM pass") rather than reaching into `Open` tasks to fill the gap. Interactive runs (`CCXP_CRON_MODE` unset/`0`) skip this filter and proceed straight to step 3.

### 3 Pre-IPM design pass — interactive only (skipped when `CCXP_CRON_MODE=1`)

**This step never runs unattended.** It's where business priorities get weighed and a candidate task actually becomes ready to implement — exactly the kind of judgment call reserved for a human at the keyboard (see "Cron mode vs. interactive mode" above). When `CCXP_CRON_MODE=1`, skip straight to step 4 with whatever the step 2 filter left in the pool. The rest of this step describes the interactive pairing-session flow:

For each Tier 2 candidate, time-box ~10–15 min. **The design pass is `/incept`** — run `/incept T<id>` (see `incept/SKILL.md`), which interviews the human in frontier rounds and, on confirmation, writes the Design section + Test Plan and any estimation revision into the task file. This phase wraps that call with the lifecycle bookkeeping `/incept` deliberately does not touch:

1. **Grill it.** `/incept T<id>`. It reads the task's Problem (and any existing Design section — a refresh re-validates the assumptions rather than starting cold), asks the frontier rounds, and stops at its synthesis for a go/no-go. Do not run the rounds yourself or summarize on the user's behalf — the whole point is the human answering.
2. **Escalate and skip when a decision can't be made here.** If the synthesis leaves an *Open* item that blocks implementation and needs someone not at the keyboard, file a Slack escalation via the existing protocol (`#claude-notification`) and **skip this task for this week** — do not claim it. It re-enters the candidate pool next IPM. (Non-blocking *Open* items are fine — they stay recorded in the Design section and get resolved in `/drive` Phase 2.)
3. **Confirm the estimate landed.** `/incept` step 4 already rewrote `estimation:` and appended `Estimation revised from {old} to {new}: {reason}` to the Design section when the estimate moved; check the frontmatter before the step 4 budget cut consumes it. If the pass was a free-text grill (no task file), it wrote nothing — file the task via `/new-task` first, then re-run.
4. **Claim the task before touching its status** (T20260610-248248 — this step
   previously only mirrored to the board, leaving the task unclaimed mid-pass
   and pickable by a peer session's `/todo next`):

   ```bash
   bash <skills-root>/_session/task_claim.sh release-others <task-id>
   bash <skills-root>/_session/task_claim.sh acquire <task-id>
   ```

   `acquire` sets `claimed_by` **and** `status: Coding` as a side effect. A
   grilled-but-not-yet-implemented task belongs in `Design`, so correct the
   status back — same two-step pattern `/drive` Phase 1 uses for "a design
   PR will still run":

   ```bash
   bash <skills-root>/_session/status.sh <task-id> Design
   ```

   Both calls are best-effort; the frontmatter is the source of truth.
5. Tier 1 carry-overs do **not** get a re-grill — once a task is in Coding, the design is presumed adequate. If Coding has revealed the design is wrong, that's a separate "stop and re-scope" event handled outside the IPM ritual.

The grilled task files (Design sections, estimation revisions, claims) are left uncommitted by `/incept`; they land together with the IPM file in step 5's commit PR, not one PR per candidate.

### 4 Budget cut

1. Set the weekly budget — start with **20h** of focused-work capacity (≈ half of a 40h week; the other half is PR review, CI watching, RCA, Slack, standup, IPM/retro overhead). **Split it into three explicit lines** so the trade-off is visible instead of absorbed silently:
   - **~12h product** (Tier 1 carry-over + Tier 2 new picks) — the feature/bug/release work below.
   - **~4h infrastructure / tooling** — internal `/drive` + `/ccxp` skill iteration, task-mirror / Project-board plumbing, CI / test scaffolding, and other process work that ships no product artifact but recurs nearly every week. Historically this lands *off*-IPM and preempts product work invisibly (a real observed retro: the task-mirror feature consumed two days and cut a paired feature from that iteration; the two prior iterations showed the same pattern). Budgeting it as a first-class line surfaces the trade-off rather than letting it eat slack or preempt Tier 2.
   - **~4h slack** — nightly RCA churn, Slack escalations, and the unexpected. This line **is** the ~20% buffer; Tier 3 mid-week additions eat from it.

   The retro grades estimate-vs-actual across all three lines and feeds back into next week's budget.
2. Subtract Tier 1 carry-over from the **~12h product** line first.
3. Walk Tier 2 candidates top-down (with revised estimations), accumulating against the remaining product budget. The cut line is: "next task would exceed the ~12h product line."
4. **Pick the infrastructure / tooling line explicitly** — treat it like Tier 2: name the commitments (task file IDs, estimation, "why now") in the IPM file's `## Infrastructure / tooling` table, rather than letting them happen invisibly. Skill-iteration / plumbing / CI-scaffolding tasks tracked in `dev/TODO/` are eligible; if the foreseeable work isn't filed as tasks, file it so it enters the board. Don't pre-commit the full ~4h — leave part open for the week's emergent tooling needs, but record what you *do* foresee so it's planned, not preemptive.
5. If after all candidates fit the product line still has ≥ 10h headroom, expand the candidate pool (re-run `/todo next` excluding already-picked tasks) and keep packing until the product line is reasonably committed.
6. Don't pad to 100% — the **~4h slack line is the buffer (≈20%)**. Aim for ~80% commit (product + infra/tooling = ~16h), ~20% slack.

### 5 Write ipm-weekly.md + tag Tier-1/2 task files with Scheduled

Write `dev/JOURNAL/YYYY-MM-DD-ipm-weekly.md`. **Revise-in-place if a `/stage` stub already exists at this path** — when candidates were staged during the prior week, `/stage` already created `dev/JOURNAL/${SCHEDULED}-ipm-weekly.md` with header `**Status**: Pre-IPM staging` and a populated `## Candidates` section. In that case do NOT create cold (it would clobber the staged rationale): edit the existing file in place — populate the Tier tables, and **drop the `**Status**: Pre-IPM staging` marker line** so the file reads as a committed IPM (this is what makes `_ipm/current.sh` start selecting it). Only create the file cold when no stub exists. The IPM's deliverables are: (a) Tier 1/2 commit, (b) cuts with reasons, **(c) recommended execution order interleaving the two tiers**, (d) notes/escalations, and (e) a disposition for every carry-over candidate from step 1.5 (accepted into a Tier, or re-cut under `## Considered but cut`). The execution order is what `/drive` consumes day-to-day; without it, the IPM is just a wishlist.

**Render every task reference as a clickable markdown link (T20260608-353422).** In every table below (Carry-over, Carry-over candidates, New picks, Infrastructure/tooling, Tier 3, Considered but cut, Recommended execution order), the `Task` column is a link, not bare text — `[T<id>](<issue-url>)`, built via the same map-free resolver the daily standup uses (`/ccxp` Phase 1.4):

```bash
source <skills-root>/_taskid/url.sh
taskid-mdlink T20260427-298901      # -> [T20260427-298901](https://github.com/…/issues/…)
```

`taskid-mdlink` defaults to `--issue` mode (unlike `taskid-slacklink`'s blob-mode default) — the *right* choice here, because an IPM file is written once and never regenerated: a blob-mode link baked in at write time can still rot if the referenced task later moves (`dev/TODO/` → `dev/JOURNAL/` on close), while the issue URL never does.

In the same step, for each Tier 1 / Tier 2 task picked, edit the task file in `dev/TODO/` to set `scheduled: ${SCHEDULED}` in its YAML frontmatter. **Always overwrite**, never skip — when a task moves between IPMs (Tier 1 carry-over from a previous week, or business-priority shift pulling it from a later iteration), the new IPM's Monday becomes the authoritative scheduled date. The git log of the task file preserves the full `scheduled` history; retro's bump-counter walks the IPM files themselves rather than reading the task file's current `scheduled` value.

**This applies to claimed / peer-owned tasks too — being claimed does not exempt a task from `scheduled:` advancement.** Editing only the `scheduled:` field of a peer-claimed task is an IPM planning action — it re-tracks which iteration the work belongs to; it does **not** touch the peer's branch/PR/work and is therefore **not** a violation of the anti-steal / collective-ownership rule. The board's Iteration field is *derived* from `scheduled:` (via the per-repo `sync-tasks-to-issues.py`), so a carry-over whose `scheduled:` is left stale stays pinned to the old iteration on the board even though the IPM prose "carried" it. That is exactly how T20260320-000029 ended up in the 06-22 Tier 1b table yet still displayed on Iteration 10 — listed but never re-`scheduled:`. Carrying a task in the prose and advancing its `scheduled:` are one action, not two: do both, every claimed task included.

**Cut candidates — advance, never clear.** For every task placed under this IPM's `## Considered but cut`, set `scheduled:` in its `dev/TODO/` frontmatter to **next** Monday — never delete the field (`scheduled` is update-forward-only). Compute next Monday from `${SCHEDULED}`:

```bash
NEXT_MON=$(date -d "${SCHEDULED} +7 days" +%F 2>/dev/null || date -j -v+7d -f %Y-%m-%d "${SCHEDULED}" +%F)
```

Then **pre-append** each cut task to next-Monday's pre-IPM stub `dev/JOURNAL/${NEXT_MON}-ipm-weekly.md` under `## Candidates`, as a `### Re-surfaced YYYY-MM-DD (cut at IPM)` sub-section (the same shape `/stage` uses for duplicates). If that stub doesn't exist yet, create it from the `/stage` header template first. This keeps the board (`iteration:@next`) and the doc stub consistent between now and next Monday. Step 1.5 re-folds the same cut at next IPM and **dedupes by task ID**, so a pre-appended cut is not double-listed.

```markdown
# Weekly Focus: YYYY-MM-DD (Mon) → YYYY-MM-DD (Fri)

**Scheduled**: {SCHEDULED}
**Budget**: 20h focused-work
**IPM duration**: ~{N} min ({start time}–{end time})

## Carry-over (Tier 1 — finish first)

| # | Task | Status | Est | Cumulative | Deadline |
|---|------|--------|-----|------------|----------|
| 1 | T... | Coding | 2h  | 2h         | 2026-04-30 |

## Carry-over candidates (deferred at {prev IPM date})

*Seeded in step 1.5 from last IPM's `Considered but cut`. Each must be dispositioned: accepted into a Tier above (gets `scheduled`) or re-cut below. Omit the section if there were no prior cuts.*

| Task | Prior cut reason | Disposition this IPM |
|------|------------------|----------------------|
| T... | {reason from last IPM} | Tier 2 / re-cut: {reason} |

## New picks (Tier 2)

| # | Task | Original est | Revised est | Cumulative | Deadline | Why |
|---|------|--------------|-------------|------------|----------|-----|
| 2 | T... | 1h | 1h     | 3h  | —          | Unblocks T... |
| 3 | T... | 4h | 8h (1d)| 11h | 2026-05-08 | ARM deadline next week |

**Cut line at 11h** — leaves the ~12h product line ~1h spare; the rest of the 20h is the infra/tooling + slack lines below.

## Infrastructure / tooling (~4h line)

*The explicit budget line for skill iteration / plumbing / CI-scaffolding work (step 4 item 4). Named here at IPM commit so it's planned, not preemptive. Leave part open for emergent needs; don't pre-commit the full ~4h. Empty is fine on a light week — but record it as a deliberate `(none foreseen)`, not a silent omission.*

| # | Task | Est | Why this iteration |
|---|------|-----|--------------------|
| i1 | T... | 2h | `/ccxp` Phase-X fix surfaced by last retro |

## Tier 3 — Mid-week additions (appended after IPM commit)

*Initialize empty at IPM commit. Tasks added throughout the week — via `/rca` red-pipeline auto-promotion (see `/rca` Step 6), `/stage` skill (T20260513-103349), or manual append — land here.*

| # | Task | Est | Added | Why this iteration |
|---|------|-----|-------|--------------------|
| (none yet) | | | | |

**Tier 3 budget rules**:
- No fixed budget — Tier 3 eats from the slack reserved at IPM (typical: 4h of slack on a 20h budget after ~80% commit across Tier 1 + Tier 2 + the infra/tooling line).
- Hard cap: if cumulative Tier 3 hours exceed the slack reserve, the additions are stretch goals — flag in retro that they pushed Tier 1/Tier 2 work into next week.
- Red-pipeline auto-promotions (from `/rca` Step 6) are exempt from the cap — recurring pipeline failures compound; they always belong in the current iteration regardless of budget.

## Recommended execution order

Sequenced by **dependency unblock + business priority + parallelism (labrun async ↔ foreground)**. Tier 1 and Tier 2 are interleaved so customer-facing / high-business-priority work starts early; tech-debt items land after the high-priority track is moving. List the tasks 1..N across the week, day-by-day, with a one-line "why this slot" each.

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

Step 5 advances `scheduled:` for the Tier-1/2 picks (carry-overs) and for cut candidates. But a third class slips through **both** paths: an `Open`/`Design` task with an **empty** claim that was scheduled into the *previous* iteration and neither got picked this IPM nor cut. The step 1 carry covers in-flight (`Coding`/`Review`) + `claimed_by` tasks; step 5's cut-advance covers what this IPM explicitly cuts; an unclaimed not-started task that nobody touched is caught by **neither** and silently strands on the now-closed iteration on the board (the recurring leak — T20260320-000029 sat on Iteration 10 while the prose "carried" it; T20260622-147834 filed the gate for exactly this).

The maintainer rule: **at IPM end, every previous-iteration board item that is not terminal (`Done`/`Parked`) must be migrated out.** Enforce it with the hard gate `<skills-root>/_ipm/ipm-iteration-drain-check.sh` (shipped by T20260622-147834; T20260623-811944 wires it here; moved out of build-pipeline's own scripts/ and generalized by T20260719-111051). Run **after** step 5 (so the picks' `scheduled:` are already advanced) and **before** the IPM is considered committed:

1. **List the strand-class offenders.** Query the board for items still on the previous iteration whose status is non-terminal — the gate does this for you (run it; on a non-zero exit it *prints* each offender). The previous iteration is resolved by the board's iteration **start-date window** (the current iteration is the latest `startDate` ≤ today; the previous is the next-earlier distinct `startDate`) — **never** a client-side counter (`ls | wc -l` desyncs the instant a Monday IPM is skipped or backfilled). Same date-window discipline as `_ipm/current.sh`. The gate **partitions** offenders by repo (Option C — T20260628-592642): **same-repo** offenders (the `--home-repo`, auto-detected from this clone's `git remote get-url origin`) are **blocking** (exit 1 — the IPM can drain them by editing their task files); **cross-repo** offenders (e.g. `hub-repo` items the build-pipeline clone cannot edit) are printed as **non-blocking `⚠` warnings** so the unattended commit is never deadlocked on items it has no way to drain. (Forward-compatible with end-state options A/B in T20260628-592642 — Option C is the deadlock-safety valve, not the final design.) **Lint-frozen sub-partition (T20260628-951477):** a same-repo offender whose task file fails the changed-mode `Lint task frontmatter` check — pre-existing non-allowlisted fields, the unresolved T20260626-353630 schema-fork class — **cannot** have its `scheduled:` advanced without an unrelated lint red. The gate probes each same-repo offender (`lint_tasks.py --changed`) and downgrades the **lint-frozen** ones to the same non-blocking `⚠` warning; only **clean** (editable) same-repo offenders block (fail-safe: anything the probe can't classify stays **blocking** — no silent exemption). So an IPM whose only remaining same-repo offenders are lint-frozen reaches **exit 0** instead of deadlocking — the real fix is resolving T20260626-353630.
2. **Drain each offender** — this applies to the **clean** same-repo (blocking) offenders; cross-repo and lint-frozen warnings are surfaced for the maintainer, not drained here (a lint-frozen file can't be edited until T20260626-353630 lands). For every listed same-repo task, decide and act exactly like step 5's per-task disposition: **carry** it (advance its task-file `scheduled:` to this IPM's `${SCHEDULED}` and place it in a Tier) or **defer** it (advance `scheduled:` to a future Monday and pre-append it to that Monday's `## Candidates` stub, per step 5's "Cut candidates — advance, never clear"). Either way `scheduled:` moves **forward** — never deleted. The board's Iteration field is *derived* from `scheduled:` via the per-repo `sync-tasks-to-issues.py`, so bumping `scheduled:` is what actually re-tracks the item off the closed iteration.
3. **Gate the commit.** Re-run the check; the IPM is **not committed** until it exits **0**:

   ```bash
   # Runs in ccxp's home clone; reads the live board via `gh project item-list`.
   # Default terminal set is "Done|Parked"; --home-repo/--owner auto-detected
   # from this clone's git remote `origin` (T20260719-111051) — no repo/org
   # hardcoded in the script itself.
   bash <skills-root>/_ipm/ipm-iteration-drain-check.sh
   #   exit 0 → previous iteration clean of CLEAN (drainable) SAME-REPO offenders (cross-repo AND lint-frozen offenders, if any, were printed as ⚠ warnings and do NOT block) — proceed to step 5b
   #   exit 1 → it printed CLEAN (editable) same-repo offenders still pinned to the previous iteration — drain them (step 2) and re-run
   #   exit 2 → usage error (bad flag/arg, or --home-repo/--owner could not be auto-detected and none was given)
   ```

   Overrides (rarely needed — the defaults are correct for a normal Monday run):
   - `--prev-start YYYY-MM-DD` — force the previous iteration's start date, skipping date-window resolution (useful when a skipped/backfilled Monday makes the window ambiguous, or for a dry-run against a known iteration).
   - `--today YYYY-MM-DD` — override "today" for the window resolution.
   - `--terminal "Done|Parked"` — the regex alternation of statuses that count as drained. `Parked` is terminal **on purpose** (a parked task is deliberately set aside in `dev/PARKING/`, not stranded work to force-migrate); don't narrow it to just `Done` or the gate will demand you migrate parked items.
   - `--home-repo OWNER/NAME` — the repo whose offenders **block** (default: auto-detected from this clone's `git remote get-url origin` — the repo ccxp runs in and can drain). Offenders in any **other** repo are reported as non-blocking warnings. Override only when the clone's remote doesn't match the repo you want treated as home (e.g. a fork).
   - `--repo-path DIR` — where same-repo task files are resolved for the lint-frozen probe, AND the source of the `--home-repo`/`--owner` auto-detect (default `.`, the IPM's own clone). `LINT_TASKS_PY` overrides the linter path (default `../repo-conventions/scripts/lint_tasks.py`); `IPM_DRAIN_FROZEN_IDS` forces the frozen set for tests. (T20260628-951477)
   - `--project N` — board number (default `1`). `--owner ORG` — board owner (default: auto-detected from this clone's git remote, same source as `--home-repo`).

   The gate is **non-destructive** (read-only — it lists, it doesn't edit); the draining in step 2 is what mutates `scheduled:`. A clean previous iteration (or the very first IPM, when no previous iteration exists) is a no-op exit 0.

### 5b Update the ROADMAP doc in the configured hub repo (cross-repo)

The multi-IPM ROADMAP doc lives at `dev/ROADMAP.md` in a separate hub repo (filed by T20260510-836314) — the hub is **required config, not a hardcoded repo name** (`ROADMAP_TARGET_REPO="<owner>/<repo>"`, resolved the same way as every other `~/.claude/.env`-backed var in this suite: already-exported wins, else `~/.claude/.env`; T20260827-280088). After writing this week's IPM file, propagate the commit forward into the ROADMAP via an ephemeral clone of that hub repo (same pattern as `/drive` Phase 1.5 cross-repo dispatch — T20260513-403409). The `/ipm` run never touches the maintainer's working clone of the hub repo.

```bash
TARGET=$(bash <skills-root>/ccxp/scripts/update-roadmap.sh clone)
cd "$TARGET"
```

`update-roadmap.sh clone` clones `ROADMAP_TARGET_REPO` into a fresh `/tmp` directory on a dated `roadmap/ipm-*` branch and prints its path — the `/ipm` run never touches the maintainer's working clone of that repo. It exits with a clear error (no clone attempted) if `ROADMAP_TARGET_REPO` is unset.

If `dev/ROADMAP.md` doesn't yet exist (first run before T20260510-836314 Phase 1 ships), create it from the template in the task file's "Initial content shape" section, then proceed. Otherwise, apply these updates in place:

1. **Promote this week's commitments** from "Deferred / on watch" → "Near-term" (or shift them within the near-term table if already there). Pull the task list from step 4's budget cut output (Tier 1 + Tier 2 picks).
2. **Demote anything cut** in step 4 → "Deferred / on watch" with a 1-line "why cut" reason (mirrors the "Considered but cut" section of the IPM file).
3. **Advance the "Last updated" line** to today's date + link to this IPM's commit PR (resolve the PR URL after step 5's IPM file is pushed and PR'd in build-pipeline).
4. **Archive shipped entries**: any near-term entries whose week is now in the past AND whose tasks shipped (per `dev/JOURNAL/<date>-T<id>-*.md` evidence in build-pipeline) move to a `## Recently shipped` section at the bottom of ROADMAP.md. **"Drop off" semantics**: keep this section to the last 4 weeks; older entries roll out of the live table — git blame on ROADMAP.md preserves the row-by-row edit history, and per-week JOURNAL entries (`<date>-ipm-weekly.md`, `<date>-retro-weekly.md`) remain unchanged in build-pipeline. The 4-week window is a display budget, not a data-loss window.

After edits, once this IPM's build-pipeline commit PR is up and its URL known:

```bash
bash <skills-root>/ccxp/scripts/update-roadmap.sh commit-pr --target "$TARGET" --bp-pr-url "<build-pipeline IPM PR URL>"
```

Runs the doc-lint guard (shared script, runs for real here too now — T20260719-111051), commits, pushes, opens the PR against the configured `ROADMAP_TARGET_REPO`, and removes the ephemeral clone.

This is a small, focused PR (~5-10 lines changed per IPM). Auto-mergeable per `dev/guidelines.md` carve-out — pure status-shift content, no design decisions inside.

If any step fails (clone, edit, commit, push, PR-create): slack the maintainer `*IPM 5b*: ROADMAP update aborted — {step} failed: {error}`. The IPM file in build-pipeline is already committed; the ROADMAP can be hand-updated later or retried via a re-run of just step 5b.

### 6 Slack the focus

Send to `#claude-notification` via MCP `slack_send_message`. On send failure, apply the same
webhook fallback as `/ccxp` Phase 1.4 (T20260717-433409) — this is a weekly, guaranteed-to-fire send in
the same failure-prone path:

```
*Weekly Focus* (YYYY-MM-DD)
- Budget: 20h, committed: {N}h
- Carry-over: {M} tasks ({list})
- New picks: {K} tasks ({list})
- Top deadline: {task} due {date}
```
