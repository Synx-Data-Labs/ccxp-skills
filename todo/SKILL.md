---
name: todo
description: Use when the user explicitly asks to list open tasks, pick the next task, or reorder/clean up the backlog
disable-model-invocation: false
argument-hint: list | next | sweep
---

Manage the dev/TODO task backlog.

## The queue: `dev/TODO/queue.md`

Priority is an explicit, ordered list, not a computed score. `dev/TODO/queue.md`
holds one line per task currently in `dev/TODO/`, top = highest priority:

```markdown
# TODO Queue

Ordered priority queue. Top = highest priority. One line per task, kept in
sync with `dev/TODO/` by `/todo sweep` (adds missing, strikes closed/parked).
Reordered by `/stage` (append to the end if missing) and `/top` (move to the
front). It's a plain list — hand-editing the order is a fully valid way to
reprioritize.

- [T20260702-947261](T20260702-947261-registry-token-rotation-baked-images.md): Container images with a container registry entitlement token baked in don't survive token rotation
- [T20260427-298901](T20260427-298901-registry-egress-cost-reduction.md): Cut registry spend (Round 2: eliminate proxy passthrough)
```

Parse each line as `- [T{id}](T{id}-{slug}.md): {title}` — the ID is
authoritative; the link target is the actual `dev/TODO/T{id}-*.md` filename
(relative link, clickable on GitHub and in-editor); the title is a
human-readability comment written at insert time and never re-validated, so
a stale title (the task was renamed since) is harmless.
`list`/`next` read this file for order. `sweep` is the only workflow that
adds or removes lines wholesale (keeping membership in sync with
`dev/TODO/`); `/stage` and `/top` reposition individual lines.

## Task metadata

Task files use **YAML frontmatter** for canonical metadata — same convention as `SKILL.md` files in this repo: a `---` … `---` block at the top of the file, parsed before the H1 title. Recognized by `/todo`, `/ccxp` IPM, `/retro`, and `/drive`. All fields are optional except `status` and `estimation`; absent fields are treated as "no constraint."

```yaml
---
estimation: 1d
status: Design
scheduled: 2026-05-19
deadline: 2026-05-22
blocks: [T20260514-299367, T20260515-447733]
source: Retro 2026-04-25
---

# T{ID}: {Title}

…body…
```

**Field semantics:**

- `estimation`: standard buckets (`15m`, `30m`, `1h`, `2h`, `4h`, `1d`, `2d`, `1w`). Required for IPM budget arithmetic.
- `status`: one of `Open`, `Design`, `In Progress` (or the legacy `Coding` alias, T20260809-355059), `Review`, `Blocked by T{id}`, `Parked`, `Done`. Required. The field is free-text after its leading token, so a `BLOCKED` or `SUPERVISED` substring can be appended to narrate why (e.g. `status: In Progress — SUPERVISED (needs VPN to GitLab)`). Consumer repos' `/ccxp` pre-flight gate (`dev/daily-ccxp.sh`) greps for these substrings to avoid waking an hourly cron session for work that's blocked or needs a human (VPN, a supervised force-push, an interactive decision) to progress.
- `scheduled`: `YYYY-MM-DD` (always a Monday). Written **only at IPM commit time** (`/ccxp` Phase 2a) for whichever tasks the IPM actually picks off the top of `queue.md` — it records which iteration a task landed in, for the GH Project board mirror; it does not drive priority (the queue does that). **Update-forward-only — never removed.** The GH Project mirror workflow (`.github/scripts/sync-tasks-to-issues.py`, per consumer repo) reads `scheduled` and looks up the matching iteration on the Project's iteration definition (which has authoritative start/end dates per iteration) — that's the source of truth for "what iteration is this?", not anything computed client-side. Used by retro for bump-counting (same task cited across 3 consecutive IPM files = bumped 3×).
- `deadline`: `YYYY-MM-DD`. Hard date the task must be delivered by — usually customer-, release-, or compliance-driven. Informational — display it, but it does not reorder the queue; if a deadline makes something urgent, reflect that by `/top`-ing it.
- `blocks`: YAML list of `T{id}`s that depend on this task. Drives the `Unblocks:` annotation in `next`'s output.
- `source`: one-line origin (e.g. `Retro 2026-04-25`, `RCA run 12345`, `Customer ticket SUPPORT-123`).

There is no `priority:` field — position in `queue.md` **is** the priority. A prior version of this schema had a free-form `Critical/High/.../Low` field that duplicated what the queue now expresses directly; it's retired.

Start from the canonical scaffold: [`repo-conventions/templates/task.md`](../repo-conventions/templates/task.md) — copy it for the file body and fill it in (don't hand-copy a recent task file; that's how stale frontmatter comments propagate). The `_taskid/new.sh` helper mints the ID only (`--check ./dev` avoids collisions) — it does not write the file, and does not add it to `queue.md` (the next `/todo sweep` picks it up, or `/stage` immediately).

**Backwards compatibility**: Legacy task files (filed before the 2026-05-14 frontmatter migration) may still carry leading-bullet metadata (`- **Status**: …`). Treat both formats as equivalent when reading. New files and updates use frontmatter.

## Argument

`$ARGUMENTS` is one of:

- `list` — show all open tasks in queue order (reports stale blockers and queue/`dev/TODO/` drift but does not modify files)
- `next` — show the top 3 non-done, non-peer-claimed tasks off the queue (does not check blocked-by/lint-frozen — that's `sweep`'s job)
- `sweep` — sync `queue.md` with `dev/TODO/`, fix stale blockers, then prune the backlog (auto-close finished/superseded work, ask before parking anything blocked or stale)

If `$ARGUMENTS` is empty, default to `list`.

## Workflow: `list`

Run `bash todo/scripts/todo-list.sh` and print its output verbatim — this
is a fully deterministic read of `queue.md` + task frontmatter (no
judgment involved), so it costs no model call (T20260914-359646). The
algorithm below is what the script implements; it stays documented here
for `sweep`'s own reuse (Phase 2/3 share the same drift/stale-blocker
checks) and for a human reading this skill — don't re-derive it by hand.

1. Read `dev/TODO/queue.md` for order.
2. For each listed ID, read its `dev/TODO/T{id}-*.md`: title, Status, Estimation, `scheduled`, `claimed_by`.
3. **Detect drift** (report, don't fix — that's `sweep`'s job):
   - Any `dev/TODO/*.md` file whose ID isn't in `queue.md` — report as "N untracked task(s) not in queue.md: … — run `/todo sweep`."
   - Any `queue.md` line whose ID has no matching `dev/TODO/*.md` file — report as "N stale queue entr(y/ies): … — run `/todo sweep`."
4. **Detect stale blockers:**
   - For any task with status containing `Blocked by T{id}` (may have trailing notes like `— waiting on X`), check whether the blocking task ID exists in `dev/TODO/`. If **not** (i.e. it has been moved to `dev/JOURNAL/` or never existed), the blocker is resolved.
   - Also scan dependency sections (e.g. `## Dependencies`) for references to T{id} tasks no longer in `dev/TODO/`.
   - **Report** stale blockers in a summary after the table (e.g. "T154460 is blocked by T336273 which is now in JOURNAL — run `/todo sweep` to update").
5. Present a table **in queue order** (top of `queue.md` first — this is the priority order, not a computed sort) with these columns:
   - `Deadline` — `YYYY-MM-DD` if set, blank otherwise; mark past-deadline rows with `⚠`
   - `Scheduled` — the raw `scheduled` date if set, blank otherwise; append `✓` when it's ≥ this week's Monday (landed in the active iteration at a past IPM commit)
   - `Claimed` — blank if unclaimed, `mine` if `claimed_by` matches this session's id (`task_claim.sh claimant-id`), otherwise the raw `claimed_by` value (a peer claim — this is a report, not a filter, so peer claims still show up here even though `next` would exclude them)

```
| # | ID | Title | Status | Est | Deadline | Scheduled | Claimed |
|---|----|-------|--------|-----|----------|-----------|---------|
```

(`#` is the 1-based queue position — makes "move this to #1" via `/top` concrete.)

6. Show counts: total, by status, and: `N committed to active iteration` / `N claimed (M mine, K by peers)`
7. Count files in `dev/PARKING/*.md` and show: `Parking lot: N parked`

## Workflow: `next`

**Goal: quickly surface the top 3 lines of the queue worth looking at (fits
one page).** The queue's order already encodes priority; this workflow only
skips entries that are pure noise to show (already finished, or owned by
someone else right now). Everything else — a `Blocked by T{id}` status, a
lint-frozen frontmatter — is shown as-is, status and all, rather than
silently filtered. If the top 3 turn out to be mostly non-actionable, that's
a signal to run `/todo sweep` (which does the deeper analysis: fixing stale
blockers, enforcing blocker order, pruning), not something this workflow
tries to work around itself.

Run `bash todo/scripts/todo-next.sh` and print its output verbatim — the
skip logic and claim-state check are fully deterministic (no judgment
involved), so this costs no model call (T20260914-359646). One line is
explicitly **not** ported to the script and stays a judgment call for
whoever reads the top pick's file: step 4's "the next concrete action to
move it forward, if evident from the file" — that requires interpreting
free-form task-body prose. The algorithm below is what the script
implements; it stays documented here for a human reading this skill.

1. Read `dev/TODO/queue.md` for order — this is the walk order, top to bottom. Do not re-sort it by deadline, estimation, or anything else; if the order is wrong, that's a `/top`/`/stage`/hand-edit problem, not something this workflow second-guesses.
2. **Walk the queue top to bottom, skipping only**:
   - `Done`, legacy `Revisit`/`Parked` — finished or not active backlog, never useful as "next" work.
   - **By default (peer mode; disable with `CCXP_PEER_MODE=0`)** tasks **claimed by another live session**: read the frontmatter `claimed_by:` (`bash ../_session/task_claim.sh read <id>`) — if it is non-empty and not this session's id (`task_claim.sh claimant-id`), skip it *unless* `task_claim.sh reclaimable <id>` reports `reclaimable` (a stale claim — no open PR, no commits in N days). This keeps the recommendation off tickets another peer is actively driving. With `CCXP_PEER_MODE=0`: no claim filtering.
   - Nothing else is checked here — no dependency-graph walk, no lint-frozen probe. A task with `status: Blocked by T{id}` or one `/drive` would refuse to claim (lint-frozen frontmatter, e.g. the [T20260626-353630] schema-fork class) still counts toward the 3; its status column says so.
3. Collect the first 3 tasks that survive the skips above, in queue order.
4. Present the top 3 with:
   - What the task is, and its **queue position** (e.g. "#3 of 42")
   - Current status verbatim, including a `Blocked by T{id}` prefix if present — don't resolve it, just show it
   - **Deadline** if set, and **Scheduled** (≥ this Monday = landed in the active iteration at a past IPM)
   - **Claim status** (unclaimed / claimed by this session / reclaimable stale peer claim)
   - **Unblocks:** if the task's frontmatter has a `blocks:` list, show it verbatim (e.g. "Unblocks: T20260320-000029, T20260320-000045")
   - The next concrete action to move it forward, if evident from the file
5. If any of the 3 are `Blocked by` an open task, call that out plainly and point at `/todo sweep` rather than trying to interpret it further.

### P0 escape hatch

A true P0 — production down, customer-blocked, security incident — preempts the queue entirely and doesn't wait for `/top`/IPM ceremony. P0s come through the Slack escalation protocol (`#acme-dev-notifications` with explicit human ack), not the normal task flow. Anything less than P0 — including newly-noticed deadline pressure — should go through `/top` (immediate) or `/stage` + the next IPM (routine). If the escape hatch is invoked more than once a week, that's a signal something structural is off; surface it in the Friday retro.

## Workflow: `sweep`

Clean up the TODO backlog: sync the queue, fix stale blockers, then prune. Unlike `list`/`next` (which only report), `sweep` modifies files. **Phases 1, 2, and Phase 3's auto-close step all act without asking** — they're mechanical (membership sync, stale-blocker resolution, ordering) or unambiguous (a task already marked `Done`, or already pointed at its superseding task). The **only** point where `sweep` stops and asks is Phase 3's Park recommendation — a move between `dev/TODO/` and `dev/PARKING/` is a judgment call about whether work is still worth tracking, so it always gets user sign-off first.

### Phase 1: Sync `queue.md` with `dev/TODO/`

1. For every `dev/TODO/*.md` file whose task ID has no line in `queue.md`, append `- [T{id}](T{id}-{slug}.md): {title}` (link target is the actual filename, title from the file's H1) to the end.
2. For every line in `queue.md` whose task ID has no matching `dev/TODO/*.md` file (closed/parked by any means — a prior sweep's Phase 3, `/drive`, a manual move), remove that line.
3. Report additions and removals.

This is pure membership sync — it never reorders an existing, still-valid line.

### Phase 2: Fix stale blockers + enforce blocker ordering

Fully automatic — no approval needed. Resolving a stale blocker is reading a fact off the filesystem (does T{id} still exist in `dev/TODO/`?), and enforcing topological order is mechanical once a violation is found.

1. For each task with status containing `Blocked by T{id}` (treat as prefix — status may have trailing notes like `— waiting on X`):
   - Check whether T{id} exists in `dev/TODO/`.
   - **Stale** (blocker no longer exists — moved to `dev/JOURNAL/` or `dev/PARKING/`): the blocker is resolved.
     - **Update the TODO file:**
       - If all blockers are resolved, update Status to the appropriate next state (Open or Design, based on whether a design section exists). Preserve any non-blocker notes.
       - Strike through resolved dependency lines (e.g. `~~**T{id}** — description~~ ✅ Done (see dev/JOURNAL/<filename>)`). Link to the actual journal file if found.
   - **Still valid** (blocker exists in `dev/TODO/`): check `queue.md` — the blocker must appear **before** the task it blocks. A blocker ranked *behind* what it blocks is a broken order (you can't start the blocked task first regardless of where the queue says to work next), not a legitimate priority call, so it isn't left for a human to resolve manually. Record any blocker found out of order as a violation.
   - Report each fix / violation found.
2. **Enforce blocker ordering**: for every violation found in step 1, use `/top T{id} --before T{blocked}` (see `/top`'s `--before` mode) — inserting the blocker immediately ahead of the specific task it blocks, not jumping it to the absolute front. This still produces a topological order (every blocker ends up ahead of everything it blocks, every sweep run) without needlessly burying unrelated higher-priority work that has nothing to do with this blocker — a plain `/top` would leapfrog it over everything, `--before` only over what it actually gates. Group violations by their **shared** blocked task first — if several blockers block the *same* `T{blocked}`, pass them all to one `/top T{id1} T{id2} ... --before T{blocked}` call (in their current `queue.md` order, front-most first, so relative order among them is preserved); blockers with *different* targets need separate `/top --before` calls, one per distinct target.
3. Show a summary of Phase 2 changes (blockers resolved + orderings enforced).

### Phase 3: Prune the backlog

**Goal: keep the backlog actionable — auto-close finished/superseded work, ask before parking anything blocked or stale.** No task merging: two related tasks stay two tasks — a prior "Consolidate" recommendation was dropped because merging didn't reduce real work, it just added bookkeeping.

**Step A — auto-close (no approval needed):**

These two signals require no judgment call — reading a status flag or an explicit cross-reference, not an interpretation:

- **Done**: `status: Done` but the file is still sitting in `dev/TODO/` (should have moved when it was marked Done — this just catches up).
- **Superseded**: task mentions another task that covers the same scope (e.g. "absorbed by T{id}"), or the work has already been done.

For each: add `## Closed (YYYY-MM-DD)` with a pointer (the covering task/PR, or "marked Done" for the Done signal), `git mv dev/TODO/{file} dev/JOURNAL/yyyy-mm-dd-{file}`, and remove its line from `queue.md`. Report what was closed — git history makes every move revertable, so there's no need to gate this behind approval.

**Step B — ask before parking:**

1. Score remaining tasks for park-worthiness:
   - **Blocked indefinitely**: blocked by an external dependency (upstream team, infrastructure) with no ETA.
   - **Revisit**: already in legacy `Revisit` status — belongs in the parking lot, not active backlog.

2. Present candidates in a table:

```
| ID | Title | Signal | Recommendation |
|----|-------|--------|-----------------|
```

Recommendation is always **Park** — move to `dev/PARKING/`.

3. **Ask the user for approval** before acting. The user may override individual recommendations. This is the one step in `sweep` that always waits for a human: moving something out of the active backlog (even to the parking lot, not JOURNAL) is a call about whether it's still worth tracking, not a fact `sweep` can read off the file.

4. For each approved Park: update the frontmatter `status:` to `Parked`, add `## Parked (YYYY-MM-DD)` with reason to the task body, `git mv dev/TODO/{file} dev/PARKING/{file}`, and remove its line from `queue.md` — in the same commit, so `queue.md` never drifts out of sync with what Phase 3 just did.

5. Show final summary: queue sync (Phase 1) + blockers fixed (Phase 2) + tasks auto-closed (Step A) + tasks parked (Step B) + remaining open count + parking lot count.

### Parking Lot (`dev/PARKING/`)

Parked tasks live in `dev/PARKING/*.md` — same format as TODO files but not competing for attention, and not in `queue.md`. New work should use parking-lot semantics instead of the old `Revisit` status. If a task is still marked `Revisit` in `dev/TODO/`, treat that as a legacy status that `/todo sweep` should migrate into `dev/PARKING/`; no new task should remain in `dev/TODO/` as `Revisit`.

- `/todo list` shows a `Parking lot: N parked` count at the bottom. Legacy `Revisit` items may still appear in TODO results until `/todo sweep` parks them.
- `/todo next` should not pick legacy `Revisit` items; they are effectively parked pending migration.
- `/drive` reviews one parked task after completing each TODO item (see drive skill).
- To revive: `git mv dev/PARKING/{file} dev/TODO/{file}`, update status to `Open` or `Design`, and add it back to `queue.md` (`/stage` it, or let the next `sweep` pick it up).
