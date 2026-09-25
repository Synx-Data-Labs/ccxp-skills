---
name: retro
description: Use when the user explicitly asks to run the weekly retrospective — review the last 7 days, grade the IPM, file action items
disable-model-invocation: false
argument-hint: "[weeks-back]"
---

Weekly retrospective: review the last 7 days of engineering work, identify what's working well, what needs improvement, and what's fine as-is. Produce action items as new tasks.

## Argument

`$ARGUMENTS` is optional:

- `/retro` — review the last 7 days (default)
- `/retro 2` — review the last 14 days (2 weeks)

## Goal

Improve the engineering process and product quality over time through structured reflection. This is not a status report — it's an honest look at how work is getting done and what to change.

## Configuration

Optional env vars (no adopting-team default baked in — read `~/.claude/.env` before running this skill; see README Prerequisites). Every one degrades gracefully when unset, including in an unattended cron run — never block the retro:

- `RETRO_SLACK_CHANNEL` — the channel Phase 6's summary posts to. If unset: in an interactive session, ask the user which channel to use; in an unattended run, skip Phase 6 and report "no RETRO_SLACK_CHANNEL configured" instead of the summary.
- `METRICS_OWNER` — the org/owner whose repos' `dev/quality/metrics.jsonl` Phase 4d reads. If unset, skip Phase 4d Step 1 entirely and report "no scoreboard reachable" the same way an unreachable individual repo already does.
- `METRICS_REPOS` — space-separated `<repo>` list (under `METRICS_OWNER`) running the quality probe. If unset or empty, same graceful skip as above. Extend as more repos adopt the probe.

## Workflow

### Phase 1: Gather evidence

Collect data from the last 7 days (or N*7 days if argument given). Do all reads in parallel:

1. **Git log**: `git log --since="7 days ago" --oneline --stat` — what shipped
2. **Journal entries**: Read all `dev/JOURNAL/*.md` files with dates in the window — completed tasks
3. **Merged PRs**: `bash ../_gh/gh.sh pr list --state merged --search "merged:>YYYY-MM-DD" --json number,title,mergedAt,additions,deletions --limit 500` — PR throughput. `gh`'s default page size is 30, which undercounts on any week with real throughput (confirmed 30 vs a true 83 on 2026-07-10) — always pass an explicit `--limit` well above expected weekly volume, same principle as step 6 below.
4. **Open PRs**: `bash ../_gh/gh.sh pr list --state open --json number,title,createdAt` — WIP that didn't land. Count entries where `createdAt` is older than 3 days from today for the Stale PRs row in Phase 3.
5. **Current TODO backlog**: count files in `dev/TODO/` and `dev/PARKING/` — backlog health
6. **CI failures**: `--limit 30` silently undercounts on any repo doing more than 30 runs/week — this recurred 3 retros running (2026-06-26, 2026-07-03, 2026-07-10; T20260702-279977) before being fixed here. Fetch with an explicit `--created` filter (same technique `/ccxp` Phase 1.2.1's nightly check already uses) so the API does the date filtering instead of a client-side slice of the newest N runs, and raise the fetch cap enough to comfortably cover a week's volume:

   ```bash
   SINCE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
   bash ../_gh/gh.sh run list --created ">=$SINCE" --limit 1000 --json conclusion,name,createdAt
   ```

   `--limit 1000` is `gh`'s API cap — if a single week's run volume ever exceeds it (check: the oldest returned `createdAt` should be ≤ `$SINCE`; if it's later, some of the window was dropped), note the gap explicitly in the retro rather than silently under-reporting, the same "no silent caps" principle as everywhere else. Group failures by `.name` and keep the top 3 by count for the Top failing workflows row in Phase 3.
7. **Slack escalations**: Read `.claude/state/drive-threads.json` — what needed human intervention
8. **Previous retro**: Read the most recent `dev/JOURNAL/*-retro-*.md` — check if prior action items were addressed, and extract the `CI pass rate` cell (e.g. `76% (...)`) so Phase 3 can report the delta vs this retro.
9. **This week's IPM commit**: Read `dev/JOURNAL/{this-week-Monday}-ipm-weekly.md` — the focus list to grade. If the file is missing (no IPM ran this Monday — holiday, off day, or pre-rollout), note "No IPM commit this week" and skip Phase 2's focus grading + Phase 3's focus rows.
10. **Last 2 ipm-weekly files**: Read the previous two `dev/JOURNAL/*-ipm-weekly.md` to detect tasks bumped 3+ IPMs in a row. A task is "bumped" if it appeared in a ipm-weekly and is still in `dev/TODO/` (not in JOURNAL as Done) — i.e. it didn't ship that week. Three consecutive bumps is a process smell worth flagging.

    Each IPM file's header records `**Scheduled**: YYYY-MM-DD` (the Monday date of that IPM commit; set by ccxp Phase 2a.5; codified in T20260513-393048). The bump-counter collects task IDs cited in each of the 3 most-recent IPM files; a task that appears in all 3 sets is bumped 3x. No reliance on Project-side iteration mapping — the IPM file dates are the join key.

11. **Cron utilization** (T20260605-862341 — the feedback loop for tuning cron frequency without extra tokens): locate the ccxp cron clone's log dir — `crontab -l` names the `daily-ccxp.sh` path; its repo root contains `.claude-ccxp-logs/`. Fall back to `<current-repo-root>/.claude-ccxp-logs` if crontab is unreadable; if neither exists, report "no cron logs reachable from this clone" and skip the Phase 3 cron rows. For each `ccxp-YYYYMMDD.log` in the window (gunzip `.log.gz` archives as needed):

    ```bash
    for f in "$CCXP_LOG_DIR"/ccxp-*.log; do
      day=${f#*ccxp-}; day=${day%.log}
      act=$(grep -oE 'duration=[0-9.]+s' "$f" | tr -d 'duration=s' | awk '{s+=$1} END{printf "%.0f", s/60}')
      cost=$(grep -oE 'cost=\$[0-9.]+' "$f" | tr -d 'cost=$' | sort -n | tail -1)
      tools=$(grep -c '] TOOL ' "$f")
      stop=$(grep -oE 'STOPPED reason=[a-z_]+' "$f" | tail -1 | sed 's/.*=//')
      skips=$(grep -c 'PREFLIGHT idle' "$f"); fires=$(grep -c 'PREFLIGHT actionable' "$f")
      echo "$day active=${act:-0}min cost=\$${cost:-0} tools=$tools stop=${stop:--} preflight=$fires/$((fires+skips))"
    done
    ```

    `active` sums the `DONE duration=` wall-times (actual model work); `cost` is the session's cumulative `total_cost_usd` (max per file — DONE lines repeat it cumulatively on `--continue` resumes). PREFLIGHT counts are zero for pre-gate logs — report "n/a (pre-gate)" for those days rather than 0/0.

### Phase 1b: Review memory

Read all memory files from the auto-memory system. These live in the Claude Code per-project memory directory (outside the repo — managed by the Claude Code harness, not version-controlled).

**Sweep every clone's memory, not just this session's own.** Memory is keyed by the encoded absolute path of the working directory, so an interactive clone (`~/<repo>`) and a cron clone (`~/focus/<repo>`) — or any other checkout of the same repo — each accumulate a *separate* memory pool. A retro invoked from only one clone silently leaves the others unswept indefinitely (confirmed 2026-08-24: the cron clone's memory stayed a disciplined ~20 files under weekly Phase 1b review, while the interactive clone's memory — never once reviewed by a retro — grew unchecked to 85 files since March). One retro run now sweeps ALL of them:

```bash
REPO_BASENAME=$(basename "$(git rev-parse --show-toplevel)")
ls -d ~/.claude/projects/*"${REPO_BASENAME}"*/memory 2>/dev/null
```

For each matched directory:

1. **Index**: Read that directory's `MEMORY.md` to get the list of stored memories
2. **All memory files**: Read each linked `.md` file. Memory types are: `user` (role/preferences), `feedback` (corrections and validated approaches), `project` (decisions, constraints, context), `reference` (pointers to external systems)

**Stale-directory check first.** Before treating a matched directory as a live source, check whether it belongs to an abandoned session rather than an active clone — the strongest signal is a project-directory name containing an ephemeral-worktree marker (e.g. `.claude-worktrees-cc-<timestamp>-<pid>`) or any other one-off session naming pattern, especially if its files' mtimes cluster around a single old date with nothing since. Flag these as **stale-directory candidates** in the Phase 5 report for the human to confirm deletion of — do NOT sweep them as a live consolidation source (their content, if any, was almost certainly already captured or is irrelevant), and do NOT auto-delete them (a human should confirm the clone is truly gone, not just quiet).

For each memory entry, assess:

- **Is it still current?** Check if the underlying fact is still true (e.g., a bug may have been fixed, a convention may have been adopted). Delete stale memories immediately (remove the file and its MEMORY.md entry).
- **Should it be codified?** If a feedback memory has proven useful across sessions, it should be promoted to a permanent home:
  - Process rules → `dev/guidelines.md`
  - Cross-repo skill behavior → the relevant skill's own `SKILL.md` in the ccxp-skills plugin source (`<name>/SKILL.md`, relative to the ccxp-skills repo root)
  - Behavior specific to a single repo's own skill → that repo's project-scoped `.claude/skills/<name>/SKILL.md` instead of the global one (e.g. a repo's own release skill, not `address-pr`/`ccxp`)
  - Pipeline/build conventions → `DEPENDENCIES.md` or workflow comments
  - Recurring cross-repo diagnostic patterns (a symptom + root cause + fix that isn't tied to one repo's specific build) → `gotchas.md`
  - **A `feedback` memory that got violated again despite already being recorded** → doc isn't enough; escalate to a technical hard-gate instead of (or in addition to) rewording the memory. Prose only works if it gets recalled and applied correctly every time — a repeat violation is evidence it doesn't. Concretely: a `PreToolUse`/`PostToolUse` hook in `~/.claude/settings.json` (`/update-config` builds and pipe-tests these) when the violation is mechanically detectable from tool input (a command pattern, a file path, a target directory), or a wrapper/validation script the relevant skill shells out to (see `_gh/`, `_taskid/`) when it needs richer logic. Precedent: `feedback_ephemeral_clone_cross_repo` was violated twice (once in another repo, once in `~/.claude/skills`) before `~/.claude/hooks/guard-interactive-clone-mutations.sh` was added to hard-block mutating git/gh commands targeting named interactive clones.
- **Create consolidation tasks** for memories that should be codified. Each consolidation task must:
  1. Add the rule/convention to its permanent home (guidelines, skill, hook, or wrapper script)
  2. Delete the memory file and remove its MEMORY.md entry (a hook/script fully replacing a memory's job means the memory itself is now redundant, not just documented elsewhere — remove it rather than keeping both)

  Tag with `Category: process` and `Source: Retro YYYY-MM-DD (memory consolidation)`.

Include a **Memory Review** section in the retro report (Phase 5) summarizing:

- Total memories: N (user: X, feedback: Y, project: Z, reference: W)
- Stale memories removed: list
- Memories to consolidate: list (with target file and task ID)

### Phase 1c: Sweep stale-by-event escalations

`.claude/state/drive-threads.json` accumulates entries that were never marked `resolved: true` even after the underlying work shipped. Common shape: a PR-approval thread (`T<id>-prN`) whose PR has since merged, or a thread whose task has moved into `dev/JOURNAL/`. The retro is the right place to reconcile these — left alone, they bloat the "open escalations" list in every standup and obscure the genuinely-pending design decisions.

**Procedure** — for each entry in `.claude/state/drive-threads.json` where `resolved` is `false`:

1. **Rule A (PR-suffix auto-resolution).** If the key matches the pattern `T\d+-\d+-pr(\d+)$`, extract the trailing PR number and run `bash ../_gh/gh.sh pr view <N> --json state,mergedAt`. If the PR is `MERGED`, mark the entry:

   ```json
   "resolved": true,
   "resolved_at": "<mergedAt>",
   "resolution": "PR #<N> merged <mergedAt> — auto-resolved by retro Phase 1c (stale-by-event)"
   ```

2. **Rule B (task-closure auto-resolution).** If the key starts with `T<id>` (with or without a PR suffix) and a file matching `dev/JOURNAL/*T<id>-*.md` exists, the underlying task has been closed. Mark resolved:

   ```json
   "resolved": true,
   "resolved_at": "<today, ISO 8601>",
   "resolution": "Task closed in dev/JOURNAL/<filename> — auto-resolved by retro Phase 1c (stale-by-event)"
   ```

   If both Rule A and Rule B match, prefer Rule A's `resolved_at` (the merge timestamp is the truer "resolved when" signal).

3. **Surface anything left.** For entries that match neither rule AND are older than 14 days (today − `sent_at` > 14d), collect them for the "Stale escalations" section in the retro report (Phase 5). Do not auto-resolve — these typically need explicit user action (a design pick, an external go/no-go, etc.).

After the sweep, write the updated JSON back atomically:

```bash
jq '...' .claude/state/drive-threads.json > .claude/state/drive-threads.json.new \
  && mv .claude/state/drive-threads.json.new .claude/state/drive-threads.json
```

**Track counts for Phase 5 + Phase 6**:

- `auto_resolved_a`: number of Rule A hits
- `auto_resolved_b`: number of Rule B hits
- `stale_surfaced`: number of stale-by-event entries surfaced for manual review

### Phase 1d: Chore index review

The weekly retro **deterministically evaluates prior process-improvement chores on evidence**,
not from memory. A repo opts in by maintaining
`dev/chore.md` — a thin index, one row per chore: Goal + link to the chore's task file +
Started date + Outcome (blank until evaluated). **Repo-agnostic**: a repo without `dev/chore.md`
is a clean no-op — skip this phase entirely and report nothing for it.

1. **List due chores**:

   ```bash
   bash ../retro/scripts/chore-review.sh list-due --repo-root . --today "$(date -u +%F)"
   ```

   Prints one `T<id>\t<goal>\t<started>` line per chore that is due: its Outcome column is
   still blank (no `Kept`/`Revised`/`Extended` recorded) AND at least one full iteration
   (7 days) has passed since Started. No output → no due chores this retro, skip to step 3.

2. **Evaluate each due chore** against *its own* goal/criteria (read the linked task file) using
   this period's evidence — merges, reverts/fixups, incidents, the Phase 3 metrics. Most do-X
   chores are a trivial "goal met? yes" look-back; hypothesis-style chores get the substantive
   evidence check (the auto-merge trial's own 06-12 evaluation is the worked example — see
   `dev/chore.md`'s seed row). Record the verdict:
   - **Kept** — effective, fold into standing policy. Update the chore's task file with the
     verdict + evidence, and update its `dev/chore.md` row's Outcome cell.
   - **Revised** — not effective as-is. Capture *what* failed in the task file; file a
     `Category: process` action item via Phase 4's task-creation steps (do **not** silent-revert
     the underlying policy); update the Outcome cell pointing at the new task.
   - **Extended** — inconclusive, needs one more iteration of evidence. Update the Outcome cell
     with `**Extended** — next review <today + 7d>` and the reason. `chore-review.sh` treats
     `Extended` as terminal (same as `Kept`/`Revised`) — it will not auto-resurface the row.
     Known v1 limitation: a genuinely multi-cycle chore needs a human/retro to manually reset
     its Outcome cell to blank once the noted review date arrives, re-entering it into
     `list-due`. Fine for now since no chore has needed a second extension yet; revisit if one
     does.
   Commit the `dev/chore.md` + task-file updates in the same PR as the rest of the retro's
   docs changes (Phase 5).

3. **Creation safety-net scan** — flag process-looking `dev/*.md` changes with no matching row:

   ```bash
   bash ../retro/scripts/chore-review.sh scan-untracked --repo-root . --since "$(date -u -d '7 days ago' +%F)"
   ```

   Prints repo-relative paths of `dev/*.md` files (root-level only — not `dev/TODO/`,
   `dev/JOURNAL/`, `dev/PARKING/`, or `dev/chore.md` itself) changed in the window whose content
   doesn't reference any task ID already linked from `dev/chore.md`. Each hit is a **prompt to
   check, not an auto-file** — a genuine process/policy/guideline change gets a `dev/chore.md`
   row added (if it's the kind of thing worth an evidence-based look-back) or an explicit
   "confirmed not a chore" note; a false positive (e.g. a docs typo fix) is dismissed with no
   action.

**Track counts for Phase 5 + Phase 6**:

- `chores_evaluated`: number of due chores evaluated this retro (Kept/Revised/Extended)
- `chores_untracked_flagged`: number of files flagged by the safety-net scan

### Phase 2: Analyze

Organize findings into three categories. Be specific — cite task IDs, PR numbers, and concrete examples.

#### Focus list grade (the main accountability check)

For each task on this week's `ipm-weekly.md`, classify the outcome. Skip this section if no IPM ran this week.

- **Shipped** — PR merged this week and the task closed as Done, whether it's already sitting in `dev/JOURNAL/` (the expected case since T20260914-422854 — `/drive` journal-moves immediately on every close) or still in `dev/TODO/` with `status: Done` (a hand-closed task, or one closed by a session predating that change — `dev/JOURNAL/`-only is a stale check that undercounts these). Compute `actual` from PR `created → merged`. Compare `revised est` (from ipm-weekly.md) vs `actual`; flag when ratio > 2x or < 0.5x.
- **In flight** — task started (Status `In Progress` or `Review`) but not merged. It will be Tier 1 carry-over next IPM.
- **Partial** — commits exist on a branch but no PR is open, or PR is open but stalled (no movement in last 3 days).
- **Dropped** — not started (Status still `Open` or `Design`). It re-enters the candidate pool next IPM.

**Estimation-revision arc.** The final `estimation:` value hides whether a task was estimated once and held, or revised repeatedly mid-week — and which way. Pull the revision arc for each graded task from its file's git history, so the grade shows the trajectory (filed → revised → revised), not just the endpoint:

```bash
bash ../retro/scripts/estimation-revisions.sh \
  --repo-root . --since "$(date -u -d '7 days ago' +%F)" T<id> T<id> ...
```

It walks `git log --follow` over each task file (backlog + the post-close JOURNAL copy) and parses both metadata formats (frontmatter `estimation:` and the legacy `- **Estimation**:` bullet), windowed to the retro period. Read the four arc shapes as estimation-discipline signal: no revisions + actual ≈ est = good; no revisions + actual ≫ est = under-estimated; revised upward, actual ≈ latest = healthy discovery; revised downward = scope-cut to fit budget. Feed the per-task arc into the Phase 5 **Revisions** column.

Cross-reference the previous 2 ipm-weekly files (Phase 1 step 10): if a Dropped task appeared in **all three** of this week, last week, and the week before, mark it **bumped 3x** and surface it under "What needs improvement" — repeated bumping means either the task is mis-prioritized, mis-estimated, or genuinely lower priority than it was filed at.

#### What went well (keep doing)

Things that worked, shipped smoothly, or improved the process. Examples:

- Tasks that went from Open to Done without blockers
- PRs that merged cleanly with good test coverage
- Process improvements that paid off (e.g., pipeline verification catching issues early)
- Patterns that reduced cycle time

#### What needs improvement (change)

Pain points, recurring friction, or things that took longer than they should. Examples:

- Tasks that got blocked or required multiple fix attempts
- CI flakiness or pipeline issues
- Design gaps that surfaced during implementation
- Scope creep or estimation misses
- Repeated escalations on the same type of issue
- Stale backlog growth

#### What's fine as-is (acknowledge)

Things that are working adequately — not broken, not exceptional. Acknowledging these prevents unnecessary churn. Examples:

- Stable workflows that don't need changes
- Adequate test coverage in certain areas
- Processes that are "good enough" and don't warrant optimization effort

### Phase 2b: Batch journal-move sweep (backstop, not the primary mechanism)

**Why**: since T20260914-422854, `/drive` Phase 4/Phase 7 always journal-moves
a task immediately on close (retiring the old in-place-only default from
T20260513-189862) — so this phase is no longer where the *expected* weekly
volume gets swept. It's a **backstop** for the paths that don't go through
`/drive`'s close at all: a task closed by hand, one closed by a session that
predates this change, or `/todo sweep`'s own out-of-band "already shipped
outside `/drive`" case. Left unswept, a `dev/TODO/` file with `status: Done`
from one of those paths would linger indefinitely rather than accumulating
for a week — still worth a sweep, just a rarer one now.

1. Find every task in `dev/TODO/` whose frontmatter `status:` is `Done`:

   ```bash
   git checkout -b "retro/$(date +%F)-journal-sweep"
   swept=()
   for f in dev/TODO/T*.md; do
     status=$(awk -F': ' '/^status:/ {print $2; exit}' "$f")
     status=${status%% *}   # leading token only — some files append narration after Done
     if [ "$status" = "Done" ]; then
       closed_date=$(awk '/^## Closed/ {gsub(/[()]/, ""); print $3; exit}' "$f")
       dest="dev/JOURNAL/${closed_date:-$(date +%F)}-$(basename "$f")"
       git mv "$f" "$dest"
       swept+=("$(basename "$f" .md) -> $dest")
     fi
   done
   ```

2. **Zero candidates → skip cleanly.** If `swept` is empty, do not open a PR or
   add a report section — an empty sweep is a no-op, not a finding.
3. Otherwise, commit and open one PR with all the renames:

   ```bash
   bash ../_docs/lint-docs.sh --fix || true   # doc-lint guard — shared script (T20260719-111051), see /gcpr Step 1.5 (T20260627-192311)
   git commit -m "docs(tasks): batch journal-move for $(date +%F) (Friday sweep)"
   git push -u origin "retro/$(date +%F)-journal-sweep"
   bash ../_gh/gh.sh pr create --title "docs(tasks): batch journal-move $(date +%F)" \
     --body "Friday retro journal sweep — moves $(printf '%s\n' "${swept[@]}" | wc -l | tr -d ' ') Done task(s): $(printf '%s; ' "${swept[@]}")"
   ```

4. Run `/address-pr` on it — auto-merge tier per `dev/guidelines.md` (pure
   status-move content, no design decisions inside).
5. Record the swept task IDs in the Phase 5 report's `## Journal sweep` section
   (below) so the maintainer sees what moved.

**Why most weeks find nothing to sweep**: since T20260914-422854, every task
`/drive` closes journal-moves immediately at merge time (see Phase 2b's own
header above) — so a task that went through `/drive`'s close never appears in
this sweep, by design, not a miss. What this sweep actually catches is the
backstop case: a task closed by hand, or by a session that predates that
change.

### Phase 3: Metrics snapshot

Compute and report these metrics for the review period:

| Metric | Value |
|--------|-------|
| Tasks completed | count of JOURNAL entries in window |
| PRs merged | count |
| PRs still open | count |
| Stale PRs (>3 days open) | count of open PRs with `createdAt` older than today − 3d; list the PR numbers if small |
| Avg PR cycle time | created → merged duration |
| CI pass rate | `X% (green/total)` plus `Δ vs prior retro: +N pp / -N pp / unchanged` (use the `CI pass rate` cell extracted in Phase 1 step 8 as the baseline) |
| Top failing workflows | top 3 workflow names by failure count in the window, e.g. `Release AcmeDB (5), Upstream Prepare (3), AcmeDB Cloud Release (2)` |
| Escalations sent | count from drive-threads.json |
| Escalations resolved | count where resolved=true |
| Backlog size | TODO count |
| Parking lot size | PARKING count |
| Net backlog change | new tasks created - tasks completed |
| Focus list grade | `{shipped}/{total}` shipped, `{in_flight}` in flight, `{partial}` partial, `{dropped}` dropped (skip if no IPM this week) |
| Focus budget hit rate | `{committed}h committed / {actual}h spent` — compute by summing revised est for shipped tasks vs PR cycle-time totals; report ratio (e.g. `1.4x` means actual was 40% over commit) |
| Tasks bumped 3x | comma-separated task IDs that appeared on this week's, last week's, AND the prior week's focus lists without shipping (or "None") |
| Escalated to High | `N tasks escalated` (Phase 4b — `priority: High` set on tasks bumped 3×). Include the IDs if N > 0; pure-text "None" if N = 0 |
| Cron active time | avg + range of active model min/day from Phase 1 step 11 (e.g. `27 min avg, 16–39`) — flag if trending down with a growing backlog (sessions starving) or up against flat throughput (churn) |
| Cron cost | avg + range $/day (e.g. `$11.7 avg, $6.5–13.9`); flag a band shift vs the prior retro — the gate (T20260605-862341) should keep this flat while the hourly cron cuts latency |
| Cron preflight ratio | `fires/total` hourly fires that launched claude (e.g. `3/24`); `n/a (pre-gate)` for pre-rollout days. A ratio near 1.0 means the gate never skips (signals always present — fine); near 0 with a stale backlog means probes may be missing real signals |
| Cron stop reasons | histogram of `STOPPED reason=` in window (e.g. `no_actionable_items×6, rate_limit×1`) — anything other than `no_actionable_items` deserves a line in Phase 5 |

### Phase 4: Create action items

For each "needs improvement" finding, create a concrete, actionable task:

1. Generate task IDs using the shared helper (same one every skill uses — see `dev/guidelines.md` and `../_taskid/new.sh`):

   ```bash
   bash ../_taskid/new.sh --check ./dev
   ```

   Run this once per action item. The helper checks `dev/{TODO,PARKING,JOURNAL}/` and retries on collision. Do NOT invent sequential IDs (e.g. `-100001`, `-100002`) and do NOT inline the `printf ... /dev/urandom ...` command.
2. Create task files in `dev/TODO/` using the repo's required TODO metadata bullets in this exact order:
   - Estimation: use standard buckets (30m, 1h, 2h — keep action items small)
   - Status: Open
   - Blocks: only include if this task blocks another task
   - Source: `Retro YYYY-MM-DD`
   - Description: include the concrete action, clear definition of done, and any relevant context
3. In the Description bullet, tag **process improvements** with `Category: process`
4. In the Description bullet, tag **quality improvements** with `Category: quality`
5. After writing each file, stamp its `scheduled:` into the **current** iteration so the action item lands on the board's Iterations view, not just the backlog: `bash ../_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md current` (token-free: committed IPM → Project API → next-Monday fallback; update-forward-only).
6. Do NOT create tasks for "what's fine" or "what went well" — those are informational

### Phase 4b: Escalate chronically-deferred tasks

`scheduled:` is **update-forward-only and is never cleared here** — it is the task's last-scheduling record, and a *past* `scheduled` already reads as a fresh candidate to `/todo next` (committed ⟺ `scheduled` ≥ current Monday), so no zombie-clearing hygiene pass is needed. Instead this phase acts on chronic deferral.

**Rule**: For every task flagged **bumped 3×** by the bump-counter (Phase 1 step 10 / Phase 2 — cited in all 3 most-recent ipm-weekly files without shipping), open its `dev/TODO/*.md` file and set `priority: High` in the frontmatter. Idempotent — skip if already `High` or `Critical`.

**Why**: a task surfaced and cut three IPMs running that nobody parked is one the team keeps deciding matters but defers. Escalating forces it up `/todo next`'s ranking so the next IPM is likely to commit it; the human's release valve is to consciously park it (`/todo sweep`) if it genuinely shouldn't escalate.

**What this does NOT touch**: `scheduled:` on any task (never cleared); files in `dev/PARKING/` and `dev/JOURNAL/`; tasks not flagged by the bump-counter.

**Report**: add an "Escalated N tasks to High (bumped 3×)" line to the metrics table (Phase 3) and the Slack summary (Phase 6); include the task IDs (or "None").

### Phase 4c: Skill quality review

Grade the skills exercised this week and improve the single worst offender. This is the recurring skill-quality loop; it consumes the Phase 2 grade and Phase 3 metrics. **Hard cap: act on at most one skill per retro.** Remaining candidates are listed in the report (Phase 5), not acted on.

**Step 1 — gather candidate signals (graceful degradation; no signal is a hard dependency):**

- **Outcome (always available):** attribute this week's pain to skills. Coarse attribution by domain when no audit block is present — many PR review iterations / reopened threads → `address-pr` or `drive` prose; CI failures or reverts after `/drive` arcs → `drive` prose; tasks bumped 3x (from Phase 2) → the planning skills (`todo`, `ccxp`). Exact attribution when a "Skills invoked" audit block is present: grep both the week's JOURNAL (`dev/JOURNAL/<this-week>-T*.md`) **and** any `dev/TODO/T*.md` with `status: Done` (a task closed but not yet swept by the Phase 2b backstop) for `## Skills invoked` — JOURNAL-only misses a hand-closed or pre-T20260914-422854 task still sitting in `dev/TODO/`.
- **Authoring (when available):** if a rubric exists in the `superpowers:writing-skills` skill, grade each candidate skill against it and count violations. Until it exists, flag only obvious staleness by inspection — a skill citing a retired path, a renamed helper, or a removed phase.
- **Compliance (when available):** grep the week's JOURNAL audit blocks for skills that should have fired but were skipped, or fired at the wrong phase. Absent the audit block, skip this signal.

**Step 2 — pick the single worst offender (judgment-assisted, no formula):** rank by outcome-pain first; use authoring + compliance to break ties and escalate. If no skill clears a "worth touching this week" bar, report "none flagged" and end the phase — a valid and common outcome.

**Step 3 — triage bounded vs needs-design:**

- **Bounded prose edit** — a clarification, a missing trigger, a DRY fix, or a stale-path/stale-reference correction; mechanical, unambiguous intent. Draft it: in the local ccxp-skills dev checkout create a branch, make the edit, and open a ccxp-skills PR handed to `/address-pr` — **never a direct merge** (see the `feedback_invoke_address_pr_not_bypass_merge` memory).
- **Needs real design** — a structural change, touches multiple skills, changes a skill's contract, or the right fix is ambiguous. **Downgrade**: do not draft. File a `Category: quality` action item via Phase 4's task-creation steps (Source `Retro YYYY-MM-DD`) so it gets a proper `superpowers:brainstorming` → design pass when picked up.
- **When unsure, downgrade.** If it is not obviously bounded, file the task.

**Guards:**

- No skills exercised this week (docs-only / planning week): report "no skill activity" and end.
- The local ccxp-skills dev checkout is dirty or behind main: skip the bounded-draft path this week, downgrade to filing a task, and note it. Never edit a dirty clone.
- `gh`/PAT fails while opening the draft PR: log it, downgrade to filing the task. Grading still completes.

**Report**: add a `## Skill quality` section to the retro report (Phase 5) and a `Skill quality:` line to the Slack summary (Phase 6).

### Phase 4d: Quality-trend review — code-metrics scoreboard (T20260609-204303 D2)

The **trailing** half of the code-quality bar. `/drive` Phase 3.8 appends one record per code-class task to each target repo's `dev/quality/metrics.jsonl`; this phase reads the rolling **3-week** window, gives per-task feedback, and files remediation chores for unresolved regressions. Pairs with Phase 4c — that grades *how we work*; this grades *what we shipped*.

**Step 1 — locate the scoreboards.** For each `<repo>` in `METRICS_REPOS` (see Configuration above — unset/empty means skip this whole phase, "no scoreboard reachable") read `dev/quality/metrics.jsonl`:

- Prefer a local sibling clone — `<repos-root>/<repo>/dev/quality/metrics.jsonl`.
- Else fall back to fetching it from `main` via the API (command below).
- If neither is reachable, report "no scoreboard reachable for `<repo>`" and skip it — never block the retro (same posture as the cron-log step).

```bash
bash ../_gh/gh.sh api \
  "repos/${METRICS_OWNER}/<repo>/contents/dev/quality/metrics.jsonl" \
  --jq '.content' | base64 -d
```

**Step 2 — filter to the 3-week window.** Keep records whose `date` is within 21 days of today. If the window is empty across all repos, report "no quality records this window" and end the phase.

**Step 3 — per-task feedback (no silent drops).** Each record carries the probe-computed `delta`. A metric **regressed** when `coverage_pct` or `design_score` *fell*, or any other metric (`shellcheck_*`, `dup_pct`, `secrets`, `code_scanning_*`, `file_loc`, `max_fn_lines`) *rose* — the direction rule in [`quality-probe/SKILL.md`](../quality-probe/SKILL.md). For every task in the window:

- **Held the bar** (no regressed metric) → ✓, no action.
- **Regressed** → list the task, the metric(s), and the delta. The strong default is to hold; a regression whose cause is **not** recorded (in the task's JOURNAL close note / PR) is flagged **"unexplained"**.

**Step 4 — remediation chores via `/stage`.** Each **unresolved** regression (regressed *and* either unexplained, or explained but not yet restored) gets a chore — `/stage` takes an existing `T<id>`, so it is a two-step:

1. **Create** the chore in the hub via Phase 4's task-creation steps — `Category: quality`, Source `Retro YYYY-MM-DD`, title `quality: restore <metric> on <repo> (regressed in T<id>, Δ<delta>)`.
2. **Stage** it for the next IPM candidate pool (non-urgent, observe-first — no queue-jump): `/stage T<new-id> "restore <metric> regressed in T<id>"`.

Idempotent — skip if an open chore for that same `<metric> on <repo>` regression already exists in `dev/TODO/`.

**Step 5 — gate-readiness signal.** Compute the **hold-vs-regress rate** over the window (`holds / (holds + regressions)`). This tracks whether record+warn is trustworthy enough to promote toward a soft/hard gate (the deferred enforcement upgrade). Report the rate and its trend vs the prior retro; do **not** change the gate posture here — that is a deliberate, separately-decided step.

**Report**: add a `Quality trend` row to the metrics table (Phase 3) — `hold N / regress M (3wk); gate-readiness X%` — a `## Quality trend` section to the retro report (Phase 5), and a `Quality trend:` line to the Slack summary (Phase 6).

### Phase 5: Write the retro report

Create `dev/JOURNAL/YYYY-MM-DD-retro-weekly.md` with:

```markdown
# Weekly Retro: YYYY-MM-DD

**Period**: YYYY-MM-DD to YYYY-MM-DD
**IPM commit**: `dev/JOURNAL/{this-week-Monday}-ipm-weekly.md` (or "No IPM this week")

## Metrics
(table from Phase 3)

## Focus list grade
(skip if no IPM this week)

Render every `Task` cell as a clickable markdown link (T20260608-353422), not bare text —
`taskid-mdlink T<id>` (from `_taskid/url.sh`, `--issue` mode by default: this report is written
once and never regenerated, so an issue-URL link that survives every future task-file move is the
right choice, same as the IPM template).

| Task | Tier | IPM revised est | Revisions | Outcome | Actual | Notes |
|------|------|-----------------|-----------|---------|--------|-------|
| T... | 1 | 2h | filed `1h` → `2h` (scope discovered) | Shipped | 4h | 2x over — design pass missed the registry side |
| T... | 2 | 1d | no revisions | In flight | — | Tier 2 carry-over next IPM |
| T... | 2 | 4h | no revisions | Dropped | — | Bumped 3x — surface in "needs improvement" |
| T... | 3 | 1h | filed `1h` | Shipped | 1h | Red-pipeline auto-promote (Phase 1.2 RCA) — fit slack cleanly |

The **Revisions** column is the per-task arc from `retro/scripts/estimation-revisions.sh` (Phase 2). `no revisions` = the estimate held all week.

Grade Tier 3 separately from Tier 1/Tier 2 (Tier 3 estimation-vs-actual is a separate signal): if cumulative Tier 3 hours > slack reserve, flag in "needs improvement" — additions pushed Tier 1/Tier 2 work into next week. If Tier 3 count is consistently 0, that's also a signal — either the rhythm has no mid-week surprises (great) or appenders aren't using the convention (worth checking).

## Journal sweep
(skip if Phase 2b swept zero tasks)

Moved to `dev/JOURNAL/` this retro, in PR #N:
- `T...` — closed YYYY-MM-DD

## What went well
(findings from Phase 2, with citations)

## What needs improvement
(findings from Phase 2, with citations and linked action items)

## What's fine as-is
(findings from Phase 2)

## Action items created
Same link convention as the Focus list grade table above (`taskid-mdlink T<id>`, `--issue` mode).

| Task ID | Title | Est |
|---------|-------|-----|
| T... | ... | ... |

## Skill quality
- Worst offender: `<skill>` (signal: outcome | authoring | compliance | combined)
- Action: drafted ccxp-skills PR #N | filed T<id> (Category: quality) | none flagged
- Runners-up (noted, not acted on): `<skill>`, `<skill>` (or "none")

## Memory review
- Total: N memories across M clone(s) (user: X, feedback: Y, project: Z, reference: W)
- Per-clone breakdown (omit this list if only one clone's memory was swept): `<encoded-path>`: N files; `<encoded-path>`: N files
- Stale removed: (list or "none")
- To consolidate: (list with target file and task ID, or "none")
- Stale directories flagged for deletion (abandoned worktree/session clones — human confirmation needed, or "none")

## Stale escalations
(skip the section if Phase 1c surfaced none)

Auto-resolved by Phase 1c sweep:
- `T...-prN` — PR #N merged YYYY-MM-DDTHH:MMZ (Rule A)
- `T...` — closed in `dev/JOURNAL/<filename>` (Rule B)

Surfaced for user action (no automated resolution path, >14 days open):
- `T20260407-594056` (Nd open) — design decision, no automated resolution path. *User action needed: pick branching model.*

## Chore review
(skip the section entirely if the repo has no `dev/chore.md` — Phase 1d no-op)

Evaluated this retro:
- `T...` — **Kept** / **Revised** / **Extended** — one-line evidence summary

Creation safety-net — process-looking docs with no matching `dev/chore.md` row:
- `dev/some-doc.md` — checked, {added a row / confirmed not a chore} (or "none flagged" if the scan found nothing)

## Prior retro follow-up
(status of action items from previous retro — completed, in progress, or dropped)

## Housekeeping
- Slack summary: Posted via MCP / Posted via webhook fallback — MCP send failed / Both MCP and webhook fallback failed (see Phase 6)
```

### Phase 6: Notify

Send a Slack summary to `RETRO_SLACK_CHANNEL` (see Configuration above) via MCP `slack_send_message`.

**Webhook fallback on MCP send failure (T20260910-872316, same pattern as `ccxp/SKILL.md` Phase 1.4 / 2a.6, T20260717-433409).** This is a weekly, unconditional send — same shape as the daily standup and Monday IPM sends, which already carry this fallback; Phase 6 previously didn't, and a 2026-09-11 retro's summary silently never posted as a result. Don't let a failed send silently drop the week's retro from Slack:

1. Attempt `slack_send_message` once, then one retry on error — 2 attempts total, no further looping (same policy as T20260717-433409/Phase 1.4).
2. If both attempts error, capture the retro summary text into a variable and fall back to the same underlying script the `/slack` skill's `dev` channel uses:

   ```bash
   RETRO_MESSAGE="$(cat <<'EOF'
   <the *Weekly Retro* (YYYY-MM-DD) mrkdwn block composed below>
   EOF
   )"
   SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL_DEV" bash ../slack/scripts/slack-send.sh "$RETRO_MESSAGE"
   ```

   Requires `SLACK_WEBHOOK_URL_DEV` resolvable via the same three-tier lookup `slack/SKILL.md`'s Prerequisites documents (already-exported env var → `~/.claude/.env` → repo `.env`).
3. Record which path succeeded in the retro report's own `## Housekeeping` section (see Phase 5 template) — `Posted via MCP` vs. `Posted via webhook fallback — MCP send failed` — mirroring Phase 1.4's convention, so the record stays visible even on a week Slack itself shows no gap.
4. If **both** the MCP send and the webhook fallback fail, that's the hard-stop worth flagging loudly — note it in the report's Housekeeping section rather than silently giving up.

```
*Weekly Retro* (YYYY-MM-DD)
- Focus: {shipped}/{total} shipped, {dropped} dropped, budget {ratio}x ({over|under})
- {N} tasks completed, {M} PRs merged, CI {P}% green
- Top win: {one-liner}
- Top improvement area: {one-liner}
- {K} action items created — see retro report
- Skill quality: {<skill> → PR #N | <skill> → filed T<id> | none flagged}
- Escalation hygiene: {auto_resolved_a + auto_resolved_b} auto-resolved, {stale_surfaced} surfaced for user action (skip the bullet if both counts are 0)
- Chore review: {chores_evaluated} evaluated, {chores_untracked_flagged} untracked flagged (skip the bullet on repos with no `dev/chore.md`)
```

(Drop the first bullet on weeks with no IPM commit.)

## Notes

- **Be honest, not diplomatic.** The retro is for the team (human + AI), not for a stakeholder. If something is broken, say so clearly.
- **Compare with prior retros.** Trends matter more than snapshots — note if metrics are improving or declining.
- **Don't create busywork.** Only create tasks for improvements that will meaningfully impact velocity or quality. A retro that produces 10 tasks is too noisy.
- **Respect the backlog.** Check if an improvement task already exists before creating a duplicate. Link to existing tasks instead.
- **Action items should be small.** If an improvement requires a large effort, create a design task first (30m-1h) to scope it, not the full implementation.
