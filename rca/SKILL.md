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
bash ../_gh/gh.sh run view <run-id> --json name,status,conclusion,headBranch,jobs \
  --jq '{name: .name, branch: .headBranch, conclusion: .conclusion, jobs: [.jobs[] | {name: .name, conclusion: .conclusion}]}'
```

- If the run is not on `main`, note it — main failures are higher priority
- Identify which job(s) failed

### 2. Extract error evidence

For each failed job:

```bash
# Failed job/step names + a bounded error-context window in one shot
# (replaces a hand-rolled grep repeated across several past RCAs — T20260719-204917)
bash ../_gh/ci-triage.sh <run-id>
```

**Dig deeper** — don't stop at the first error. Look for:

- The actual error message (not just "exit code 1")
- Context around the error (5-10 lines before)
- Whether it's a compilation error, dependency issue, timeout, infrastructure issue, etc.

### 3. Classify the failure

**Check the local KB first.** If `dev/known-failures.md` exists at the current repo's root, grep it for a match on the error signature from step 2. A match gives you a candidate root cause and a verify command — but **re-run that verify command now**. A KB hit is a lead, not an answer: the same signature can have a different cause than last time it was seen (a `403` that used to mean a credential scope gap can just as easily mean a storage quota — that drift, discovered only on the 7th reproduction, is why this file exists).

| Category | Examples | Action |
|----------|----------|--------|
| **Our code** | Script bug, missing patch, wrong SHA | Create task, fix ASAP |
| **Infrastructure** | Runner OOM, disk full, network timeout | Note it, may retry |
| **Upstream** | New upstream code breaks build | Create task, investigate |
| **Transient** | Git fetch timeout, rate limit, flaky test | Retry, monitor frequency |
| **Configuration** | Missing secret, wrong env var | Fix configuration |

**Evidence required — no guessing.** Every classification must be backed by one of:

- Direct log evidence (cite the specific line), or
- A concrete verification command run just now that confirms or denies the hypothesis — from a KB entry's verify command, or an ad hoc check (query a quota/rate-limit API, re-run with a different credential to isolate scope, check the provider's status page, check whether the failure correlates with a deploy/rotation window, etc.)

If neither is available — you have a hypothesis ("probably a network glitch") but no way to prove it from what's on hand — do **not** report it as classified. Mark it **Unconfirmed** (see report template, step 5) and, in step 6, file a task whose action item is adding the logging/instrumentation that would make the *next* occurrence provable instead of guessed. Never write "probably X" into a report as if it were a finding.

### 4. Determine impact

- Is `main` broken? (blocks all builds)
- Is it a release blocker? (blocks specific version)
- Is it a nightly-only issue? (lower priority)
- Has it happened before? Check recent runs:

  ```bash
  bash ../_gh/gh.sh run list --workflow <workflow> --branch main --limit 5 \
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
<Our code | Infrastructure | Upstream | Transient | Configuration> — <Confirmed | Unconfirmed>

### Verification
<one of: the command you ran just now and what it showed; "Confirmed via cited log line — see Root cause, no command needed"; or, if Unconfirmed, "No verification path available; instrumentation task filed (see Action)">

### Impact
<What's blocked>

### Action
- [ ] <specific action item>
```

### 6. Create task if needed

**If classification is Unconfirmed** (step 3): always create a task, regardless of category — this is additive to that category's own action below, not a replacement for it (e.g. an Unconfirmed Infrastructure failure still gets retried first per that path; the instrumentation task is filed either way, retry outcome aside). The task's action item is adding the instrumentation/logging needed to make the next occurrence provable — not "fix the bug," since the bug isn't diagnosed yet. Apply the same Tier 3 auto-promote + `scheduled:` stamp as the paths below.

If classification is **Our code**, **Upstream**, or **Configuration**:

1. Generate task ID with the shared helper (no inlined generator — same one every skill uses):

   ```bash
   bash ../_taskid/new.sh --check ./dev
   ```

2. Create `dev/TODO/<id>-<slug>.md` with the RCA findings
3. **Auto-promote to current iteration's Tier 3** (red-pipeline rule, codified in T20260513-155615). Find the current committed IPM file (staging-aware — skips the future-dated pre-IPM staging stub `/stage` writes; see T20260604-194697):

   ```bash
   IPM_FILE=$(bash ../_ipm/current.sh)
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
   bash ../_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md current
   ```

5. Report the task ID, the `scheduled:` date the stamper printed, and that it was auto-promoted to current Tier 3 (or, if no committed IPM, deferred to the next iteration).

If classification is **Transient**:

- Check if it's happened 3+ times in the last week
- If yes: create task (pattern indicates a real problem) — and apply the same Tier 3 auto-promote + `scheduled:` stamp (steps 3–4 above)
- If no: note it, no task needed

If classification is **Infrastructure**:

- Retry the run: `bash ../_gh/gh.sh run rerun <run-id> --failed`
- If retry also fails: create task — and apply Tier 3 auto-promote + `scheduled:` stamp (steps 3–4 above)

### 7. Update the local knowledge base

If the classification is **Confirmed** (step 3 verified it with a concrete command, not a guess):

- If no existing `dev/known-failures.md` entry matches this signature: append one (create the file with a short header if it doesn't exist yet — it's a repo-local file, not part of this skill). Record: the grep-able error signature, the root cause, the exact verify command that confirmed it just now, any false-positive alternatives ruled out along the way, the source (this run's URL or the task ID), and today's date as "last confirmed."
- If an existing entry's signature matched but its stated cause turned out wrong or incomplete this time (the way a `403` can drift from "credential scope gap" to "storage quota" across repeated reproductions): correct that entry in place — don't add a duplicate. Bump "last confirmed" and note the correction.

Skip this step entirely if the classification is Unconfirmed — there's nothing confirmed yet to record.

## Important Notes

- **Evidence over guessing.** A classification is either backed by a cited log line or a verification command run just now — never a hunch. See step 3.
- **`dev/known-failures.md` is repo-local, not part of this skill.** This skill's classification/verification discipline is generic; domain-specific failure signatures (e.g. what a given CI's `403`s tend to mean) are knowledge that belongs to the repo whose pipeline produces them, built up incrementally via step 7. A repo without one yet just skips the KB-lookup in step 3.
- **Check if the failure is pre-existing.** Don't blame the latest commit if the same failure existed before.
- **Check recent history.** A "transient" failure that happens every day is not transient.
- **Don't skip failures.** Every main branch failure deserves investigation. Normalized failures become permanent.
