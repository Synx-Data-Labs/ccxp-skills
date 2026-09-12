---
name: grill-me
description: Use when the user explicitly asks to grill, interview, or stress-test a plan or task before implementation, or when /ccxp Phase 2a.3 runs a pre-IPM design pass on a Tier 2 candidate
disable-model-invocation: false
argument-hint: "[task-id | free-text plan]"
---

# Grill Me

Stress-test a plan through structured adversarial questioning before any
code is written. Model the plan as a **design tree** — every decision
branches into the decisions that hang off it — and interview the user in
rounds until every branch is resolved and nothing is silently assumed.

Adapted from the Hermes `grill-me` skill (Rafael Zendron + Matt Pocock's
`grilling`), re-shaped for this suite: the output lands in a `dev/TODO/`
task file's Design section so `/ccxp` Phase 2a.3 and `/drive` Phase 2 can
consume it.

## Argument

- `T<id>` — grill an existing task. Read `dev/TODO/T<id>-*.md` first; the
  Problem section (and any existing Design section) seeds the tree. On
  synthesis, write the result back into that file (Workflow step 4).
- free text — grill a raw idea. No file is touched; synthesis is printed.
  Offer `/new-task` at the end if the user wants it filed.
- omitted — ask what to grill.

## Workflow

### 1. Build the initial tree

Read the task (or the idea) and sketch the design tree privately: goal →
scope boundaries → each architectural choice → its edge cases and failure
modes. Do not show the tree; it drives which questions come next.

**Facts are your job; decisions are the user's.** Anything answerable from
the environment — the codebase, `dev/guidelines.md`, an existing pattern in
a sibling skill, CI config — look up yourself (`grep`, `read`, or a
subagent for a heavy exploration). Never ask the user for a fact you could
find. Only questions downstream of an exploration wait on it; ask the rest
of the frontier now.

### 2. Frontier rounds

The **frontier** is every decision whose prerequisites are already
settled. Ask the whole current frontier in one message, numbered, each
question carrying a recommended answer. Then stop and wait.

```
❓ Q1 — <title>: <question, options if relevant>
➡️ Recommendation: <recommended answer + one-line why>

❓ Q2 — <title>: <question>
➡️ Recommendation: <...>
```

A question whose answer depends on another question still open in this
round belongs to a **later** round. After each reply, recompute the
frontier and ask the next round. Stop when the frontier is empty.

Cover these branches in the tree:

- **Understanding** — actual objective; what is explicitly IN and OUT of
  scope; constraints (time, tech, dependencies); who consumes the result.
- **Technical decisions** — for each choice: "why this and not X?", "what
  if Y fails?", "worst case?", "how do you roll back?". If the suite
  already has a pattern for this (a `_<prefix>/` lib, a phase in a sibling
  skill), name it and ask whether to reuse it.
- **Edge cases** — unexpected input; a dependency down; 100x volume; the
  cron/unattended path vs. the interactive path; security implications.
- **Verification** — how will "done" be proven? This becomes the Test
  Plan, which `lifecycle.md` requires before a task enters `Design`.

### 3. Synthesis (frontier empty)

Print:

1. **Decisions** — every settled decision as one bullet each
2. **Open** — anything still undecided, and why it can wait
3. **Out of scope** — what was explicitly excluded
4. **Estimate** — a revised `estimation` (`15m|30m|1h|2h|4h|1d|2d|1w`) with
   a one-line reason if it differs from the task's current value
5. Ask: "Aligned? Should I record this, or adjust anything?"

Do not proceed until the user confirms.

### 4. Record (task-id mode only)

On confirmation, edit `dev/TODO/T<id>-*.md`:

- Write or refresh the `## Design` section with the Decisions / Open /
  Out-of-scope bullets and a `### Test Plan` sub-section (bullets, ~3 per
  level — `dev/guidelines.md` Documentation rules).
- If the estimate changed, update the `estimation:` frontmatter and append
  to the Design section: `Estimation revised from {old} to {new}: {reason}`
  (the exact shape `/ccxp` Phase 2a.3 step 3 and `/retro`'s
  estimate-vs-actual grading expect).
- Do **not** change `status:`, `claimed_by:`, or `scheduled:` — the caller
  owns lifecycle transitions (`/ccxp` 2a.3 step 4 claims and sets status;
  `/drive` Phase 2 does its own).
- Lint the touched file, scoped, never repo-wide:

  ```bash
  python3 ~/.claude/skills/repo-conventions/scripts/lint_tasks.py --changed dev/TODO/T<id>-*.md
  bash ~/.claude/skills/_docs/lint-docs.sh --fix
  ```

Leave the change uncommitted — the caller decides how it lands (`/ccxp`
2a.3 batches all candidates into one PR; an ad-hoc user runs `/gcpr`).

## Important Notes

- **Never write code during the interview.** Alignment only; implementation
  is `/drive`'s job after an explicit green light.
- **Do not accept "I don't know" as final.** Offer options, trade-offs, and
  a recommendation; if the user still can't decide, record it under *Open*
  and, when it blocks implementation, tell the caller so `/ccxp` 2a.3 step
  2 can escalate via Slack and skip the task this week.
- **Be adversarial.** The job is to find problems. If everything looks
  fine, look harder — a plan that survives zero pushback was not grilled.
- **One round per message.** Do not batch dependent questions, and do not
  answer your own questions.
- **Interview in the user's language.**
- Not for existing code (`/address-pr`, `superpowers:requesting-code-review`)
  or trivial one-off tasks — grilling a 15m chore wastes more than it saves.
