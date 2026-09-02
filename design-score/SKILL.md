---
name: design-score
description: Use when checking whether a /drive design doc clears the quality bar before implementation — a deterministic 0–100 structural score that gates Phase 2 → Phase 3
disable-model-invocation: false
argument-hint: "<task-file> [--kind code|docs] [--threshold N] [--json]"
---

# Design Score

Deterministically score a task/design doc against
[`repo-conventions/templates/design-doc.md`](../repo-conventions/templates/design-doc.md)
and gate `/drive` **Phase 2 → Phase 3** on the result: a design must clear the
threshold before any implementation begins (T20260609-204303 D3).

This is the **hard gate** of the code-quality bar — cheap and deterministic, it
catches design decay before a single line of code exists. (Its sibling, the
`quality-probe` trailing metric, is *record + warn*; the asymmetry is
deliberate.) **Deterministic only** in this increment — no LLM rubric.

## Argument

```
score.sh <task-file> [--kind code|docs] [--threshold N] [--json]
```

- `<task-file>` — the `dev/TODO/T<id>-<slug>.md` design doc to score (required).
- `--kind code|docs` — override change-kind auto-detection (see below).
- `--threshold N` — pass mark (default **70**).
- `--json` — emit `{"score":N,"threshold":N,"pass":bool,"kind":"code|docs","checks":{…}}`
  instead of the human-readable breakdown.

Exit **0** if `score >= threshold`, **1** otherwise (and on usage / IO errors).

## Workflow

```bash
bash ~/.claude/skills/design-score/scripts/score.sh <task-file>
```

- Default output: a per-check breakdown + total + **PASS/FAIL**.
- Add `--json` for machine consumption (e.g. the `design_score` field the
  `quality-probe` scoreboard records).
- The script is sourceable and function-wrapped; the CLI runs only under the
  direct-execution guard.

## The 7 checks — each has its own ceiling; the total is *normalized*, not summed

| # | Check | Max | What it measures |
|---|-------|-----|------------------|
| C1 | Frontmatter completeness | 20 | `estimation` · `status` · `source` · `related` (4 each) + `priority` **with a rationale** (4 — the value must carry text beyond the bare level, e.g. `P2 — <why>`). `scheduled` is set by the IPM and is **not** scored. |
| C2 | §Common section presence | 28 | The 7 body sections — `TLDR`, `Problem`, `Plan`/`Scope`/`Solution`, `Test plan`, `Done criteria`, `Closed`, `Skills invoked` — 4 each. `TLDR` is mandatory, not a bonus: a design a maintainer can't skim in 10 seconds fails its primary job. |
| C3 | §Code-only handling | 10 | **code-class:** `Root cause` (5) + `Repo file references` (5). **docs-class:** full 10, **but −5** if stubbed code-only sections are present (padding). |
| C4 | Test-plan checkbox | 6 | The Test-plan section has ≥1 `- [ ]` / `- [x]`. |
| C5 | Done-criteria mapping | 16 | × the fraction of done-criteria checkboxes that cite a test name, `file:line`, a 7–40-hex SHA, a PR `#N`, or a skill ref. An unmapped criterion is untested or vague. |
| C6 | Evidence-anchor density | 18 | × the fraction of the present prose sections among {`Problem`, `Plan`/`Scope`/`Solution`, `Root cause` (code-class only)} that contain ≥1 anchor: `file:line` \| 7–40-hex SHA \| fenced code/command block \| PR `#N`. |
| C7 | Alternatives-rejected | 6 | The Plan/Scope/Solution section inlines an alternative *considered and rejected* (matches `reject` / `alternative`). |

`Plan`, `Scope`, and `Solution` are interchangeable heading names for the same
section — pick whichever fits the task (see the template). `Context` and
`Appendix` are recommended by the template for readability but are **not**
separately scored — adding or omitting them doesn't move C1–C7. `TLDR` *is*
scored, as part of C2 above — it's required, not optional.

**The checks' maxes (20+28+10+6+16+18+6 = 104) don't need to sum to 100.**
`design-score` sums the earned points (`raw`), sums the checks' own ceilings
(`max_sum`), and normalizes: `pct = round(100 * raw / max_sum)`. Adding an 8th
check later is one new function plus one new `max_sum` term — no hand-trimming
some unrelated existing check to keep a fixed 100-point budget balanced (the
`TLDR` addition above used to require exactly that kind of trim; it doesn't
anymore).

**Placeholder penalty:** −4 each for `TBD` / `TODO` / `FIXME` / `???` / `<…>` in
the body, **excluding** fenced code blocks and `<!-- … -->` scaffold comments.
Applied as flat percentage-points *after* normalization (`total = pct + penalty`),
floored at 0.

## Change-kind auto-detect

When `--kind` is omitted the doc is classified **code-class** if it has a
`## Root cause` or `## Repo file references` heading, OR its body references code
paths (`scripts/`, `*.sh`, `*.py`, `*.ts`, `.github/workflows`); otherwise
**docs-class**. `--kind` overrides. Mirror the `/drive` Phase 3.0 docs/code
classifier — a docs chore omits the code-only sections and should be scored as
docs.

## Rubric intent

The bar is *the right sections completed with evidence*, **not a line count**. A
well-formed code-class design clears the threshold comfortably; a docs chore
clears it without code-only padding. Missing §Common sections, anchor-less
prose, unmapped done-criteria, and placeholder text each dock predictable
points — see `tests/design_score.bats` for the pinned bands.

## Testing

`tests/design_score.bats` (run `bats tests/design_score.bats`) pins the scoring
behavior against `tests/fixtures/design-score/` — a complete code-class design
(PASS ≥85), a poor one (FAIL <70), and docs-class clean/padded fixtures.

## Important Notes

- **Gate placement:** `/drive` runs this at the Phase 2 → Phase 3 boundary —
  *after* the design PR merges, *before* Phase 3.0. Below threshold ⇒ the design
  is not ready; fix the gaps before coding.
- **Deterministic only.** This increment scores structure, not argument
  quality; an LLM rubric is deferred to a later increment.
- Requires `jq`.
