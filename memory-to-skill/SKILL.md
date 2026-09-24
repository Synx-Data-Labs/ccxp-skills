---
name: memory-to-skill
description: Use when the user explicitly asks to review the current clone's auto-memory, prune stale entries, or turn recurring memories into a durable skill/doc/hook change
disable-model-invocation: false
argument-hint: "[dry-run]"
---

Review the CURRENT clone's Claude Code auto-memory files, delete what's
stale, and codify what's proven durable into its permanent home — a skill's
`SKILL.md`, `dev/guidelines.md`, `DEPENDENCIES.md`/`gotchas.md`, or a
hard-gate hook. When a recurring memory doesn't map to any existing
skill or doc, file a task to design a NEW skill for it instead of forcing
a bad fit or dropping it.

This is `/retro` Phase 1b's memory-review logic, extracted so it can run
on demand from a single clone without the rest of the weekly retro. See
**Cross-references** for how the two relate.

## Argument

`dry-run` — optional. Report findings (stale candidates, consolidation
targets, new-skill candidates) without deleting memory files or filing
tasks. Default (no argument): apply the changes.

## Scope

**Current clone only.** No sweep across other checkouts of the same repo
(`/retro` Phase 1b does that separately, with its own stale-directory
detection). If more than one clone of a repo has accumulated memory, run
this skill again from each clone.

## Workflow

### 1. Locate this clone's memory directory

```bash
bash memory-to-skill/scripts/find-memory-dir.sh
```

Prints the absolute path to `~/.claude/projects/<encoded-cwd>/memory`, or
exits 1 if this clone has never accumulated memory — in that case, report
"no memory to review" and stop.

### 2. Read every memory

Read that directory's `MEMORY.md` for the index, then read each linked
`.md` file in full. Memory types: `user` (role/preferences), `feedback`
(corrections and validated approaches), `project` (decisions, constraints,
context), `reference` (pointers to external systems).

### 3. Assess each memory

For each entry, decide:

- **Still current?** Check whether the underlying fact is still true (a
  bug may be fixed, a convention may have changed, a project may have
  shipped). If stale, delete the memory file and remove its `MEMORY.md`
  entry — do this immediately, don't defer to step 4.
- **Worth codifying?** A `feedback` or `project` memory that's proven
  useful across sessions should be promoted to a permanent home instead
  of living only in auto-memory:
  - Process rules → `dev/guidelines.md`
  - Cross-repo skill behavior → that skill's own `SKILL.md` in this
    plugin source (`<name>/SKILL.md`)
  - Behavior specific to a single repo's own skill → that repo's
    project-scoped `.claude/skills/<name>/SKILL.md` instead of the
    global one
  - Pipeline/build conventions → `DEPENDENCIES.md` or workflow comments
    in that repo
  - Recurring cross-repo diagnostic patterns (symptom + root cause + fix
    not tied to one repo's specific build) → `gotchas.md`
  - A `feedback` memory that got **violated again** despite already
    being recorded → prose alone isn't working; escalate to a hard gate
    (a `PreToolUse`/`PostToolUse` hook, or a wrapper/validation script)
    instead of just rewording the memory
  - **No existing skill or doc fits** (see step 4) → don't force it

### 4. New-skill branch

If a memory describes a recurring need — the same workaround, the same
manual step, the same judgment call — and none of step 3's targets
actually fit it (it isn't a tweak to an existing skill's behavior, a
process rule, or a diagnostic pattern; it's a capability that doesn't
exist yet), file a task to **design a new skill** for it:

```bash
/new-task "Design /<candidate-name>: <one-line gloss of the recurring need, sourced from the memory>"
```

Let `/new-task` gather the rest through its normal back-and-forth — don't
fabricate the task's Problem/estimation from the memory alone. Reference
the source memory's content in the task's Problem bullets so the design
work has the original evidence, then delete the memory (its job — get
this codified — is now tracked as a task, so keeping the memory too
would duplicate it).

### 5. File consolidation tasks

For each codify-able item from step 3 that isn't a trivial one-line edit
you're making directly: file a task (`bash ../_taskid/new.sh --check
./dev` + the task template), tagged `Category: process` and `Source:
memory-to-skill YYYY-MM-DD`. For a small, obvious edit (e.g. one bullet
added to `dev/guidelines.md`), just make the edit directly instead of
filing a task to describe making it — use judgment the way `/retro` Phase
1b does.

### 6. Report

Summarize:

- Total memories reviewed: N (user: X, feedback: Y, project: Z, reference: W)
- Stale memories removed: list
- Consolidated: list (target file, and task ID if one was filed)
- New-skill candidates: list (task ID)

In `dry-run` mode, report the same shape but with "would remove" / "would
consolidate" / "would file" — make no file changes and file no tasks.

## Cross-references

- `/retro` Phase 1b — the multi-clone version of this same review, run
  weekly as part of the full retrospective. `/retro` Phase 1b may in
  future call this skill directly (per-clone) and layer its own
  cross-clone sweep + stale-directory detection on top, instead of
  duplicating the assess/codify logic — noted here as a follow-up, not
  implemented as part of this task.
- `/new-task` — files both the new-skill-design tasks (step 4) and the
  consolidation tasks (step 5)
- `dev/guidelines.md`, `gotchas.md`, `DEPENDENCIES.md` — common
  consolidation targets
