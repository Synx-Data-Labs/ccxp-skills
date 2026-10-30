---
name: address-pr
description: Use when the user explicitly asks to address, verify, or merge a specific open PR (CI, Claude Code review, test plan, tiered merge)
argument-hint: "[PR number or URL]"
---

Address a PR's review comments, verify CI and affected pipelines, then merge or notify.

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

## Argument

`<arg>` is optional:

- `/address-pr 188` — address a specific PR
- `/address-pr https://github.com/<owner>/<repo>/pull/188` — by URL
- `/address-pr` — auto-pick the next open PR (oldest first, authored by us)

## Workflow

### 1. Find PR, authorship gate (§1.3) and ownership (§1.6)

One read-only script decides all three; it writes nothing:

```bash
GATE=$(bash <skills-root>/address-pr/scripts/entry-gate.sh <number|url|->); RC=$?
```

`<number|url|->`: a PR number, a `…/pull/<n>` URL, or `-` to auto-pick (our own open PRs only; oldest-first, skipping `owned:<other>`/`unknown`, so one permanently-owned PR cannot block the rest). `$GATE` is one JSON line `{number, task_id, author, verdict, head_ref}`. `$RC` is the gate; **anything not in this table, or an empty `$GATE`, is a stop** (fail closed):

- `0` (`mine`, `untracked`): proceed to §1.5
- `10` (`free`): claim the task first (§1.6 `free`), then proceed
- `11` (`new`): claim on the PR's own branch (§1.6 `new`), then proceed
- `20` (`foreign`): **hard stop, no write action of any kind** (below)
- `21` (`owned:<agent>`): defer: another session owns the task; do not run the loop or merge
- `22` (`unknown`): defer: ownership unresolvable (fail-safe, never a silent merge)
- `1`: `-` found no pickable PR: report "No open PRs to address" (the script's stderr names skipped PRs) and exit
- `2`: usage, fix the argument

**`20` foreign PR** (authored by someone else or a bot like `app/*`, or author/login unreadable): the explicit number/URL path is not filtered by `--author @me`, so `address-pr 877` would otherwise review, edit and **merge a teammate's PR**. No merge, push, review comment, body/label edit or task-claim write.

- **Autonomous context** (`/ccxp` cron, auto-pick, `/drive` dispatch): `echo "PR #<number> authored by <author> (not us) — skipping, not touching."` and **exit**. Never pick a foreign PR again this run.
- **Explicit human invocation**: STOP and ask the user what they want — a read-only review/summary is fine if they confirm, but **never merge or mutate a foreign PR**, even on request (tell them to merge it themselves or have the author do it). Treat "help with" as advisory-only.

§1.3 is about **whose PR it is**; §1.6 about **which CC session is driving our shared PRs**; the script checks them in that order and both must pass. The §1.5 Project writes below run only after the gate.

### 1.5. Status=Review + PR ref (best-effort)

`/address-pr` may be invoked independently of `/drive` (e.g., reviewing an already-open PR). To make the Project board show the PR is in human-reviewable state, do two things up front:

1. **Correlate the PR back to its task**: the gate's `task_id` (from `_session/pr_task_id.sh`: branch name → PR body `Task:` link → commit-message scan).
2. **Set Project Status = Review** so the board flips out of `In Progress` for the duration of the PR loop.
3. **Append the PR ref to the task's Project item title** (`set-pr-ref.sh`) so the board shows the task→PR mapping at a glance. Idempotent — a no-op if `/gcpr` already stamped it, or on re-entry.

```bash
TASK_ID=$(jq -r .task_id <<<"$GATE")
if [ -n "$TASK_ID" ]; then
  # 1) Status=Review
  bash <skills-root>/_session/status.sh "$TASK_ID" Review
  # 2) Append the PR ref to the item title (board task->PR mapping)
  PR_URL=$(bash <skills-root>/_gh/gh.sh pr view <number> --json url --jq .url 2>/dev/null)
  [ -n "$PR_URL" ] && bash <skills-root>/_session/set-pr-ref.sh "$TASK_ID" "$PR_URL"
fi
```

Both calls are best-effort: failures log to stderr and don't block the workflow. If `task_id` is empty (untracked branch, no body Task: link, no T-id in commits), skip the Project writes — the file-driven mirror workflow will reconcile state on the next push.

**Clone-locality note (informational only):** once `TASK_ID` is resolved you *may* run the guard for visibility:

```bash
[ -n "$TASK_ID" ] && bash <skills-root>/_taskid/in-this-repo.sh "$TASK_ID" || true
```

- Unlike `/drive`, here a non-zero result is **expected and fine**: cross-repo `/address-pr` runs in the *target* clone (e.g. hub=hub-repo, target=ccxp-skills) where the task file is *not* present by design. So this is **warn-only/informational** in `/address-pr` — never refuse, and ignore `DRIVE_STRICT_CLONE` here.
- Its only purpose is to surface the rare case where you expected a same-repo PR but are standing in the wrong clone.
- `/address-pr` reads ownership (§1.6) and, on a `free` verdict, claims the task itself (see §1.6's `free` handling) — this note is about the *clone-locality* guard specifically, which stays informational-only here; the guard's harder, refusing teeth are in `/drive` and `/stage`.

`/address-pr` owns the `Review` transition (not `/drive` Phase 3) because `/drive` hands off to address-pr the moment the PR opens, and the entire multi-iteration PR loop (CI fixes, review back-and-forth, force-pushes, merge gate) belongs in the Review stage. Owning it here means re-invoking `/address-pr` from another session correctly re-asserts `Review` on every entry.

### 1.6. PR ownership — DERIVED from the task claim (authoritative anti-steal)

- The §1.5 Project-board writes (Status mirror + PR ref) are **soft visualization** (task-keyed, best-effort) — they are NOT a lock.
- Two CC sessions (e.g. an interactive session and the `/ccxp` cron) can otherwise drive the same PR concurrently because the PR lives on GitHub, reachable from every clone, and "one-session-per-clone" only protects working trees.
- That is how a PR got merged by the cron while a human was still (silently) waiting on a labrun.

(The §1.3 authorship gate must already have passed — §1.6 applies only to PRs that are ours.)

- **PR ownership is NOT tracked separately on the PR.** There is no `cc-owned` label or marker comment.
- A PR is owned by whoever owns the **task it implements** — that task's `claimed_by: cc1-<machine-id>:<path-hash>` on `main`, which is durable, GitHub-persisted, and atomically arbitrated by the merge (the same (machine, clone) agent identity, and the release-on-pickup "≤1 task at a time", that `task_claim.sh` already enforces).
- The old per-PR marker stranded green PRs under dead sessions (#1361/#1326/#1386/#1524) and leaned on a verified-dead liveness probe that isn't feasible on stable signals.
- Deriving ownership from the task makes that whole failure class vanish: a dead agent's claim self-clears when its clone next picks up work (release-on-pickup), or via the reclaim sweep for a foreign dead clone.

The gate (§1) already resolved the owner via `_session/task_claim.sh pr-owner <number>`; its verdicts mean:

- **`mine`** — this clone holds the task claim (the normal `/drive` path: it claimed the task before opening the PR). Proceed.
- **`free`** — the task exists **on `main`** but is unclaimed. **Claim it before doing anything else** — see below. Don't just "proceed"; a PR can sit open against an unclaimed task for weeks, during which the Project board reads `Open`/unclaimed even while a PR against it exists, and a peer session could pick the same task for duplicate work.
- **`new`** — the task file does **not exist on `main` yet**: this very PR introduces it (the `/stage` pattern — `queue.md` + the new task file committed together) and it's unclaimed. Distinct from `free` because the claim mechanics differ — see its own procedure below.
- **`untracked`** — the PR maps to no task (`fix/*` branch, no `Task:` link). No cross-session task to coordinate on; proceed.
- **`owned:<agent>`** — a *different* (machine, clone) agent holds the task. Defer; do not drive or merge.
- **`unknown`** — the task file couldn't be resolved (network / not found). Fail-safe: defer, never a silent merge.
  - A stale branch-name-vs-body-Task:-link mismatch can also surface as `unknown` on a rescoped PR; that is a tooling bug to fix separately, not license to bypass the fail-safe. If you have manually confirmed the real current task from the PR body and claimed *that* task, you may proceed — but say so explicitly and file or link the tooling bug if not already tracked.

**`free` → claim now, same mechanism as `/drive` Phase 1's Claim PR** (this is the one case where `/address-pr` *does* acquire, not just read):

1. `$TASK_ID` is already resolved from §1.5. On a fresh `t<id>-claim` branch off `main`: `bash <skills-root>/_session/task_claim.sh release-others <id>` (free any stale claim this clone holds), then `bash <skills-root>/_session/task_claim.sh acquire <id>`, plus the status-preserve step below.
2. Commit (pure frontmatter change — status + `claimed_by`), push, `gh pr create`, and drive *that* claim PR through this same `/address-pr` loop to merge (it's docs-only, auto-merge-eligible under the status-change tier).
3. **Conflict on the `claimed_by:` line = you lost the race** — another session claimed the task in the same window. `git checkout main && git pull && git remote prune origin`, re-run `task_claim.sh pr-owner <number>`; it should now read `owned:<other>` — defer per that case.
4. Once the claim PR merges, `git checkout main && git pull && git remote prune origin`, then continue to §2 on the *original* PR you were addressing.

**Status-preserve (both `free` and `new`).** `task_claim.sh acquire` hard-sets `status: In Progress` (`_session/task_claim.sh:569`), so a task already at `Design` (e.g. just recorded by `/incept`) would be silently demoted in the claim commit. Capture the status first, restore it after:

```bash
PRE=$(bash <skills-root>/_session/task_claim.sh read <id> | cut -f1)   # before acquire
bash <skills-root>/_session/task_claim.sh acquire <id>
if [ -n "$PRE" ] && [ "$PRE" != "Open" ] && [ "$PRE" != "In Progress" ]; then
  PRE="$PRE" bash -c '. <skills-root>/_session/task_claim.sh; _tc_fm_set "$(_tc_find_file <id>)" status "$PRE"'
  bash <skills-root>/_session/status.sh <id> "$PRE"   # board mirror, best-effort
fi
```

- The frontmatter edit is what matters: it merges to `main` in the claim commit. `status.sh` only mirrors the Project board and never touches the file, so it is not enough alone.
- This is the stronger form of `/ipm` step 3.4's `acquire` then `status.sh <id> Design` (`ipm/SKILL.md`) — same intent, plus the frontmatter write.
- `Open` and `In Progress` need no correction (`acquire`'s result is already right).

**`new` → claim directly on the PR's own branch** — unlike `free`, there is **no separate claim-branch/merge round-trip**, because `free`'s procedure above can't work here: `task_claim.sh acquire`'s file lookup (`_tc_find_file`) is a **local filesystem glob**, and a fresh branch cut off `main` does not have a file that exists only on this PR's own (not-yet-merged) branch. Instead:

1. `git fetch && git checkout <the PR's headRefName>` — the **existing** PR branch, not a new one, so the just-added task file is present in the local working tree.
2. `bash <skills-root>/_session/task_claim.sh release-others <id>` then `bash <skills-root>/_session/task_claim.sh acquire <id>` — now succeeds, since the file is right there on this checked-out branch.
3. Commit (pure frontmatter change) and push — lands as one more commit on the **same** PR; no separate claim PR.
4. **Push rejected (non-fast-forward) = you lost the race** — mirrors `free`'s step 3 above: another session saw `new` on this same PR and pushed its own claim commit first. Do **not** force-push. `git fetch && git checkout <branch>` again (picks up their commit) and re-run `task_claim.sh pr-owner <number>` — it re-resolves via the same head-ref path against the *new* head SHA, reads their now-stamped `claimed_by`, and reports `owned:<other>`. Defer per that case.
5. Otherwise, continue driving this PR through the rest of this loop (§2 onward) as normal — one PR, one push, done.

**No heartbeat / release for the `mine`/`owned` cases.** Ownership is already established when the task was claimed; `/address-pr` only *reads* it there. There is no TTL marker to heartbeat, and nothing to release at merge — the task claim is released at task close (`/drive` Phase 7 / the journal-move PR, via `task_claim.sh release`).

- **Cross-repo ownership resolution.** For a cross-repo task (hub repo holds the task file + claim, e.g. `hub-repo`; target repo holds the PR, e.g. `ccxp-skills`/`example-website.com`), the claim is written from the **hub** clone (`/drive` Phase 1) but `/address-pr`'s cross-repo mode runs from the ephemeral **target** clone (Phase 1.5: `/tmp/<task-id>-<slug>-target`) — a different path on the same host.
- `_tc_claimant_id`'s exact identity match can never call that "mine" on its own, which without this recognition made every cross-repo PR fall through to `owned:<hub-clone>` (from the target clone) or `untracked`/wrong-PR (from the hub clone, since `gh pr view <n>` resolves against `$PWD`'s origin).

`_tc_pr_owner` closes this gap with `_tc_is_own_cross_repo_clone`, a pure check consulted only when `_tc_decide` itself said `other`:

- **Host must match** — a genuinely foreign host is never "mine", cross-repo or not.
- **The current clone's path must be *this task's* ephemeral target directory** — `basename` matches `<task-id>-*-target`, the exact naming convention Phase 1.5 creates for *this* task. A same-host clone working a *different* task (even one that also looks like an ephemeral target clone), or any path that isn't that naming convention, still falls through to `owned:`/defer.

- Net effect: a session driving its own cross-repo PR from the target clone now reads `mine` (proceed), while every foreign-host, foreign-task, or non-ephemeral same-host case is unchanged — the anti-steal guarantee above holds exactly as before.
- This does **not** address the secondary hub-clone-side symptom (`gh pr view <n>` resolving the wrong repo's PR # when invoked from the hub clone) — cross-repo `/address-pr` is already documented (§1.5 cwd-discipline note) to always run from `$TARGET`, so that path isn't exercised here.

### 2. Loop until hard gate passes

- **cwd discipline (cross-repo mode)**: If `/address-pr` is invoked on a PR that lives in a different repo than the maintainer's hub clone (typical for cross-repo /drive dispatches: hub=hub-repo, target=ccxp-skills / example-website.com / build-pipeline-repo), `cd` into the target repo's clone before any `git` / `gh pr` invocation, and verify `pwd` literally matches that path.
- `pre-merge-check.sh` reads files from cwd; the wrong cwd means the wrong file gets validated. Same gotcha class as `/drive` Phase 3 and `/gcpr` Step 4 — see those for the full discussion.

**Each iteration:**

#### a. Hard gate (FIRST step, every iteration)

(No ownership heartbeat — PR ownership is the durable task claim on `main`, §1.6, not a TTL marker to keep alive.)

- **Pre-gate verification (before the pre-merge check):** `pre-merge-check.sh` is a green-light script — it checks CI, review-comment resolution, and test-plan boxes, but does not challenge unstated assumptions. Before relying on its verdict, **invoke `superpowers:verification-before-completion`** on the current PR state.
- Gaps it catches that the script can't: test-plan items mechanically checked but never exercised; a pipeline that "passed" by skipping the failing job; commit/PR-body claims that drift from the actual diff; workflow-file changes that need *post*-merge dispatch, not pre-merge.

This fires **every iteration** of the §2 loop, not just the first — each push reset re-introduces stale-assumption risk. If verification surfaces a gap, fix it (commit + push triggers a fresh iteration) and re-run §2.a from the top. For docs-only PRs (same change-kind heuristic as `/drive` Phase 3.0), verification scope is lighter (links, frontmatter, render) but still gated.

**Doc-consistency check (alongside verification):** run the doc-freshness helper so a behaviour / structure / setup change doesn't merge with stale docs (especially `README`-like docs):

```bash
bash <skills-root>/_docs/doc-impact.sh "origin/${base_ref:-main}"   # base_ref = the PR's base branch
```

- If it flags docs the PR didn't touch, the change isn't done: push a commit updating them (a fresh §2 iteration), or — interactively — record an explicit "reviewed, no change needed".
- **Unattended (ccxp loop):** do not block the merge — proceed, but file a follow-up doc-conformance task (`bash <skills-root>/_taskid/new.sh --check ./dev`) for the unaddressed flags so drift is tracked, not lost.
- It's a **follow-up**, so stamp its `scheduled:` into the **next** iteration after writing the file: `bash <skills-root>/_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md next` (token-free; update-forward-only). Docs-only PRs are exempt (the change *is* the docs). Same change-kind heuristic as the verification step above.

- Then run the pre-merge check script. It is the single source of truth for CI, test plan, and pipeline verification.
- (Repos without the script — e.g. ccxp-skills — fall back to the manual gate: CI, mergeability, test-plan boxes.) **Note on review-comment enforcement**: pre-merge-check.sh's own "review comments" check (where it exists) was written against Copilot's native `reviewThreads` — it does not see the plain PR comments step d now posts, so it will report "0 unresolved" trivially regardless of what step d found.
- The actual enforcement of Claude Code review findings is step d's own in-loop discipline (fix or justify before continuing), not a persisted, externally-checkable state.
- A session that skips step d entirely is not caught by the hard gate the way an unresolved Copilot thread used to be — this is a known reduction in cross-session backstop coverage, not an oversight.
- Consumer repos wanting that backstop back need to teach their own `pre-merge-check.sh` to look for the `**Claude Code review:**` marker instead of `reviewThreads`.

```bash
bash <skills-root>/address-pr/scripts/pre-merge-check.sh <number>
```

For a `support` task also run `bash <skills-root>/_support/gate-pr.sh <number>` (same-commit regression test; no-op for other PRs; see [`_support/README.md`](../_support/README.md)); a non-zero exit blocks the merge like `❌ BLOCKED`.

- If it outputs `✅ ALL CHECKS PASSED`: also check mergeability (`bash <skills-root>/_gh/gh.sh pr view <number> --json mergeable`). If MERGEABLE → **exit the loop**. If CONFLICTING → rebase in step b.
- If it outputs `❌ BLOCKED`: **read the failures and fix them in steps b-e below, then loop back to step a.**
- **NEVER skip the hard gate. NEVER declare ready without it passing.**

#### b. Rebase if needed

Check mergeability (the default branch may have advanced since last iteration):

```bash
bash <skills-root>/_gh/gh.sh pr view <number> --json mergeable --jq '.mergeable'
```

- If `UNKNOWN`: retry after 10 seconds
- If `CONFLICTING`: checkout, rebase on main, force-push. If conflicts can't be auto-resolved, stop and report.
- If `MERGEABLE`: continue

#### c. Fix CI failures

```bash
bash <skills-root>/_gh/gh.sh pr checks <number>
```

- If any check is `fail`: read the failure logs, fix the code, commit, push.
- If checks are `pending`: wait 60 seconds and re-check.
- If all checks `pass` (or no checks for docs-only PRs): continue.

#### d. Address Claude Code review

- No external bot.
- The reviewer is a **fresh, independent Claude agent** dispatched via the `Agent` tool — it has no memory of why this change was made, which is the property that made Copilot's review useful in the first place (a second pair of eyes, not the same author grading their own work).
- This also drops the org-tier dependency (Copilot Enterprise / Code Review add-on) entirely — every repo gets the same review mechanism regardless of GitHub plan.

- State lives on the PR itself, not in local files — re-invoking `/address-pr` from a different clone or session must re-derive the same state, not restart blind (same durability rule as §1.5/§1.6).
- Keyed to the **head SHA the review actually covered**, not a timestamp — a push landing between the diff fetch and the comment post would date-order *after* the comment despite never having been reviewed.

```bash
bash <skills-root>/address-pr/scripts/review-state.sh <NUMBER>   # -> "reviewed <head-sha>" | "needs-review <head-sha>"
```

It reads our own latest `**Claude Code review:**` comment, takes the `(sha: …)` from its header line, and compares it with the PR's current head (exit 3 = gh failed: stop, never read as `reviewed`). Keep the printed sha as `HEAD_SHA`.

- `reviewed <sha>`: this exact commit is already reviewed — skip to the approval gate below (LGTM check), then step e.
- `needs-review <sha>`: dispatch a fresh review (steps 1-3 below).

1. **Diff the PR**, scoped to the actual changed files:

   ```bash
   bash <skills-root>/_gh/gh.sh pr diff <NUMBER>
   ```

2. **Dispatch an independent review agent** via the `Agent` tool (`subagent_type: code-improvement-scanner`, or `general-purpose` if the diff is a workflow/config change outside that agent's usual scope). Give it the diff (or point it at the branch/files — its own choice how to read them) and an explicit review brief: find real bugs, correctness issues, security issues, and quality problems; if the diff is correct and complete, say so plainly (a clean bill) rather than manufacturing nitpicks. **Do not tell it what the implementation was trying to achieve beyond the PR's own title/description** — that context gap is what makes the review independent.
3. **Post the agent's report as a PR comment** from a file: write the report to `$REVIEW_REPORT_FILE` (never splice the agent's freeform text into a shell argument — it routinely contains `$`, backticks or code snippets), then:

   ```bash
   bash <skills-root>/address-pr/scripts/post-review.sh <NUMBER> "$HEAD_SHA" "$REVIEW_REPORT_FILE"   # add --dry-run to preview
   ```

   It posts `**Claude Code review:** (sha: <HEAD_SHA>)` plus the report, so the audit trail lives on the PR. Nothing is posted on a non-zero exit: `2` empty/unreadable report, `3` stale (the head moved since `HEAD_SHA`; re-run `review-state.sh` and review the new head), `4` gh failure.

- If the report is a clean bill (no real findings): review is complete — set `CLEAN_BILL=1`, dispatch the approval gate below, then continue to step e.
- If the report describes real issues: **before responding**, invoke `superpowers:receiving-code-review`. It enforces: steelman the finding before deciding to push back; distinguish "wrong because I have context the reviewer lacked" from "wrong because I want to be done"; and when pushing back (not making a code change), post a follow-up PR comment with the specific design constraint or test that makes the finding incorrect — not "stylistic preference". Then address each per the skill's output: fix code (commit + push — the head SHA changes, so `review-state.sh` reports `needs-review` and a fresh review re-triggers next iteration), or post the pushback comment and move on. **Never silently drop a finding without a comment explaining why.** This targets the same "argue with the reviewer to feel productive" anti-pattern the Copilot-era wording warned about — the skill is still the brake, just aimed at a different reviewer.

- **Dispatch the approval gate (only after a clean bill, only when the repo has one).** A repo with a `synx-merge-bot` App-auth `pr-approve.yml` workflow (`.github/workflows/pr-approve.yml` on its default branch — check once per run, not once per repo forever, since a repo can gain this later) uses that workflow to submit a real GitHub `APPROVE` review, pinned to the exact commit this step's review just covered — this is what makes `required_approving_review_count: 1` on such a repo satisfiable by automation without weakening what the review means (see `pr-approve.yml`'s own design comment: it is deliberately mechanical and never decides *whether* to approve — that judgment is entirely this step, right here).
- Repos without the workflow skip this block entirely; nothing else in `/address-pr` depends on it.

**LGTM supplement.** The PR author's `LGTM` comment is a second trigger for this same dispatch — it is *not* an approval itself (the bot's real `APPROVE` review is what satisfies `required_approving_review_count`, and branch protection still decides merge). It supplements the independent review, never replaces it:

- A review of `HEAD_SHA` must exist and **no finding may be unanswered** (each fixed, or pushed back with a comment; set `FINDINGS_OPEN=1` while any is, which blocks the LGTM path); the LGTM never skips the review or silences an open finding.
- `bash <skills-root>/address-pr/scripts/has-lgtm.sh <NUMBER> [--after <time of our latest pushback comment>]` decides: exit 0 prints the author. It counts only the PR author's own, non-bot comment after the latest push whose first line is a bare `LGTM` (not `LGTM but`, `not LGTM`, quoted, or a `**Claude Code review:**` comment); any later author comment other than a clean LGTM (hold, wait, a second thought) revokes. Contract and tests: `tests/address_pr_has_lgtm.bats`.
- Only the author's LGTM triggers (other maintainers' do not); no ack comment is posted. Exit 1 or 2 means no LGTM — behave exactly as before.
- No `pr-approve.yml` in the repo: nothing is triggered; notify/wait as usual, and note "LGTM seen, no approval workflow" in the §3 report.

```bash
LGTM_BY="$(bash <skills-root>/address-pr/scripts/has-lgtm.sh <NUMBER> ${PUSHBACK_AT:+--after "$PUSHBACK_AT"} 2>/dev/null || true)"
if [ "${CLEAN_BILL:-0}" = 1 ]; then TRIGGER=(--clean-bill)                 # review of HEAD_SHA was a clean bill
elif [ -n "$LGTM_BY" ]; then TRIGGER=(--lgtm-by "$LGTM_BY"); [ "${FINDINGS_OPEN:-0}" = 1 ] && TRIGGER+=(--findings-open)
else TRIGGER=(); fi                                                          # no trigger: skip the gate
[ "${#TRIGGER[@]}" -gt 0 ] && bash <skills-root>/address-pr/scripts/approve-dispatch.sh <NUMBER> "$HEAD_SHA" "${TRIGGER[@]}"   # add --dry-run to preview
```

`approve-dispatch.sh <NUMBER> <HEAD_SHA> (--clean-bill | --lgtm-by <login> [--findings-open]) [--dry-run]` encodes the dispatch: it runs `gh workflow run pr-approve.yml -f pr_number=… -f commit_sha=<HEAD_SHA>`, then polls the PR's own reviews (not the workflow run) for a genuine `APPROVED` review pinned to that exact commit.

The poll is bounded (`APPROVE_POLL_TRIES` x `APPROVE_POLL_INTERVAL`, default 12 x 10s) so a slow or failed dispatch never hangs the loop. One line on stdout, and the exit is the verdict; an exit not listed here, or empty output, is a stop:

- `0` `approved via workflow|fallback <sha>`: a real approval landed
- `10` `no-workflow`: no `pr-approve.yml` (the check cannot tell "absent" from a transient/auth failure: deliberately fail-safe, worst case a repo that should auto-approve is skipped and the merge stalls, never an approval that should not exist); nothing dispatched. Note "LGTM seen, no approval workflow" in the §3 report when it was an LGTM
- `11` `timeout`: dispatched but no approval landed and the fallback was unavailable or failed: warn and continue; the §2.a mergeability check is the backstop
- `13` `dry-run`: only with `--dry-run`; nothing was changed, never an approval
- `12` `not-eligible`: `--lgtm-by` with `--findings-open` (an LGTM never silences an open finding); nothing dispatched
- `2` usage: no trigger flag, both flags, or a bad sha (fail closed)

The fallback (local-mint `_gh/gh-app-token.sh` + the same pinned `APPROVE`) runs only when `GH_APP_ID` and a private key are already in the environment; the token is never printed. Contract and tests: `tests/address_pr_approve_merge.bats`.

- Standard route: the dispatched `pr-approve.yml` (App secrets stay in GitHub). Local minting via `_gh/gh-app-token.sh` is a fallback only; no bypass list is ever used.
- Trust model: anyone who can dispatch workflows on the repo can obtain a bot approval for any PR and SHA; the approval means something only because this step dispatches after a clean independent review.
- Auto-merge is armed in §3.3 (`gh pr merge --auto`), only after the hard gate and step e pass, so GitHub cannot merge ahead of the test plan; it then fires once branch protection's required approval and checks pass. Where `--auto` is refused (no protection on the repo), §3.3 merges as before.

#### e. Verify test plan

- **Auto-record every out-of-band gate as a pre-merge item FIRST (Layer B — the single source of truth).** The moment you kick off any verification that is NOT a required GitHub check on the PR — a labrun, a `--ref <branch>` pipeline dispatch, an external/manual check — immediately write it into the PR body's `### Pre-merge` section as an unchecked item carrying the run URL, BEFORE you start waiting on it:

```bash
bash <skills-root>/_gh/gh.sh pr edit <number> --body "$(...append '- [ ] labrun green — <run-url>'...)"
```

- Tick the box only once that run is green.
- This is what makes the gate **cross-session**: `pre-merge-check.sh` §3 (and the ccxp-skills manual fallback) already block merge on any unchecked pre-merge item, so the instant the gate is on the PR, *every* session — including the `/ccxp` cron — is blocked until it's satisfied.
- A PR merged out from under a human precisely because its labrun gate lived only in session-private context and never on the PR. If it's a gate, it goes on the PR.

Then check the PR body for unchecked pre-merge items (`- [ ]`):

1. For each unchecked item:
   - **If it requires a pipeline run**: trigger it on the branch using `--ref <branch>`.
   - If verifiable: run the verification, check the box via `gh pr edit`
   - If not verifiable (manual/external): stop and report to the user — the hard gate will block until it's resolved.
2. **CRITICAL: Never declare a pre-merge item as "needs merge first"** unless the workflow literally doesn't exist on main yet.

**Post-merge items**: Do NOT verify before merge. List them in the report.

- **Never declare a PR ready with unchecked test-plan items.** Every verifiable `- [ ]` must actually be checked off (not just left for the maintainer to trust) before reporting the PR ready to merge — an item that "needs a workflow run" means trigger it and wait, not skip it.
- If an item genuinely can't be verified pre-merge, say so explicitly in the report rather than silently treating unchecked as checked.

**PR titles need a descriptive slug, not just the bare task ID.** `fix(rc-confirm-promote): stop gh workflow run's stdout leaking into run_id (T20260727-252437)` — never a title that's only `T20260727-252437`. A bare ID gives a reviewer no context without looking up the task file; this applies to claim PRs and journal-move PRs too, not just the main implementation PR.

#### f. Safety valve

- After **5 full iterations**, stop and ask the user.
- If a fix introduces new failures, stop and report.

### 3. Notify and report

When the hard gate passes (pre-merge-check.sh outputs ALL CHECKS PASSED):

1. Send Slack notification. `slack-text.sh` renders the text (it sends nothing); pass the number of test-plan items needing manual verification, if any, then hand the line to `/slack`:

   ```bash
   bash <skills-root>/address-pr/scripts/slack-text.sh <number> <url> [--unverified <N>]
   ```

   Verified: `PR #<number> is ready to merge — CI green, Claude Code review addressed, test plan verified. <url>`; with `--unverified N`: `… Claude Code review addressed. N test plan items need manual verification. <url>`.

2. Report to the user:
   - PR number and URL
   - CI status (all checks)
   - Number of review iterations completed
   - Number of comments addressed
   - Test plan status (all checked / N items need manual verification)
   - Current branch

3. **Follow the merge policy in `dev/guidelines.md`** — tiered merge, pipeline verification on branch, main must always be green. Use `bash <skills-root>/_gh/gh.sh pr merge --auto --rebase --delete-branch` when a bot approval landed in step d (falling back to plain `pr merge --rebase --delete-branch` if `--auto` is refused); `--auto` returns before the merge happens, so run `bash <skills-root>/address-pr/scripts/wait-merged.sh <number>` (read-only poll, `WAIT_MERGED_TRIES` x `WAIT_MERGED_INTERVAL`, default 30 x 10s) and continue to step 4 and any branch cleanup only on exit `0` (`merged`); `11` still open, `12` closed unmerged, `4` state unreadable: stop and report, never assume merged. Or plain `pr merge --rebase --delete-branch` for the auto-merge tier, or notify for wait-for-approval tier.

4. **Status=Done** (after merge succeeds):

   ```bash
   if [ -n "$TASK_ID" ]; then
     bash <skills-root>/_session/status.sh "$TASK_ID" Done
   fi
   ```

   Set Project Status=Done (intentional double-coverage with `/drive` Phase 7 — catches the merge-via-UI path where /drive never sees the close). Best-effort and idempotent; a no-op if `/drive` already wrote it.

   - **No PR-ownership release step.** Ownership is the task claim, not a per-PR marker — there is nothing to remove from the PR. The task claim is released at task close: `/drive` Phase 7 (the journal-move PR runs `task_claim.sh release <task-id> <final-status>`).
   - On an early exit (safety valve §2.f, deferring in §1.6, or handing back to the user) there is likewise nothing to release — you never wrote PR-side ownership, so you can't strand it.

## Important Notes

- **Concurrency safety.** Follow `dev/guidelines.md` — read-only operations may run in parallel, but side-effecting operations (checkout, stash, edit, commit, push) must run sequentially. Finish all mutations for one branch before switching to another.
- **Every push resets the loop** — including `--amend` + `--force-with-lease`. After ANY push, wait for both CI and a fresh Claude Code review before declaring clean. Never skip re-review after a force-push. Step d only dispatches a fresh review when the newest review comment predates the latest push, which keeps the loop idempotent without re-reviewing an unchanged diff.
- **Never sneak changes into an approved PR.** If you push new commits or amend after the PR was approved, the approval is stale. Do NOT merge — the new changes need fresh review. Create a new PR if the scope changed, or request re-review. This applies even if the new changes don't touch manifests or docs.
- **One PR = one scope.** Don't pile unrelated fixes onto an existing PR branch. If you discover something to fix while working on a PR, create a separate branch/PR for it.
- Between iterations, wait 60 seconds for CI to run
- When fixing code, run tests locally (`bats tests/`) before pushing to avoid ping-pong failures
- Use the same commit message conventions as `/gcpr` (conventional commits, Co-Authored-By trailer)
- If a review finding is debatable (style preference, not a bug), reply with justification in a PR comment — don't change code unnecessarily
- Always read the full review report before fixing — some findings are wrong or don't apply; the reviewing agent has no memory of why the change was made, so it can misjudge intent
