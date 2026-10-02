---
name: skill-conventions
description: Use when authoring or editing a SKILL.md in ccxp-skills, or deciding a skill's name, structure, arguments, frontmatter, or whether to extract a shared lib
disable-model-invocation: false
argument-hint: show
---

# Skill Conventions (ccxp-skills)

This suite's own conventions for authoring a SKILL.md, layered on top of generic skill-authoring guidance. For *generic* skill-authoring — what a skill is, skill types, description-as-trigger theory, RED-GREEN-REFACTOR subagent pressure-testing, frontmatter character limits — use **`superpowers:writing-skills`**. This skill documents only the deltas layered on top of it.

## Argument

`show` (default): print these conventions. No other verbs — this is a reference skill. The mechanical checks live in §10's scripts; `/retro` Phase 4c runs the recurring improvement loop.

## Conventions

### 1. Description = `Use when…` trigger

These skills are model-invocable (see §2), so the `description` is the text the model matches to decide whether to auto-invoke. Follow superpowers' rule: the description states **when** to use the skill, not **what** it does — start with `Use when …` and name concrete triggering conditions.

**Guardrail — scope action/workflow triggers tightly.** Skills that take a deliberate action (`/drive`, `/gcpr`, `/slack`, `/ccxp`, `/address-pr`) must phrase the trigger so the model does not surprise-fire them: `"Use when the user explicitly asks to …"`. Reference/diagnostic skills (`/rca`, `/proof-read`) may use broader symptom triggers (`"Use when a pipeline run has failed and you need to diagnose root cause"`).

Example — `/drive`: not `"Pick ONE task, drive it to done"` (what) but `"Use when the user explicitly asks to start focused work on a single task and drive it to a merged PR"` (tightly-scoped when).

**A second, harder mechanism exists.** The prose above is a request the model can ignore. `disable-model-invocation: true` is enforced by the harness — it blocks autonomous discovery outright. Test: **"could the model usefully reach for this autonomously?"** No (hard to reverse, high-blast-radius) → flip it, but verify first if another skill's prose nested-invokes it.

Counter-example — never flip `/drive`: the flag also blocks preloading into subagents, and `/autopilot` dispatches a subagent to run `/drive`; flipping it breaks that. Said inline in `/drive`'s own frontmatter.

### 2. Dual invocation

These skills are BOTH:

- **Model-invocable** — `disable-model-invocation: false` plus a good `Use when…` description (§1).
- **User-invocable** — an `argument-hint` so `/name <arg>` works from the slash menu.

Naming: kebab-case, a single clear verb where possible, no abbreviations or invented terms (`/drive`, `/retro`, `/sweep`). Reference skills may be noun-ish (`/repo-conventions`, `/skill-conventions`).

### 3. Argument design

Use a small set of **positional verbs**, not a flag soup. The canonical pattern is `list` / `next` / `sweep` (see `/todo`, whose `argument-hint: list | next | sweep`). Always set `argument-hint`. The default (no arg) should do the most common thing.

### 4. Shared libraries (`_<prefix>/`)

When 2+ skills need the same helper, extract it into a `_<prefix>/` directory instead of duplicating. Existing libs: `_gh/` (gh wrapper), `_taskid/` (ID minting), `_session/` (Project-board mirror). Add a `_<prefix>/README.md` documenting the lib's surface — see `_session/README.md`.

### 5. Testing

- Scripts under `_<prefix>/` get **BATS** tests (`tests/*.bats`).
- Prose-only skills need no BATS tests; their behavior is covered by §10 evals (`<skill>/evals/evals.json`).

This is this suite's counterpart to superpowers' subagent pressure-testing; we do not require that for prose skills.

### 6. Structure & voice

- Sections: `## Argument`, then `## Workflow` (or `## Conventions` for reference skills), then `## Important Notes` — omit any that do not apply.
- Write instructions **to Claude**, not to a human reader.
- Use **phase numbers as stable anchors** (e.g. `Phase 2a.5`, `§2.d`) so other skills and journal entries can cite exact steps — see `/ccxp` phase numbering and `/address-pr` §-anchors.
- Mark **best-effort** semantics explicitly when a step may fail without blocking the workflow — see the `_session` calls in `/address-pr`.

### 7. Cross-repo dispatch

A task's hub repo (where its `dev/TODO/` file lives) and its implementation's target repo don't have to be the same repo. `/drive`'s own Phase 1.5 defines the general mechanism — hub-vs-target terminology, the journal-move-PR close pattern; it makes no assumption about how many repos a team runs, or which specific repos they're named — one repo for everything (unset) or several. **For the frontmatter's exact key spelling, use `lifecycle.md`, not a skill's prose** — it documents the lint-enforced `target-repo`/`target-path` (lowercase-hyphenated) explicitly over `/drive`'s own human-readable `Target repo`/`Target path` capitalized illustration, which is not what `lint_tasks.py`'s allowlist actually requires.

### 8. Cross-references

- `dev/guidelines.md` — TODO lifecycle, naming, status flow
- `lifecycle.md` — task status transitions
- `/repo-conventions` — CLAUDE.md / guidelines.md / dev/ layout
- `superpowers:writing-skills` — generic skill-authoring this skill defers to

### 9. Deterministic logic → bundled scripts

When a SKILL.md workflow step is fully deterministic/mechanical (a parse, a lookup, a formatted report — no judgment calls), port it into a bundled, sourceable script under `<skill>/scripts/` that the workflow invokes, instead of re-deriving the logic in prose an LLM re-executes every run. Reuse §4's shared-library rule when 2+ skills need the same helper.

What stays in prose: logic that makes a real judgment call (a Park recommendation, a blocker-order decision) is not this convention's scope — only a deterministic read/transform is.

**Required validation gate before switchover**: add tests (BATS/unit, per §5) that prove behavior parity — the script's output matches the skill's own prior real invocations (or a hand-verified fixture) — before rewriting the SKILL.md workflow section to invoke the script instead of the prose it replaces. This makes §5's existing test requirement explicit as a *port-safety* gate, not just "has tests."

Worked example: [T20260914-359646](../dev/JOURNAL/2026-09-22-T20260914-359646-todo-next-as-local-script.md) ported `/todo list`'s table-rendering and `/todo next`'s queue-walk into `todo/scripts/{_lib,todo-list,todo-next}.sh`, keeping `sweep`'s judgment-call logic (blocker-order enforcement, Park recommendations) in prose since those genuinely decide, not just read.

**"Mature" enough to extract?** Use §10's ladder: a good extraction candidate is **L3+** (ideally **L4** — zero open feedback means the prose isn't still shifting). A lower rung means re-porting after the next correction.

**Vs. the `Workflow` tool**: `drive/SKILL.md` Phase 3.1's sequential `Workflow` compiles *control-flow* between steps that each still need a model call; §9 eliminates the model call entirely. Different tools for different steps — a skill can use both.

### 10. Quality loop: score → evals → feedback (novice → master)

Three deterministic instruments, all under `skill-conventions/scripts/`:

| Instrument | Grades | Command |
|---|---|---|
| `skill_score.py` | Static structure, 0–100: trigger phrasing, context cost (full marks ≤ 8 KB body), broken in-repo refs, task-ID changelog noise, sections, long paragraphs, untested scripts | `python3 skill-conventions/scripts/skill_score.py [skill…]` |
| `skill_eval.py` | Behavior: runs `<skill>/evals/evals.json` via `claude -p` in a throwaway fixture dir, grades with regex/file assertions (no LLM judge), N runs per case, pass at ≥ 90% | `python3 skill-conventions/scripts/skill_eval.py <skill> --record` |
| `skill_feedback.py` | Real-use misbehavior log (`dev/quality/skill-feedback.jsonl`) | `python3 skill-conventions/scripts/skill_feedback.py add <skill> correction "<what went wrong>"` |

**Maturity ladder** — computed by `skill_score.py`, never self-declared:

- **L0 Draft** — score < 60.
- **L1 Novice** — score ≥ 60.
- **L2 Apprentice** — + ≥ 3 eval cases with assertions.
- **L3 Practitioner** — + latest recorded eval run ≥ 90%.
- **L4 Master** — + score ≥ 85, last 3 recorded runs ≥ 90%, zero open feedback items.

**The loop** — every real-use failure becomes a permanent regression test:

1. When a skill misbehaves in use (user corrects it, it misfires, skips a step), log it with `skill_feedback.py add`.
2. Reproduce it as a failing eval case first (red), then edit the SKILL.md until it passes (green) — the §9 parity gate, applied to prose.
3. Close the item with `skill_feedback.py codify <F-id> <eval-id>`; record the run with `skill_eval.py --record`.

**Ratchet**: CI runs `skill_score.py --check dev/quality/skill-scores.json` — a score may rise but never fall below its baseline, and a new skill must reach 70. After an improvement, lock it in with `--write-baseline dev/quality/skill-scores.json`.

**Eval authoring**: prefer `command_succeeded` (bundled script ran and resolved), `tool_not_called`/`command_not_ran` (safety: no `Edit` in a read-only verb, no `gh pr merge`), and `file_matches` (end state) over `output_matches` on free text. Evals run with GitHub/Slack credentials scrubbed; a case that needs the network stubs it in its fixture.

## Important Notes

- This skill defers to `superpowers:writing-skills` for everything generic. If the two ever conflict on a *generic* point, superpowers wins; the §1–10 guardrails here are the only intentional local overrides.
