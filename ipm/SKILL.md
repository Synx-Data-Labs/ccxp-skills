---
name: ipm
description: Use when the user explicitly asks to run or re-run the Iteration Planning Meeting — carry over in-flight work, commit queue-ordered picks into ipm-weekly.md, drain the previous iteration, update the ROADMAP
---

# IPM

The Iteration Planning Meeting commits a slice of the week's focused work. `dev/TODO/queue.md` is already the single ordered priority list (see `/todo`) — this skill does not re-rank it or run a separate scoring pass; it walks that order top to bottom, auto-including in-flight work and committing whatever candidates fit this iteration.

Output is a single `ipm-weekly.md` file that the daily standup grades against and the Friday retro grades final on.

- **Optional, ad-hoc tool — not an automatic step.** T20260924-252293 retired the mandatory Monday commit ceremony: continuous `/todo next` + `/drive` off `queue.md` is the documented day-to-day planning loop, and `/ccxp` no longer invokes this skill automatically (neither cron nor interactive mode day-of-week-triggers it — see `ccxp/SKILL.md` Phase 2a). `/ipm` stays available for a deliberate iteration re-plan — e.g. a repo that wants an explicit weekly commit snapshot in `dev/JOURNAL/` — invoked directly, any day.
- **Callable ad hoc, any day** — re-scope after a design changes, or re-commit after a priority shift. This skill has no day-of-week check of its own; "Monday" below just names the conventional cadence for a repo that chooses to run it weekly.
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

**Source of truth for iteration**: the task files themselves — there is no GitHub Project board. `scheduled:` in a task's own frontmatter, plus the committed `dev/JOURNAL/*-ipm-weekly.md` files, fully answer "what's in / left from iteration N." Step 5a's drain gate (below) and `/retro`'s bump-counter both walk these plain files directly.

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

- Otherwise a `Design`+claimed task is invisible to both this step and step 1.5 (never in a `## Considered but cut` table), its `scheduled:` never advances, and it silently strands on a stale iteration.
- **A claim pins ownership of the work, not the iteration it's tracked in:** the IPM still has full discretion to *defer* a claimed task to a later iteration instead of carrying it (set its `scheduled:` to a future Monday in step 5).
- What it must never do is leave a claimed task's `scheduled:` untouched and let it drift from the IPM's intent.

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

Run `/todo next` to get the top 5 ranked tasks (`Design` or `Open`) off `dev/TODO/queue.md`. **There is no separate scoring** — `queue.md`'s position *is* the priority; `/todo next` is a flat top-to-bottom walk (skipping only `Done`/peer-claimed/legacy-`Revisit`), not a deadline/urgency/unblocks computation (see `../todo/SKILL.md` Workflow: `next`).

Do not second-guess that ordering, and do not re-derive a ranking the queue already encodes — a wrong order is a `/top`/`/stage`/hand-edit fix to `queue.md`, not something to work around here.

**Also fold in the staged candidates.** Look for this week's pre-IPM stub directly at `dev/JOURNAL/${SCHEDULED}-ipm-weekly.md` — not via `_ipm/current.sh`, which deliberately skips it (the selector returns the last *committed* IPM, never the still-`Pre-IPM staging` stub).

- If it exists, read its `## Candidates` section — each entry was appended via `/stage` through the week and carries its own one-line rationale ("Why this iteration"), a signal the plain queue walk doesn't carry on its own.
- Merge these into the candidate pool alongside the `/todo next` top-5, dedupe by task ID.
- A staged candidate is a deliberate human/skill nomination, so weight its rationale when ordering — but it still passes through step 4's commit decision like any other pick.

**Cron-mode eligibility filter.**

- When `CCXP_CRON_MODE=1`, drop any candidate whose `status:` is still `Open` (it hasn't been through an interactive pre-IPM design pass — step 3 is skipped this run). Only `status: Design` candidates with a non-empty `estimation` are eligible for this week's commit.
- If the filtered pool is thin, record it under `## Notes` (e.g. "3 candidates skipped — still `Open`, awaiting a pre-IPM pass") rather than reaching into `Open` tasks to fill the gap.
- Interactive runs (`CCXP_CRON_MODE` unset/`0`) skip this filter and proceed straight to step 3.

### 3 Pre-IPM design pass — interactive only (skipped when `CCXP_CRON_MODE=1`)

**This step never runs unattended** — it's where business priorities get weighed and a candidate becomes ready to implement, a judgment call reserved for a human (see "Cron mode vs. interactive mode" above).

- `CCXP_CRON_MODE=1` → skip straight to step 4 with whatever step 2 left in the pool.
- Otherwise, the rest of this step describes the interactive pairing-session flow:

For each candidate, time-box ~10–15 min. **The design pass is `/incept`** — run `/incept T<id>` (see `incept/SKILL.md`), which interviews the human in frontier rounds and, on confirmation, writes the Design section + Test Plan and any estimation revision into the task file. This phase wraps that call with the lifecycle bookkeeping `/incept` deliberately does not touch:

1. **Grill it.** `/incept T<id>`. It reads the task's Problem (and any existing Design section — a refresh re-validates the assumptions rather than starting cold), asks the frontier rounds, and stops at its synthesis for a go/no-go. Do not run the rounds yourself or summarize on the user's behalf — the whole point is the human answering.
2. **Escalate and skip when a decision can't be made here.** If the synthesis leaves an *Open* item that blocks implementation and needs someone not at the keyboard, file a Slack escalation via the existing protocol (`#acme-dev-notifications`) and **skip this task for this week** — do not claim it. It re-enters the candidate pool next IPM. (Non-blocking *Open* items are fine — they stay recorded in the Design section and get resolved in `/drive` Phase 2.)
3. **Confirm the estimate landed.** `/incept` step 4 rewrites `estimation:` and appends `Estimation revised from {old} to {new}: {reason}` to the Design section when the estimate moved — check the frontmatter before step 4 consumes it. A free-text grill (no task file) writes nothing: file the task via `/new-task` first, then re-run.
4. **Claim the task before touching its status** — an unclaimed task stays
   pickable mid-pass by a peer session's `/todo next`:

   ```bash
   bash <skills-root>/_session/task_claim.sh release-others <task-id>
   bash <skills-root>/_session/task_claim.sh acquire <task-id>
   ```

   `acquire` writes `claimed_by` **and** `status: In Progress` directly into
   the task file's own frontmatter (the durable write — see
   `_session/task_claim.sh`'s own header comment). A grilled-but-not-yet-
   implemented task belongs in `Design`, not `In Progress`, so correct the
   frontmatter `status:` line back by hand right after `acquire`:

   ```bash
   # In <task-file>'s frontmatter: status: In Progress -> status: Design
   # (leave claimed_by untouched — only the status token moves)
   ```

   Don't reach for `_session/status.sh` for this correction.

   - Its own header documents it as a best-effort *GH Project board* mirror
     only — it never writes the task file.
   - Calling it here used to leave the frontmatter silently stuck at
     `In Progress` after every grill — moot now that there's no board left
     to mirror to anyway.
5. Carry-overs do **not** get a re-grill — once a task is In Progress, the design is presumed adequate. If implementation has revealed the design is wrong, that's a separate "stop and re-scope" event handled outside the IPM ritual.

The grilled task files (Design sections, estimation revisions, claims) are left uncommitted by `/incept`; they land together with the IPM file in step 5's commit PR, not one PR per candidate.

### 4 Commit new picks

**No computed or enforced budget** (a deliberate
de-automation; a prior ~20h/3-line hour-budget design here never actually ran
in this repo's own history and, after `estimation:` moved to story points
(T20260924-232855), had nothing left to sum against anyway).

1. Carry-over (step 1) is already committed, unconditionally — it's not
   subject to anything below.
2. For everything else — the candidate pool from step 2, plus carry-over
   candidates from step 1.5 — walk `dev/TODO/queue.md`'s existing order
   top-down and decide what to commit, by judgment.
   - `estimation` point totals can inform how much you're taking on.
   - **No categorical Product/Infra-tooling split, no numeric ceiling this
     skill itself enforces.** Pick what you can realistically land; stop
     there.
3. **Infra/tooling work doesn't need a dedicated line to get picked.** When
   you do pick one (skill iteration, CI/test scaffolding, other process work
   that ships no product artifact), name it explicitly with a one-line "why
   this now" in the `Why` column of the `## Committed this iteration` table
   (step 5) — a plain annotation, same as any other pick's rationale, not a
   protected quota.
4. Every carry-over candidate from step 1.5 still needs an explicit
   disposition — accept it into this week's committed list, or re-cut it
   under `## Considered but cut` with a reason. Nothing is silently dropped.

### 5 Write ipm-weekly.md + tag committed task files with Scheduled

Write `dev/JOURNAL/YYYY-MM-DD-ipm-weekly.md`.

- **Revise-in-place if a `/stage` stub already exists at this path** — `/stage` may have already created `dev/JOURNAL/${SCHEDULED}-ipm-weekly.md` during the prior week, header `**Status**: Pre-IPM staging` plus a populated `## Candidates` section. Don't create cold (it'd clobber the staged rationale): edit in place, populate the Committed table, and **drop the `**Status**: Pre-IPM staging` marker line** so `_ipm/current.sh` starts selecting it as committed. Create cold only when no stub exists.
- Deliverables: (a) the committed list — carry-over + new picks + infra/tooling, one table, in `queue.md` order (see template below), (b) cuts with reasons, (c) notes/escalations, (d) a disposition for every carry-over candidate from step 1.5 (accepted into the committed list, or re-cut under `## Considered but cut`). This is a record of what was committed, not a schedule — `/drive` works it off `queue.md` order day-to-day, same as any other week.

**Render every task reference as a clickable markdown link.** In every table below (Committed this iteration, Carry-over candidates, Mid-week additions, Considered but cut), the `Task` column is a link, not bare text — `[T<id>](<issue-url>)`, built via the same map-free resolver the daily standup uses (`/ccxp` Phase 1.4):

```bash
source <skills-root>/_taskid/url.sh
taskid-mdlink T<id>      # -> [T<id>](https://github.com/…/issues/…)
```

`taskid-mdlink` defaults to `--issue` mode (unlike `taskid-slacklink`'s blob-mode default): an IPM file is written once and never regenerated, so an issue URL is the right choice — a blob-mode link baked in at write time can rot if the referenced task later moves (`dev/TODO/` → `dev/JOURNAL/` on close), the issue URL never does.

In the same step, for each task in the committed list (carry-over, new pick, or infra/tooling), edit the task file in `dev/TODO/` to set `scheduled: ${SCHEDULED}` in its YAML frontmatter.

- **Always overwrite**, never skip — when a task moves between IPMs (carried over, or a business-priority shift pulling it from a later iteration), the new IPM's Monday becomes the authoritative scheduled date. The task file's git log preserves the full `scheduled` history; retro's bump-counter walks the IPM files themselves rather than the task file's current value.
- **Applies to claimed / peer-owned tasks too** — being claimed does not exempt a task from `scheduled:` advancement. Editing only that field is an IPM planning action (re-tracking the iteration), not a touch on the peer's branch/PR/work — not a collective-ownership violation.
- `scheduled:` is the only iteration record there is (no board to derive from) — a carry-over whose `scheduled:` is left stale stays pinned to the old iteration even though the IPM prose "carried" it. Carrying a task in the prose and advancing its `scheduled:` are one action, not two: do both, every claimed task included.

**Cut candidates — advance, never clear.** For every task placed under this IPM's `## Considered but cut`, set `scheduled:` in its `dev/TODO/` frontmatter to **next** Monday — never delete the field (`scheduled` is update-forward-only). Compute next Monday from `${SCHEDULED}`:

```bash
NEXT_MON=$(date -d "${SCHEDULED} +7 days" +%F 2>/dev/null || date -j -v+7d -f %Y-%m-%d "${SCHEDULED}" +%F)
```

Then **pre-append** each cut task to next-Monday's pre-IPM stub `dev/JOURNAL/${NEXT_MON}-ipm-weekly.md` under `## Candidates`, as a `### Re-surfaced YYYY-MM-DD (cut at IPM)` sub-section (the same shape `/stage` uses for duplicates).

- If that stub doesn't exist yet, create it from the `/stage` header template first.
- Step 1.5 re-folds the same cut at next IPM and **dedupes by task ID**, so a pre-appended cut is not double-listed.

```markdown
# Weekly Focus: YYYY-MM-DD (Mon) → YYYY-MM-DD (Fri)

**Scheduled**: {SCHEDULED}
**IPM duration**: ~{N} min ({start time}–{end time})

## Committed this iteration

*One list, in `queue.md` order — no separate carry-over/new-pick tables. `Status` shows what's auto-carried (`In Progress`/`Review`/claimed — always carried, never cut) vs. a new pick (`Design`/`Open` — picked in step 4). `Est` is the task's story-point `estimation`.*

| # | Task | Status | Est | Deadline | Why |
|---|------|--------|-----|----------|-----|
| 1 | T... | In Progress | 2 | 2026-04-30 | Carry-over |
| 2 | T... | Open | 1 | — | Unblocks T... |
| 3 | T... | Design | 5 | 2026-05-08 | ARM deadline next week |
| 4 | T... | Design | 2 | — | Infra/tooling — `/ccxp` Phase-X fix surfaced by last retro |

*Infra/tooling picks (step 4 item 3) are just rows here like any other pick — named with a one-line "why this now" in `Why`, not a separate category.*

## Carry-over candidates (deferred at {prev IPM date})

*Seeded in step 1.5 from last IPM's `Considered but cut`. Each must be dispositioned: accepted into the committed list above (gets `scheduled`) or re-cut below. Omit the section if there were no prior cuts.*

| Task | Prior cut reason | Disposition this IPM |
|------|------------------|----------------------|
| T... | {reason from last IPM} | Committed / re-cut: {reason} |

## Mid-week additions (appended after IPM commit)

*Initialize empty at IPM commit. Tasks added throughout the week — via `/rca` red-pipeline auto-promotion (see `/rca` Step 6), `/stage` skill, or manual append — land here as a plain running list, same judgment call as any other pick (no budget cap to weigh against).*

| # | Task | Est | Added | Why this iteration |
|---|------|-----|-------|--------------------|
| (none yet) | | | | |

## Considered but cut

| Task | Reason |
|------|--------|
| T... | Design pass revealed much larger effort than expected — re-rank next IPM |
| T... | Blocked on customer reply — waiting |

## Notes

- Design pass on T... raised ABI compatibility question → escalated to Slack thread {url}
```

### 5a Drain the previous iteration (HARD GATE — the IPM commit is not final until this is green)

Step 5 advances `scheduled:` for the committed list (carry-overs + new picks) and for cut candidates. But a third class slips through **both** paths: an `Open`/`Design` task with an **empty** claim that was scheduled into the *previous* iteration and neither got picked this IPM nor cut.

- Step 1's carry covers in-flight (`In Progress`/`Review`) + `claimed_by` tasks; step 5's cut-advance covers what this IPM explicitly cuts.
- An unclaimed not-started task that nobody touched is caught by **neither** and silently strands on the now-closed iteration.

The maintainer rule: **at IPM end, every previous-iteration task that is not terminal (`Done`/`Parked`) must be migrated out.** Enforce it with the hard gate `<skills-root>/_ipm/ipm-iteration-drain-check.sh` — **file-only**: it reads `dev/TODO/*.md` frontmatter directly, no GitHub Project board, no `gh` call at all. Run **after** step 5 (so the picks' `scheduled:` are already advanced) and **before** the IPM is considered committed:

1. **List the strand-class offenders.** The gate scans every `dev/TODO/*.md` file and flags any whose `status:` is non-terminal (default terminal set `Done|Parked`) **and** whose `scheduled:` equals the previous iteration's Monday — i.e. it's still pinned to the week that just closed.
   - The previous iteration's Monday is **today's current-week Monday minus 7 days** (or `--prev-start` to force it for a backfilled/ad-hoc run) — a plain calendar computation, not a board lookup. Same "no client-side counter" discipline as before, just sourced from the calendar instead of a board's iteration list.
2. **Drain each offender.** For every listed task, decide and act exactly like step 5's per-task disposition:
   - **carry** it (advance its task-file `scheduled:` to this IPM's `${SCHEDULED}` and add it to the committed list), or
   - **defer** it (advance `scheduled:` to a future Monday and pre-append it to that Monday's `## Candidates` stub, per step 5's "Cut candidates — advance, never clear").
   - Either way `scheduled:` moves **forward** — never deleted.
3. **Gate the commit.** Re-run the check; the IPM is **not committed** until it exits **0**:

   ```bash
   bash <skills-root>/_ipm/ipm-iteration-drain-check.sh
   #   exit 0 → previous iteration clean of non-terminal offenders — proceed to step 5b
   #   exit 1 → it printed offenders still pinned to the previous iteration's scheduled: — drain them (step 2) and re-run
   #   exit 2 → usage error (bad flag/arg)
   ```

   Defaults are correct for a normal Monday run (today's date, `dev/TODO` in cwd). Run `bash <skills-root>/_ipm/ipm-iteration-drain-check.sh --help` for the override flags (`--today`, `--prev-start`, `--terminal`, `--todo-dir`) — rarely needed outside tests.

   The gate is **non-destructive** (read-only — it lists, it doesn't edit); the draining in step 2 is what mutates `scheduled:`. A clean previous iteration (or the very first IPM, when nothing is old enough to be "previous") is a no-op exit 0.

### 5b Update the ROADMAP doc

`dev/ROADMAP.md` is a plain file **in this repo** — no separate hub repo, no `ROADMAP_TARGET_REPO` global config — every repo owns its own ROADMAP/EPICS. Edit it **in place, in the same working tree and the same IPM commit/PR** as this week's `ipm-weekly.md` — no ephemeral clone, no second PR.

If `dev/ROADMAP.md` doesn't exist yet (first run), create it from the shipped template first:

```bash
mkdir -p dev && cp <skills-root>/ipm/templates/ROADMAP.md dev/ROADMAP.md
```

Then apply these updates directly to `dev/ROADMAP.md`:

1. **Promote this week's commitments** from "Deferred / on watch" → "Near-term" (or shift them within the near-term table if already there). Pull the task list from step 4's committed list — carry-over + new picks.
2. **Demote anything cut** in step 4 → "Deferred / on watch" with a 1-line "why cut" reason (mirrors the "Considered but cut" section of the IPM file).
3. **Advance the "Last updated" line** to today's date.
4. **Archive shipped entries**: near-term entries whose week is past AND whose tasks shipped (per `dev/JOURNAL/<date>-T<id>-*.md` evidence) move to a `## Recently shipped` section at the bottom of `ROADMAP.md`. Keep only the last 4 weeks there — older entries roll off the live table; git blame plus the unchanged per-week JOURNAL entries preserve the rest. A display budget, not a data-loss window.

`dev/ROADMAP.md` goes into the same `git add` / commit as `ipm-weekly.md` and the committed tasks' `scheduled:` bumps in step 5 — one commit, one PR, run through the same `_docs/lint-docs.sh dev/ROADMAP.md` pre-commit check every other doc edit gets.

If anything about the edit is unclear (e.g. a near-term entry with no obvious task-shipped evidence), leave a `## Notes` line in the IPM file rather than guessing — this is a judgment-call doc edit, not a scripted mutation.

### 6 Slack the focus

Send to `#acme-dev-notifications` via MCP `slack_send_message`. On send failure, apply the same
webhook fallback as `/ccxp` Phase 1.4 — this is a weekly, guaranteed-to-fire send in
the same failure-prone path:

```
*Weekly Focus* (YYYY-MM-DD)
- Committed: {N} tasks
- Carry-over: {M} tasks ({list})
- New picks: {K} tasks ({list})
- Top deadline: {task} due {date}
```
