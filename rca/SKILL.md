---
name: rca
description: Use when you have a failed GitHub Actions run URL or run ID to diagnose, classify, and track root cause directly (not from a Slack notification — that's /labrun-rca)
disable-model-invocation: false
argument-hint: "<run-url or run-id> [workflow-name]"
---

Perform root cause analysis on a failed GitHub Actions pipeline run.

## Argument

`$ARGUMENTS` is a run URL or run ID:

- `/rca https://github.com/your-org/build-pipeline-repo/actions/runs/12345`
- `/rca 12345`
- `/rca` — auto-pick the most recent failed run on main

## Workflow

### 1. Identify the failure

```bash
# Get run details
bash ~/.claude/skills/_gh/gh.sh run view <run-id> --json name,status,conclusion,headBranch,jobs \
  --jq '{name: .name, branch: .headBranch, conclusion: .conclusion, jobs: [.jobs[] | {name: .name, conclusion: .conclusion}]}'
```

- If the run is not on `main`, note it — main failures are higher priority
- Identify which job(s) failed

### 2. Extract error evidence

For each failed job:

```bash
# Failed job/step names + a bounded error-context window in one shot
# (replaces a hand-rolled grep repeated across several past RCAs — T20260719-204917)
bash ~/.claude/skills/_gh/ci-triage.sh <run-id>
```

**Dig deeper** — don't stop at the first error. Look for:

- The actual error message (not just "exit code 1")
- Context around the error (5-10 lines before)
- Whether it's a compilation error, dependency issue, timeout, infrastructure issue, etc.

### 3. Classify the failure

| Category | Examples | Action |
|----------|----------|--------|
| **Our code** | Script bug, missing patch, wrong SHA | Create task, fix ASAP |
| **Infrastructure** | Runner OOM, disk full, network timeout | Note it, may retry |
| **Upstream** | New upstream code breaks build | Create task, investigate |
| **Transient** | Git fetch timeout, rate limit, flaky test | Retry, monitor frequency |
| **Configuration** | Missing secret, wrong env var | Fix configuration |

**Evidence required**: Every classification must cite specific log lines. Never say "probably transient" without proof.

### 4. Determine impact

- Is `main` broken? (blocks all builds)
- Is it a release blocker? (blocks specific version)
- Is it a nightly-only issue? (lower priority)
- Has it happened before? Check recent runs:

  ```bash
  bash ~/.claude/skills/_gh/gh.sh run list --workflow <workflow> --branch main --limit 5 \
    --json databaseId,conclusion --jq '.[] | "\(.databaseId) \(.conclusion)"'
  ```

### 5. Report

Output a structured report:

```
## RCA: <workflow name> run <run-id>

**Branch**: main / <branch>
**Failed job**: <job name>
**Failed step**: <step name>

### Error
<exact error message from logs>

### Root cause
<1-2 sentence explanation with evidence>

### Classification
<Our code | Infrastructure | Upstream | Transient | Configuration>

### Impact
<What's blocked>

### Action
- [ ] <specific action item>
```

### 6. Create task if needed

If classification is **Our code**, **Upstream**, or **Configuration**:

1. Generate task ID with the shared helper (no inlined generator — same one every skill uses):

   ```bash
   bash ~/.claude/skills/_taskid/new.sh --check ./dev
   ```

2. Create `dev/TODO/<id>-<slug>.md` with the RCA findings
3. **Auto-promote to current iteration's Tier 3** (red-pipeline rule, codified in T20260513-155615). Find the current committed IPM file (staging-aware — skips the future-dated pre-IPM staging stub `/stage` writes; see T20260604-194697):

   ```bash
   IPM_FILE=$(bash ~/.claude/skills/_ipm/current.sh)
   ```

   If `$IPM_FILE` is non-empty, open it, locate the `## Tier 3 — Mid-week additions` table, and add a new data row:
   - `#`: next sequential row number in that table
   - `Task`: task ID from step 2
   - `Est`: your best estimate from the RCA findings
   - `Added`: today's date (`date +%Y-%m-%d`)
   - `Why this iteration`: `RCA auto-promote — <classification> failure; recurring pipeline failures compound`

   If the `| (none yet) |` placeholder row is still present, replace it with this row; otherwise append after the last data row.

   If `$IPM_FILE` is empty, no committed IPM exists this week — note "no current IPM; Tier 3 auto-promote skipped" in the RCA report and continue (the `scheduled:` stamp in the next step still runs, defaulting the task to the next iteration).
4. **Stamp `scheduled:` on the new task file** so its iteration mapping matches the Tier-3 placement (without this the task sits in a Tier but is mapped to no board iteration — the gap T20260626-190842 fixed). The shared helper resolves the Monday token-free (committed IPM → Project API → next Monday) and writes it update-forward-only:

   ```bash
   bash ~/.claude/skills/_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md current
   ```

5. Report the task ID, the `scheduled:` date the stamper printed, and that it was auto-promoted to current Tier 3 (or, if no committed IPM, deferred to the next iteration).

If classification is **Transient**:

- Check if it's happened 3+ times in the last week
- If yes: create task (pattern indicates a real problem) — and apply the same Tier 3 auto-promote + `scheduled:` stamp (steps 3–4 above)
- If no: note it, no task needed

If classification is **Infrastructure**:

- Retry the run: `bash ~/.claude/skills/_gh/gh.sh run rerun <run-id> --failed`
- If retry also fails: create task — and apply Tier 3 auto-promote + `scheduled:` stamp (steps 3–4 above)

## Important Notes

- **Always cite log evidence.** Never guess or assume — the log is the source of truth.
- **Check if the failure is pre-existing.** Don't blame the latest commit if the same failure existed before.
- **Check recent history.** A "transient" failure that happens every day is not transient.
- **Don't skip failures.** Every main branch failure deserves investigation. Normalized failures become permanent.
