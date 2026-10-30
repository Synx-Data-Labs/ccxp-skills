---
name: rca
description: Use when you have a failed GitHub Actions run URL or run ID to diagnose, classify, and track root cause directly (not from a Slack notification — that's /labrun-rca)
argument-hint: "<run-url or run-id> [workflow-name] [--no-post]"
---

Perform root cause analysis on a failed GitHub Actions pipeline run.

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

## Argument

`$ARGUMENTS` is a run URL or run ID:

- `/rca https://github.com/your-org/build-pipeline-repo/actions/runs/12345`
- `/rca 12345`
- `/rca` — auto-pick the most recent failed run on main
- `--no-post` (any position) — skip step 5.5's Slack post. A caller that owns the Slack reply (`/labrun-rca` posts into the alert's thread) passes it so the report is not also posted to the channel root.

## Workflow

### 1. Identify the failure

```bash
# Get run details
bash <skills-root>/_gh/gh.sh run view <run-id> --json name,status,conclusion,headBranch,jobs \
  --jq '{name: .name, branch: .headBranch, conclusion: .conclusion, jobs: [.jobs[] | {name: .name, conclusion: .conclusion}]}'
```

- If the run is not on `main`, note it — main failures are higher priority
- Identify which job(s) failed

### 2. Extract error evidence

For each failed job:

```bash
# Failed job/step names + a bounded error-context window in one shot
bash <skills-root>/_gh/ci-triage.sh <run-id>
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

### 3.5 Check for an existing open task

Only when step 3 matched a KB entry, Confirmed (else step 6). Determination only — `/top` runs in step 6:

- No `task:` on the entry → step 6 as normal.
- Resolves in `dev/TODO/` → open. Note "T<id>: re-top" as the Action item.
- Doesn't resolve (closed/`dev/JOURNAL/`/migrated) → step 6 as normal; note the recurrence.

### 4. Determine impact

- Is `main` broken? (blocks all builds)
- Is it a release blocker? (blocks specific version)
- Is it a nightly-only issue? (lower priority)
- Has it happened before? Check recent runs:

  ```bash
  bash <skills-root>/_gh/gh.sh run list --workflow <workflow> --branch main --limit 5 \
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
- [ ] <specific action item — or, per 3.5, "T<id>: re-top">
```

### 5.5 Post to Slack

**Skip this whole step when `--no-post` was passed** (the caller posts the report itself, in a thread). Otherwise, immediately post the report to Slack via `slack_send_message` — don't ask "want me to post this?" first; that just adds friction and stalls the loop. The RCA is meant to feed back to the team, so posting is the default, not an opt-in. Post to `#claude-notification` (or whatever the repo's configured standup/alert channel is — see `SLACK_STANDUP_CHANNEL`) if a more specific build-alerts channel isn't reachable.

**Plain text, not a markdown table** — even though the report template in step 5 above reads naturally as a set of labeled fields, render it as bold key-value lines / bullets, not a table, when posting to Slack. Slack does not render markdown tables; a table posted there shows up as a garbled pipe-delimited mess instead of the structured report it's meant to be.

### 6. Create task if needed

Get the plan first (print-only; you still classify and judge Confirmed vs Unconfirmed):

```bash
bash <skills-root>/rca/scripts/action-plan.sh --class <our-code|upstream|configuration|transient|infrastructure> \
  --confidence <confirmed|unconfirmed> [--kb-task-open [T<id>]] [--recent <n>] [--retry-result pass|fail|pending]
```

`--recent` (transient; optional with `--kb-task-open`) = occurrences in the last 7 days; `--retry-result` is infrastructure only. One action per line, in order: `RETRY`, `TOP`, `TASK kind=fix|instrument`, `PROMOTE`, `NOTE`; the `IF_RETRY_FAILS` prefix = only after the retry failed. Exit 2 = bad inputs: fix them, never guess a plan.

If 3.5 flagged an open task: invoke `/top <id>` here instead of any task-creation gate below (Infrastructure's retry still always runs; Transient's 3+ check no longer applies).

**If classification is Unconfirmed** (step 3): always create a task, regardless of category — this is additive to that category's own action below, not a replacement for it (e.g. an Unconfirmed Infrastructure failure still gets retried first per that path; the instrumentation task is filed either way, retry outcome aside). The task's action item is adding the instrumentation/logging needed to make the next occurrence provable — not "fix the bug," since the bug isn't diagnosed yet. Apply the same mid-week auto-promote + `scheduled:` stamp as below.

If classification is **Our code**, **Upstream**, or **Configuration**:

1. Generate task ID with the shared helper (no inlined generator — same one every skill uses):

   ```bash
   bash <skills-root>/_taskid/new.sh --check ./dev
   ```

2. Create `dev/TODO/<id>-<slug>.md` with the RCA findings
3. **Auto-promote to this iteration's mid-week additions** (red-pipeline rule). Find the current committed IPM file (staging-aware — skips the future-dated pre-IPM staging stub `/stage` writes):

   ```bash
   IPM_FILE=$(bash <skills-root>/_ipm/current.sh)
   ```

   If `$IPM_FILE` is non-empty, add a row to its `## Mid-week additions` table (`Est` = your best estimate from the RCA findings; `Task` = the step 2 ID):

   Add the row with the helper (replaces the placeholder or appends, numbers it, touches only that table):

   ```bash
   bash <skills-root>/rca/scripts/midweek-add.sh --file "$IPM_FILE" --task T<id> --est <est> \
     --why "RCA auto-promote — <classification> failure; recurring pipeline failures compound"
   ```

   Exit 10 = already listed (fine); 4 = no well-formed `## Mid-week additions` table (nothing written: report it); 2/3 = usage / unreadable file. `--added` defaults to today.

   If `$IPM_FILE` is empty, no committed IPM exists this week — note "no current IPM; mid-week auto-promote skipped" in the RCA report and continue (the `scheduled:` stamp in the next step still runs, defaulting the task to the next iteration).

4. **Stamp `scheduled:` on the new task file** so its iteration mapping matches the mid-week placement (without this it's mapped to no board iteration). The shared helper resolves the Monday token-free (committed IPM → Project API → next Monday) and writes it update-forward-only:

   ```bash
   bash <skills-root>/_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md current
   ```

5. Report the task ID, the `scheduled:` date the stamper printed, and that it was auto-promoted to the mid-week additions (or, if no committed IPM, deferred to the next iteration).

If classification is **Transient**:

- Check if it's happened 3+ times in the last week
- If yes: create task (pattern indicates a real problem) — and apply the same mid-week auto-promote + `scheduled:` stamp (steps 3–4 above)
- If no: note it, no task needed

If classification is **Infrastructure**:

- Retry the run: `bash <skills-root>/_gh/gh.sh run rerun <run-id> --failed`
- If retry also fails: create task — and apply mid-week auto-promote + `scheduled:` stamp (steps 3–4 above)

### 7. Update the local knowledge base

If the classification is **Confirmed** (step 3 verified it with a concrete command, not a guess):

- No existing entry matches: append one to `dev/known-failures.md` (create it, with a short header, if it doesn't exist — repo-local, not part of this skill). Record: the grep-able signature, root cause, verify command that confirmed it, false positives ruled out, the run URL, `task:` (step 6's ID, if filed), and today as "last confirmed."
- If an existing entry's signature matched but its stated cause turned out wrong or incomplete this time (e.g. a `403`'s cause drifting across reproductions): correct that entry in place — don't add a duplicate. Bump "last confirmed" and note the correction.
- Entry existed, cause still holds: bump "last confirmed"; sync `task:` too — write it if step 6 just filed the entry's first task (e.g. Transient at 3 occurrences), update it if the old task closed and a replacement was filed, else leave it (step 6 ran `/top`).

Skip this step entirely if the classification is Unconfirmed — there's nothing confirmed yet to record.

## Important Notes

- **Evidence over guessing.** A classification is either backed by a cited log line or a verification command run just now — never a hunch. See step 3.
- **`dev/known-failures.md` is repo-local, not part of this skill.** This skill's classification/verification discipline is generic; domain-specific failure signatures (e.g. what a given CI's `403`s tend to mean) are knowledge that belongs to the repo whose pipeline produces them, built up incrementally via step 7. A repo without one yet just skips the KB-lookup in step 3.
- **Check if the failure is pre-existing.** Don't blame the latest commit if the same failure existed before.
- **Check recent history.** A "transient" failure that happens every day is not transient.
- **Don't skip failures.** Every main branch failure deserves investigation. Normalized failures become permanent.
