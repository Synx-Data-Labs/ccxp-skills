# Task Lifecycle (Your Company)

Canonical conventions for tasks across all your-org repos. This file lives in `ccxp-skills` because the same repo holds the skills that enforce the conventions (`/drive`, `/todo`, `/gcpr`, `/address-pr`, `/ccxp`). Consumer repos (`hub-repo`, `build-pipeline-repo`, `example-website.com`, etc.) carry a short pointer to this file rather than their own copy.

## File Layout

Tasks live as individual files — the filesystem is the index.

- **Open tasks**: `dev/TODO/*.md` — one file per task
- **Parked tasks**: `dev/PARKING/*.md` — valid but not actionable now (reviewed periodically)
- **Completed tasks / journal**: `dev/JOURNAL/*.md` — permanent record

## Task ID Format

New tasks use timestamp-based IDs to avoid cross-branch conflicts:

```
TYYYYMMDD-NNNNNN
```

Where `NNNNNN` is a 6-digit random number. Generate with:

```bash
printf "T%s-%06d\n" "$(date +%Y%m%d)" "$(od -An -tu4 -N4 /dev/urandom | tr -d ' ' | cut -c1-6)"
```

Or via the ccxp-skills helper: `bash _taskid/new.sh`, run from the ccxp-skills repo root (or `../_taskid/new.sh` when invoked from within another loaded skill's own directory).

Open TODO tasks previously tracked as legacy IDs (T26, T29, etc.) were migrated to the `TYYYYMMDD-NNNNNN` format using their original creation date. Historical journal entries and filenames may still retain legacy `TNN` IDs.

## Task File Structure

Task metadata uses **YAML frontmatter** (`---` … `---` at the top of the file), same convention as `SKILL.md` files in this repo. The H1 title follows the frontmatter block.

```markdown
---
estimation: {30m|1h|2h|4h|1d|2d|1w|2w}
status: {Open|Design|Coding|Review|Blocked by T{id}}
source: {GitHub issue, upstream link, or process note}
description: {One-line summary of what's wrong and what "done" looks like}
---

# T{ID}: {Title}
```

Optional metadata fields:

- `blocks: [T{id1}, T{id2}]` — YAML list, records what this task is holding up (bidirectional)
- `deadline: YYYY-MM-DD` — release or hard deadline
- `scheduled: YYYY-MM-DD` — a Monday; set by `/ccxp` Phase 2a.5 at IPM commit, for whichever tasks land in that iteration. Update-forward-only — never removed (see the Iteration assignment section below)
- `target-repo: <owner/name>` + `target-path: <abs-path>` — cross-repo dispatch (task lives in hub repo, implementation lands elsewhere; see `/drive` Phase 1.5). **Exact key spelling matters**: `lint_tasks.py`'s allowlist requires lowercase-hyphenated `target-repo`/`target-path` — not `Target repo`/`Target path`, even though some skill prose (e.g. `/drive`'s own illustrative bullet) formats the concept in that human-readable capitalized form. Verify against existing closed examples (`grep -rl "target-repo:" dev/JOURNAL/`) rather than a skill's prose example.

There is no `priority:` field. Priority is a task's position in `dev/TODO/queue.md`
(see `/todo`) — `/stage` appends a task to the end of the queue; `/top` moves
one to the front. `/todo next` reads the queue top-to-bottom; it no longer
computes a score.

See `todo/SKILL.md` "Task metadata" section for the full field semantics.

**Templates** (the canonical scaffolds — copy these, don't hand-copy a recent file):

- New task: [`repo-conventions/templates/task.md`](repo-conventions/templates/task.md)
- Design section (grown during `/drive`): [`repo-conventions/templates/design-doc.md`](repo-conventions/templates/design-doc.md)

**Backwards compatibility**: Legacy task files (filed before the 2026-05-14 frontmatter migration) carry leading-bullet metadata (`- **Status**: …`). Skills treat both formats as equivalent when reading.

## Status Flow

```
Open → Design → Coding → Review → Done
         ↕                          ↕
    Blocked by T{id}             Parked
```

> **Done** means the file is **moved** from `dev/TODO/` to `dev/JOURNAL/`.
> **Parked** means the file is **moved** from `dev/TODO/` to `dev/PARKING/` — not actionable now, reviewed periodically by `/drive`.

| Status | Meaning |
|--------|---------|
| Open | Not yet started — queued for future work |
| **Design** | Research, planning, writing the design journal entry |
| **Coding** | Implementation — writing code, scripts, tests |
| **Review** | PR open or awaiting verification/sign-off |
| Blocked by T{id} | Cannot proceed until dependency is resolved (list all blockers) |
| Parked | Moved to `dev/PARKING/` — valid but not actionable now. Use `/todo sweep` to park tasks. |
| Done | Move to `dev/JOURNAL/` — the journal entry is the permanent record |

The active states `Design`, `Coding`, `Review`, `Blocked` live in the task file's frontmatter `status:` field. The file is the single source of truth — no external mirror. (Previously: claims were mirrored to `your-org/projects/1` via `_claims/`; removed in T20260513-422869 alongside the one-session-per-clone convention.)

**Session visibility** (separate from lifecycle status): `/drive` and `/address-pr` write a thin "which session is on this task right now" annotation to the Project item — see `_session/README.md`. Soft visualization, not coordination: failures don't block, and this layer alone never refuses work. The actual race protection is the on-main `task_claim.sh` lock (`claimed_by:` frontmatter, arbitrated atomically by the merge to `main`) — peer mode by default (`_session/README.md`'s "Task-claim lock" section), not the older one-session-per-clone-only model. Any path that flips a task's status out of `Open` should take this claim first (T20260610-248248) — `/drive` Phase 1 and `/ccxp` Phase 2a.3 both do.

**PR ref in title**: when a PR opens for a tracked task, `/gcpr` and `/address-pr` append `(<repo>#<num>)` to the task's issue title (e.g. `T20260510-285938: … (ccxp-skills#37)`), so the board shows the task→PR mapping at a glance. Idempotent and best-effort; the `T{id}:` prefix is preserved. See `_session/set-pr-ref.sh`.

## Blocking: Bidirectional Links

Blocking relationships are recorded in **both** directions:

- **Blocked task**: frontmatter `status: Blocked by T{id}` — cannot proceed until blocker is resolved
- **Blocking task**: frontmatter `blocks: [T{id}]` (YAML list) — records what this task is holding up

Always maintain both sides. When adding `Blocked by T{id}` to a task's `status`, also add `T{other}` to the blocker's `blocks` list. This lets `/todo next` prioritize blockers that unblock the most work.

**`/top` follows the blocker chain.** `/top T{id}` on a blocked task expands to `[blocker-chain..., T{id}]` before reordering, walking the structured `status: Blocked by T{id}` field (never `related:` — that's soft context, not a hard dependency) recursively, capped at 10 hops with a hard-stop on a cycle. This puts the task that's actually actionable next at the very front of `dev/TODO/queue.md`, instead of surfacing a task whose own prerequisite is still buried mid-queue. A blocker not found in `dev/TODO/` (already closed, or lives in another repo) is skipped.

**Cascade-unblock on completion.** When you complete a task (move it to `dev/JOURNAL/`), clear or retarget the `status: Blocked by T{id}` of every task it was blocking — otherwise dependents silently keep a stale block and drop off `/todo next`. The `lint-tasks` action enforces this: a `Blocked by T{id}` that points at a task already in `dev/JOURNAL/` (Done), or at no task file at all, fails CI. The check is board-wide and keyed on `status:` (not the free-text `blocked-by:` field).

## Iteration assignment

The `scheduled: <YYYY-MM-DD>` frontmatter field — always a Monday — is the **only** iteration input: there is no `Iteration:`-by-title field. The task file is the source of truth; the GH Project Iteration is a one-way mirror, derived by the `sync-tasks-to-issues.py` workflow, which maps `scheduled` to whichever iteration's date range contains it.

`scheduled` is set two ways: **softly** by `/stage` (set to *next* Monday when a task is staged — a soft commitment that surfaces it on the board's "Next iteration" view), and **firmly** by `/ccxp` Phase 2a.5 at IPM commit (set to *this* Monday for every Tier 1 / Tier 2 task).

`scheduled` is **update-forward-only — never removed**. Its current value is always the last-scheduling record (no git archaeology needed). So "has `scheduled`" does **not** mean "is committed"; the test is a window: **a task is committed to an active iteration iff `scheduled` ≥ the current week's Monday.** A *past* `scheduled` is a historical record — the task is back to fresh-candidate status, re-ranked by `/todo next` like any backlog item (on the board it maps to a past iteration, so it never pollutes the current/next views).

A task **deferred ("cut")** at an IPM has its `scheduled` *advanced* to next Monday (Phase 2a.5) and is pre-appended to next week's `## Candidates` stub, so it rolls into the next iteration on both the board and the doc. The next IPM re-surfaces it (Phase 2a.1.5, deduped) and either commits it (stamping that IPM's Monday) or re-cuts it (advancing again). A cut never silently drops; chronic deferral is caught by `/retro`'s bump-counter, which escalates a task bumped 3× via `/top` — moving it to the front of `dev/TODO/queue.md` instead of leaving it to drift down the backlog again.

**`scheduled:` — not local IPM prose — is what actually answers "what's in / left from iteration N."** A hand-maintained `dev/JOURNAL/*-ipm-weekly.md` table can drift from it: a straight numbering off-by-one (a table can call a week "Iteration 11" while the same week's start date actually maps to "Iteration 10"), or a table claiming a task was carried into the next iteration when its `scheduled:` was never actually bumped, leaving it pinned to the old iteration regardless of what the prose says. For a team that has wired up the `sync-tasks-to-issues.py` action, the GitHub Project board's `Iteration` field is a convenient, mechanically-derived mirror of `scheduled:` — a good visual read for "what's in iteration N" without re-deriving it by hand. But the board is optional tooling, not a requirement: `scheduled:` plus the local `dev/TODO/` and `dev/JOURNAL/*.md` files are fully sufficient on their own to answer "what's in iteration N," with no board sync wired up at all.

**Note (2026-07-03):** the paragraph above describes `/ccxp` Phase 2a's Tier-based candidate/cut mechanics, which predate the `dev/TODO/queue.md` model `/todo`/`/stage`/`/top` now use and haven't been reconciled with it yet — treat this section as accurate to `/ccxp`'s current behavior, not as the target design. Phase 2a is expected to simplify to "take the top N queue entries that fit the budget" (no more Tier 1/2/3 partition); this doc should be rewritten once that lands.

**Invariant**: a task whose `status` is beyond `Open` MUST carry a non-empty `scheduled:` reflecting when the work actually happened. Three sanctioned writes close the gap between scheduling-intent (`/stage`, `/ccxp`) and reality:

1. **Early-pickup re-stamp (case a):** `scheduled:` is set but to a *future* Monday and work starts before it → re-stamp to the *current* Monday. The previous value is superseded; the task is being worked earlier than planned.
2. **Empty-on-advance stamp (case b):** `scheduled:` is empty and status leaves `Open` → stamp the *current* Monday. Covers tasks filed directly in-progress or promoted without an IPM commit.
3. **Done = completion-date Monday:** when a task moves to `dev/JOURNAL/`, set `scheduled:` to the Monday of the `yyyy-mm-dd` date prefix used in the JOURNAL filename (the week the work shipped). Idempotent — leave it unchanged if already set.

"Update-forward-only" still governs *deferral*. These reality-stamps are the sanctioned exceptions: re-stamps on actual start move only to the *current* week's Monday (never backward past it), and the Done stamp uses the genuine — correctly historical — completion date. A *past* `scheduled:` (already before the current Monday) is left untouched in all cases. `dev-task-lint` enforces this invariant: a TODO/PARKING file whose `status` leading token is beyond `Open`/`Parked` and whose `scheduled:` is absent or not a valid date fails CI.

## Estimation

Tasks carry a free-text time-based estimate (e.g. `1h`, `0.5d`, `2w`). For a small team, time estimates are more grounded than story points — `1d` tells you whether work fits in a day, while `3 points` requires a calibrated team velocity to interpret.

**`lint-tasks` v5 requires `estimation` to START with a bare duration** — regex `^\d+(m|h|d|w)\b`, units `m|h|d|w` only (no `s`). So `~2d remaining …` FAILS (the `~` prefix breaks the match) but `2d remaining …` passes (trailing prose after the duration is fine). It lints only a PR's **changed** task files (`mode: changed`), so pre-existing non-conforming `estimation:` values already on `main` are not valid precedent — they simply haven't been re-touched under v5 yet. Validate locally before pushing: `python3 repo-conventions/scripts/lint_tasks.py --changed <file>`, run from the ccxp-skills repo root (exit 0 = conforms).

(The previous Estimate→Size Fibonacci bucket mapping was used by `_claims/sync-tasks.sh` to derive a Project board `Size` field; that derivation was removed in T20260513-422869 along with the rest of the `_claims/` machinery. If formal-bucket grouping comes back, the previous mapping is in git history.)

## Creating a Task

1. Generate a task ID (the output includes the `T` prefix, e.g. `T20260320-042851`)
2. Create `dev/TODO/{id}-slug.md` (e.g. `dev/TODO/T20260320-042851-my-task.md`) with metadata as markdown bullets in this order: Estimation, Status, optional Blocks, Source, Description
3. Set estimation per the table above
4. Include: what's wrong, where it is, and what "done" looks like
5. If blocked: add `Blocked by T{id}` to Status, and add `Blocks` to the blocker task

## Working a Task

- **Open → Design**: Start researching and planning; add journal notes to the task file. **Always include a Test Plan section** when entering Design — define how the change will be verified (unit tests, integration dry-runs, regression checks) before writing any code.
- **Design → Coding**: Design is settled; begin implementation
- **Coding → Review**: Code is written and tested; PR is open or ready for verification
- If blocked at any stage, note what's blocking it (e.g., "Blocked by T20260320-000063")
- Keep the task file current — update it as understanding evolves
- **Refresh context on every switch.** When resuming a task after working on something else (park/resume, multi-task sessions), always re-verify `git branch --show-current` matches the task's branch and re-read the task file before making any change — jumping between branches for different tasks is a real source of stale-context mistakes.

## Completing a Task

1. **Update the task file** with final journal entry:
   - Problem: what was wrong
   - Fix: what changed and why
   - Files changed: table of affected files
   - Next steps: any follow-up work (may spawn new TODOs)
2. **Stamp `scheduled:` if empty** — before the `git mv`, if the task file's `scheduled:` is empty, set it to the Monday of the `yyyy-mm-dd` date you are about to use as the JOURNAL filename prefix. Idempotent: if `scheduled:` is already set, leave it unchanged (never overwrite an existing value). This satisfies the "Done = completion-date Monday" reality-stamp (see § "Iteration assignment") so the task shows in the correct iteration after sync.
3. **Move the file**: `git mv dev/TODO/{id}-slug.md dev/JOURNAL/yyyy-mm-dd-{id}-slug.md`
4. **Include in the implementing PR**: the journal move goes in the same PR that completes the task — not as a separate commit after merge. This keeps the task lifecycle atomic.
5. **Concrete pre-merge check**: before merging any PR that completes a task, verify the diff actually moves `dev/TODO/{id}.md` → `dev/JOURNAL/yyyy-mm-dd-{id}.md` with `status: Done` and test-plan boxes ticked. The most common miss is creating/updating the task file mid-work and simply forgetting the move at completion — a merged implementing PR whose task file is still sitting in `dev/TODO/` is that miss.

## Branch Rule

**Do NOT update `CLAUDE.md` on feature branches.** Each task file in `dev/TODO/` and `dev/JOURNAL/` is unique — different branches create different files, so they never conflict. Only update `CLAUDE.md` on `main` after merge if needed.

## Pointer convention for consumer repos

Each consumer repo carries a 2-3 line pointer back to this file rather than its own copy. Typical placement is `dev/guidelines.md` § "TODO Lifecycle" or `dev/task-lifecycle.md` (legacy filename). Example:

```markdown
## TODO Lifecycle

See [ccxp-skills/lifecycle.md](https://github.com/your-org/ccxp-skills/blob/main/lifecycle.md) for the canonical conventions (status flow, ID format, blocking, Estimate→Size mapping).
```

## Tasks about ccxp-skills itself

Since 2026-08-19, `ccxp-skills` tracks its own backlog the same way — `dev/TODO/`, `dev/PARKING/`, `dev/JOURNAL/`, per [its own `dev/guidelines.md`](https://github.com/your-org/ccxp-skills/blob/main/dev/guidelines.md).

- **File work about this repo here directly** — a bug in a shared script (`_gh/`, `_session/`, `_taskid/`, `_ipm/`, …), a new skill, skill-authoring cleanup, or an edit to this file — rather than as a cross-repo task (`target-repo: your-org/ccxp-skills`) in whichever consumer repo happened to discover it.
- **Why**: before this, such tasks were scattered one-per-discovering-repo (hub-repo, build-pipeline-repo, pointer, …), so there was no single place to see the ccxp-skills backlog.
- **Pre-2026-08-19 tasks** filed the old way in a consumer repo's hub are left where they are unless explicitly migrated — this only changes where *new* ccxp-skills-scoped tasks go.
- This does not change the cross-repo pattern itself (§ "Pointer convention for consumer repos" above) for work targeting any *other* repo — only for work targeting ccxp-skills.
