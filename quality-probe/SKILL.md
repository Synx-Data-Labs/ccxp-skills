---
name: quality-probe
description: Use after implementing a task (pre-PR) to measure code quality on the task's TOUCHED files and append one record per task to dev/quality/metrics.jsonl in the target repo — record+warn, never block
disable-model-invocation: false
argument-hint: "--task <T-id> (--range <git-range> | --files <csv>) [--repo-root <path>] [--date YYYY-MM-DD] [--design-score N] [--json]"
---

# Quality Probe

Measure code quality on a task's **touched files** (not the repo's legacy debt)
and append one record per task to an append-only scoreboard
`dev/quality/metrics.jsonl` in the **target (consumer) repo**, so quality trend
is visible task-by-task (T20260609-204303 D2).

This is the **trailing, record+warn** half of the code-quality bar. Its sibling
`design-score` is the cheap deterministic **hard gate** (`/drive` Phase 2 → 3);
this probe instead *observes-first* — it records and warns loudly on a
regression but **never blocks the merge**. The asymmetry is deliberate; see
[`engineering-standards.md`](../engineering-standards.md) ("Quality metrics —
measure, record, never silently regress").

## Argument

```
probe.sh --task <T-id> (--range <git-range> | --files <csv>)
         [--repo-root <path>] [--date YYYY-MM-DD] [--design-score N] [--json]
```

- `--task <T-id>` — task id recorded in the scoreboard line (**required**).
- `--range <git-range>` — git range for touched files (default
  `origin/main...HEAD`); files come from `git -C <repo-root> diff --name-only`.
- `--files <csv>` — explicit comma-separated touched-file list; **overrides**
  `--range` (no git needed — used by tests and ad-hoc runs).
- `--repo-root <path>` — target repo root (default: cwd). The scoreboard lives
  at `<repo-root>/dev/quality/metrics.jsonl`.
- `--date YYYY-MM-DD` — record date (default: today; set only in the CLI
  entrypoint so the testable functions stay deterministic).
- `--design-score N` — the `design-score` of the task's design doc, recorded as
  the `design_score` field (default `null` — not hard-coupled to that skill).
- `--json` — print the assembled record to stdout (it is appended either way).

Exit **0 always** (record + warn) — the only non-zero exits are usage / IO
errors (missing `--task`, unreadable `--repo-root`, a `--range` diff that can't
run with no `--files`, an un-writable scoreboard).

## Workflow

```bash
bash ../quality-probe/scripts/probe.sh \
  --task T20260610-123456 --repo-root /path/to/target-repo --design-score 86
```

Output: a one-line human summary plus a loud
`WARNING: <metric> regressed (delta X)` line for every metric that moved in the
worse direction vs the last record. The record is appended to the scoreboard
regardless.

The script is **sourceable and function-wrapped**; the CLI runs only under the
`[[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]` direct-execution guard, so BATS can
source it and test the pure parse functions directly
(`tests/quality_probe.bats`).

## The probes

Each probe measures the touched files only. **A missing tool records that field
as `null` and logs `skip: <tool> not installed` to stderr — it never errors**
(graceful while probes/repos are incomplete; an un-probed repo is *un-measured*,
not blocked).

| Field | Tool | What it measures |
|-------|------|------------------|
| `shellcheck` | `shellcheck -f gcc` | `{error, warning, info, style}` counts over touched `*.sh`. **Note:** the gcc format collapses shellcheck's *info* and *style* into a single `note:` label, so this maps `note → info` and reports `style` as `0` (gcc cannot surface it). Deterministic. |
| `file_loc` / `max_fn_lines` | pure bash/awk (no external tool) | summed physical LOC over touched `*.sh`, and the largest single-function line span (header line to its matching close brace, inclusive). Over-threshold is *informational*. |
| `dup_pct` | `jscpd` | duplication percentage (parsed from `jscpd`'s JSON report). |
| `secrets` | `gitleaks` | secret-finding count. |
| `coverage_pct` | `kcov` | line coverage % over the repo's bats suite. **Best-effort — usually skips** (kcov is rarely installed); the skip path is explicitly tested. |
| `code_scanning` | `gh api .../code-scanning/alerts` (via [`_gh/gh.sh`](../_gh/gh.sh)) | `{error, warning}` counts of **open** GitHub code-scanning alerts (CodeQL + Trivy), filtered to touched files via `most_recent_instance.location.path`. Skips if code-scanning is disabled / unauthorized. This consumes signal the repo already generates but never reads (T20260609-204303 #257). |
| `design_score` | — | from `--design-score N`, else `null`. |

## The scoreboard — `dev/quality/metrics.jsonl` (target repo)

One record per task, append-only. The directory and file are created
idempotently. Record shape:

```json
{"task":"T20260610-123456","date":"2026-06-10","files":["scripts/foo.sh"],
 "shellcheck":{"error":0,"warning":2,"info":0,"style":0},"coverage_pct":71.4,
 "max_fn_lines":48,"file_loc":260,"dup_pct":3.1,"secrets":0,
 "code_scanning":{"error":0,"warning":1},"design_score":86,
 "delta":{"file_loc":10,"shellcheck_warning":1}}
```

- **`delta`** — numeric diff (`current − prior`) of every shared numeric metric
  vs the **last record for this repo** (nested objects flatten to
  `shellcheck_warning`, `code_scanning_error`, …). Empty `{}` when there is no
  prior record. Only changed metrics appear.
- **Regression direction** — `coverage_pct` and `design_score` regress when they
  *fall*; every other metric (lint findings, dup, secrets, code-scanning, LOC,
  function size) regresses when it *rises*. A regression prints a loud
  `WARNING:` line; the merge still proceeds.

## ccxp hooks (wired)

- **`/drive` Phase 3.8** (code-class, pre-PR) — runs the probe on the task's
  touched files, appends the record (shipped in the same PR), warns on
  regression, never blocks.
- **`/retro` Phase 4d** (Friday) — reads the rolling **3-week trend** in the
  scoreboard, gives per-task hold/regress feedback, and files remediation chores
  via `/stage` on unresolved regressions; also emits the gate-readiness signal.

## Testing

`tests/quality_probe.bats` (run `bats tests/quality_probe.bats`) pins behavior
against `tests/fixtures/quality-probe/`:

- each probe parses mock tool output correctly (shellcheck gcc, jscpd JSON,
  gitleaks JSON, code-scanning alerts JSON);
- the **missing-tool → `null` + skip note + exit 0** path for shellcheck, jscpd,
  gitleaks, and kcov;
- a valid JSON line is appended to `metrics.jsonl` (idempotent dir/file
  creation; a second run appends, never clobbers);
- `delta` is computed vs a seeded baseline; a regression emits a `WARNING` and
  still exits 0;
- `--files` scoping and `--design-score` recording.

## Important notes

- **Touched-files-only.** Judge a task on what it changed. Repo legacy debt is
  out of scope here.
- **Record + warn, never block** — the one exception in the quality bar is
  `design-score` (a hard gate). This probe is observe-first by design.
- Requires `jq`. The scanners (`shellcheck`, `jscpd`, `gitleaks`, `kcov`) and
  GitHub code-scanning are all optional — absence is a recorded `null`, not an
  error.
