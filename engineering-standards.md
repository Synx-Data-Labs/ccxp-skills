# Engineering standards

The quality bar for code and design across the fleet — *what good looks like*.
The day-to-day mechanics (lifecycle, branch/merge, script patterns) live in each
repo's `dev/guidelines.md`; the task/design conventions in
[`lifecycle.md`](lifecycle.md). This file adds the practices that keep quality
from decaying task-by-task — gated by [`design-score`](design-score/SKILL.md)
and measured by the `quality-probe` skill.

This file lives in `ccxp-skills` (peer to `lifecycle.md` / `gotchas.md` /
`glossary.md`); each repo's `dev/guidelines.md` references it rather than
restating it.

## Foundations (defined in `dev/guidelines.md`)

KISS, DRY, and *fix the root cause, not the symptom* are the baseline — defined
in each repo's `dev/guidelines.md`, not restated here.

## Test-driven development (the code-class default)

Red → green → refactor is the default for all code-class work (`/drive` Phase
3.0 does the classification; the discipline lives in the
`superpowers:test-driven-development` skill). Write the failing test first, watch
it fail *for the right reason*, then write the minimal code to pass. Scripts
under `scripts/` require a BATS (or unit) case — no exceptions (`dev/guidelines.md`).

## Test-driven refactoring

Refactor only under green tests. Before touching untested legacy code, write
**characterization tests** that pin its current behavior, then refactor against
them. A refactor that changes behavior is a feature change — treat it as one
(failing test first).

## Simple shared-library design

- **Rule of three** before extraction — don't abstract on the second use; wait
  for the third real call site so the shared shape is grounded, not guessed.
- **One purpose per module** — if its name needs an "and", split it.
- **Legible without internals** — a caller should know how to use it from the
  signature plus a one-line doc, without reading the body.
- Prefer composition and small **sourceable, function-wrapped** bash over deep
  coupling (`dev/guidelines.md` script patterns).

## Quality metrics — measure, record, never silently regress

We measure quality per task on **touched files** (not the repo's legacy debt)
and keep a trend, so decay is visible instead of silent:

- **What** — shellcheck findings, test coverage, file/function size, duplication,
  secrets, code-scanning (CodeQL / Trivy) alerts, and the `design-score` of the
  task's design doc.
- **Posture** — *record + warn*, not a hard gate (the one exception is
  `design-score`, which gates `/drive` Phase 2 → 3): a regression emits a loud
  warning and is recorded, but the merge proceeds. The aspiration is to **hold or
  improve** every metric, task by task; chronic regression is surfaced at `/retro`.
- **How** — the `quality-probe` skill appends one record per task to
  `dev/quality/metrics.jsonl` in the target repo; `/retro` reviews the rolling
  3-week trend and files remediation chores via `/stage`.

*Why record+warn rather than a gate:* the cheap deterministic check
(`design-score`) gates; the noisier trailing metrics observe-first until the
trend is trusted — then we revisit promoting them to a soft, and later hard,
gate.
