---
name: ccxp
description: Use when the user explicitly asks to run the full XP engineering loop / day-or-week orchestrator (daily standup, Monday IPM, focused work, Friday retro)
disable-model-invocation: false
argument-hint: "[task-id]"
---

Claude Code Extreme Programming: the master skill that orchestrates daily engineering work following XP best practices. Starts with a daily standup (review yesterday, check progress against the week's IPM commit, plan today), runs an Iteration Planning Meeting on Mondays, focused work via `/drive`, and a weekly retrospective on Fridays.

## Argument

`$ARGUMENTS` is optional:

- `/ccxp` — auto-mode: standup (+ IPM on Mondays, retro on Fridays)

## Cron mode vs. interactive mode

`CCXP_CRON_MODE` (default `0`; `dev/daily-ccxp.sh` sets it to `1` for every
cron-spawned session) draws the line between what the unattended loop does on
its own and what stays reserved for a human sitting down with the agent.
**Rituals and housekeeping run in both modes** — sync (Phase 0), the reclaim
sweep (Phase 0.5), standup (Phase 1, which now includes nightly health/RCA as
Phase 1.2 before the standup message is composed), the
Monday IPM budget-cut (Phase 2a), and the Friday retro (Phase 2b) are all
bookkeeping/process work, not product engineering, and cron does them the same
as an interactive session would.

Two things are **interactive-only — skipped whenever `CCXP_CRON_MODE=1`**:

- **The pre-IPM design pass (`/ipm` step 3).** Reviewing business priorities,
  reading each candidate task, and getting it design-ready (scope, unknowns,
  a real estimate) is a judgment call worth a human's attention, not
  something to run unattended every Monday morning. In cron mode, `/ipm`
  step 2's Tier 2 candidate pool is filtered to tasks **already at `status:
  Design` with an `estimation` set** — i.e., already taken through a pre-IPM
  pairing session at some point during the week. Tasks still at `status:
  Open` are left out of that week's Tier 2 commit; a thinner-than-usual Tier
  2 is reported explicitly (`## Notes`: "N candidates still need a pre-IPM
  pass"), never silently backfilled by skipping the design step.
- **Phase 3 (focused work).** The autonomous loop never invokes `/drive`
  in cron mode — it exits after that day's rituals (standup any day,
  +IPM on Monday, +retro on Friday). Implementation work happens only when
  a human runs `/drive` or `/ccxp` interactively (where `CCXP_CRON_MODE` is
  unset/`0` and both the design pass and Phase 3 run normally, exactly as
  this skill originally did end-to-end).

This mirrors the existing `CCXP_PEER_MODE` env-var pattern (default behavior
baked into the skill, one var flips it) rather than adding a second
skill/argument surface.

## XP Practices Mapping

| XP Practice | How ccxp applies it |
|-------------|---------------------|
| Planning game | Pre-IPM design pass (interactive-only, `/ipm` step 3, run as `/incept` per candidate) readies candidates during the week; Monday IPM (`/ipm`, cron) budget-cuts whatever's design-ready → ipm-weekly.md; **continuous pre-IPM staging** via `/stage` (candidates accrue all week under `## Candidates`, IPM folds them in) |
| Small releases | Continuous PR flow — ship small, ship often |
| Simple design | KISS principle from `dev/guidelines.md` |
| Testing | TDD — test plan before code, `bats tests/` before push |
| Refactoring | `/simplify` after implementation |
| Pair programming | Claude + human via Slack escalation; pre-IPM design passes and focused implementation (Phase 3) run interactively, human at the keyboard, not via the unattended cron |
| Continuous integration | Pipeline verification on branch + nightly RCA via `/rca`, included as a classified digest in the standup message (Phase 1.2, `*🌙 Nightly*` section) |
| Collective ownership | All code through PRs with review |
| Sustainable pace | Weekly retro grades focus list; estimation-vs-actual self-corrects budget |
| On-site customer | Slack escalations for real-time decisions; P0 escape hatch preempts WIP |

## Workflow

**`<skills-root>` placeholder, used throughout this document (T20260918-414727):**
every `<skills-root>/X/Y.sh` reference below means: take the "Base
directory for this skill" value reported when this skill loaded (e.g.
`/home/ci/ccxp-skills/ccxp`), drop the trailing `/ccxp`, and substitute
that literal absolute path — never run these cwd-relative, and never
`cd` into it. cwd must stay the **working/target repo** for the
`dev/TODO/`, `dev/JOURNAL/`, `git log`, and `$(pwd)/dev` commands used
elsewhere in this document — a `/ccxp` session's cwd is not guaranteed
to sit anywhere inside the ccxp-skills checkout (a headless cron
session's cwd is commonly the target repo instead). (The one deliberate
exception is `/ipm` step 5b's ephemeral roadmap clone, which `cd`s into its own
throwaway directory for that phase only — not a case this preamble
governs.) Before Phase 0's first command below, verify the substituted
path is real and fail loudly if not:

```bash
[ -x "<skills-root>/_gh/gh.sh" ] || { echo "ccxp: <skills-root> (<the literal path you substituted>) doesn't look like a ccxp-skills checkout — check the Base directory reported above" >&2; exit 1; }
```

### Phase 0: Sync

Pull the latest code and skills, prune stale refs, and clean up local branches whose remote is gone. This ensures the TODO backlog, guidelines, and skill definitions are current — and `git branch` doesn't accumulate stale `t<id>-…` branches from merged PRs.

```bash
bash <skills-root>/ccxp/scripts/sync-and-prune-branches.sh
```

Fast-forwards the working repo and the shared skills repo, then deletes local branches whose remote tracking ref is gone (PRs already merged + remote branch auto-deleted by `gh pr merge --delete-branch`) — inlining the `/cleanup-branches` skill workflow so the cron-driven ccxp run stays self-contained, no nested skill dispatch needed. The `--prune` in its fetch step is the prerequisite for the branch cleanup — without it, `[gone]` markers don't appear, and the cleanup is a no-op. See `ccxp/scripts/sync-and-prune-branches.sh` for the full recipe.

If the project worktree has uncommitted changes (leftover from a previous session), stash or report them before pulling. If `git pull --ff-only` fails (diverged history), report and continue — don't force-reset. **Do NOT pull sibling repos here** — that's `/drive`'s Phase 1.5 responsibility (just-in-time refresh of the target repo, gated on safety checks). ccxp Phase 0 is scoped to the working repo + the shared skills repo only.

#### Phase 0.5: Prune stale state (resolved escalations)

One cheap, idempotent prune keeps session-coordination state lean.

**1. Resolved drive-thread escalations.** `/drive` records Slack escalations in `.claude/state/drive-threads.json` (gitignored — local session state, never committed) and `/slack-check-reply` flips them to `resolved: true` once a reply lands. Resolved entries are dead weight: nothing reads them, but every `/drive` Phase 0.5 re-reads the whole file. Prune resolved entries older than 7 days (the grace window keeps recently-resolved threads scrollable):

```bash
bash <skills-root>/ccxp/scripts/prune-drive-threads.sh
```

Idempotent — a no-op on a clean file, and the `&& mv` guard leaves the original untouched if `jq` errors (e.g. a malformed file). Unresolved escalations and recently-resolved ones are always kept; the Slack channel (`#claude-notification`) remains the canonical archive of historical escalations, so this file is only `/drive`'s working index, not a long-term record.

**3. Dead task-claim reclaim sweep.** The peer-mode lock (`_session/task_claim.sh`) is **heartbeat-free by design** — a `claimed_by:` line on `main` is what lets a claim survive restarts, but a claim whose owning CC session *died* (crash / kill / reboot) is never released. The task stays `status: Coding`, `claimed_by: <dead session>`, and peer-mode `/todo next` excludes it from every *other* session, so it silently leaks out of the backlog (this is the orphaned-claim cause behind the recurring "PR stranded under a stale owner" escalations). On-demand reclaim covers the pick path; this sweep is the proactive backstop. Run it once per tick (active by default with peer mode; no-op only on the `CCXP_PEER_MODE=0` opt-out — symmetric with the lock):

```bash
bash <skills-root>/ccxp/scripts/reclaim-sweep-pr.sh
```

No-op (prints nothing, exits 0) when `CCXP_PEER_MODE=0` or when the read-only detect pass finds nothing to reclaim — nothing branched, nothing committed. Otherwise it branches off main, applies the sweep, runs the doc-lint guard, commits, pushes, opens a PR, and returns to main (never leaves the cron working tree on a branch), printing the reclaimed-lines summary and the PR URL on stdout. Then `/address-pr` the new PR (pure status-change → auto-merge tier) and MCP-Slack each reclaimed line to `#claude-notification` — a reclaimed task may have had real WIP, so a reclaim is never silent.

Detect-on-`main` → branch-only-if-work keeps the cron working tree clean. The reclaim decision reuses the unit-tested `task_claim.sh reclaimable` primitive: a claim is freed only when status is `Coding`/`Review`, `claimed_by` is session-shaped (either the current `cc1-` form or the legacy `<sid>@<machine>` form — a non-session value like a bare human name is never auto-reclaimable, T20260724-312324), there is no caller-observed in-progress GH Actions run on the claim's open PR branch, AND **both** activity signals exceed `TASK_CLAIM_STALE_DAYS` (default 2) — the last commit mentioning it on `main` (the relevant signal for a no-PR task) **and** the open PR's last activity (`updatedAt`: push/comment/review — the relevant signal for an open-PR task). Open PRs are **no longer** auto-excluded (T20260622-404636 — the old "any open PR ⇒ live" rule leaked dead-owner open-PR tasks forever; PR ownership is now *derived* from this same claim, so reclaiming the claim reclaims the PR). Self-reclaim-guarded (never frees this session's own claim) and idempotent (a clean board emits nothing, branches nothing). See `_session/reclaim_sweep.sh` + `tests/reclaim_sweep.bats`. (The prior soft-claim TTL layer this sweep supersedes — `_session/claim.sh`/`heartbeat.sh`/`prune.sh`/`release.sh` + the 4 Project fields `machine`/`clone_path`/`cc_session_id`/`last_heartbeat` — was fully retired in T20260616-308030; `prune.sh` no longer exists.)

**4. Claim-gap detection.** The opposite failure mode from #3: a task whose status is `Coding` but whose `claimed_by` was never set — the gap left by any path that flips status via `_session/status.sh` (board visualization only, no lock) without also calling `task_claim.sh acquire` (`/ccxp` Phase 2a.3, now `/ipm` step 3, was the confirmed live example — T20260610-248248, fixed above). Detector only, never mutates:

```bash
bash <skills-root>/_session/claim_gap.sh
```

**Only `Coding` is flagged — `Design`/`Review` + empty `claimed_by` is NOT a gap** (corrected T20260809-310724, 2026-08-09, after this detector re-Slacked the same 7-task list every tick for a day, half of them genuinely misclassified): an abandoned-but-real design/review is the normal resting state of an unclaimed backlog item — `/todo next`'s peer-claim filter only skips a task when `claimed_by` is *non-empty*, so nothing is actually invisible to claim-based coordination there. Verified live: 3 of a previously-flagged set of 4 `Design`-status tasks had simply never been claimed at all (`claimed_by` empty since their seed-migration commit, untouched since) — flagging those was the bug, not a symptom of one. `Coding` is different: a task mid-implementation with no claimant means someone flipped status without acquiring the lock, which IS a real coordination gap.

No-op (prints nothing) when every `Coding` task is properly claimed, **or when the flagged list is unchanged since the last call** (dedup, same T20260809-310724 fix — the script now remembers the last-posted list's hash in `.claude/state/claim-gap-last.json` and stays silent on a repeat). Otherwise, log each `unclaimed <task-id> …` line and Slack the summary to `#claude-notification` — same "never silent" principle as the reclaim sweep, since a genuinely new (or changed) gap is exactly the kind of coordination issue a peer session could step into. See `_session/claim_gap.sh` + `tests/claim_gap.bats`.

### Phase 1: Daily standup

Generate a daily progress summary by reviewing yesterday's work.

#### 1.1 Gather yesterday's data (parallel reads)

1. **Git log**: `git log --since="yesterday 00:00" --until="today 00:00" --oneline --stat`
2. **PRs merged yesterday**: `bash <skills-root>/_gh/gh.sh pr list --state merged --search "merged:>=YYYY-MM-DD merged:<YYYY-MM-DD" --json number,title,mergedAt` (use yesterday's date then today's date)
3. **PRs opened/updated**: `bash <skills-root>/_gh/gh.sh pr list --state open --json number,title,updatedAt`
4. **Journal entries**: Check `dev/JOURNAL/` for files dated yesterday
5. **Current drive-threads**: Read `.claude/state/drive-threads.json` for unresolved escalations
5b. **Check for maintainer replies — MANDATORY every tick**: run `/slack-check-reply all`. This is not optional and not skippable on the basis of any prior-tick note: a reply can land between any two ticks, and the maintainer often answers **in the daily standup thread** (one reply resolving several blockers at once), which the patched `/slack-check-reply` discovers and reads. **The MCP slack user CAN read `#claude-notification` even though it is a private channel** — use `slack_search_public_and_private` (NOT `slack_search_public`, which only sees public channels and returns nothing here) and `slack_read_thread` with the channel_id+ts. **Disregard any prior daily-summary note claiming "MCP can't see the channel" / "can't re-read replies from a fresh session" — that was a wrong conclusion from using the public-only search; overwrite it.** A reply preempts: split a batched standup reply into per-task directives, treat each as resolving that blocker, and file any new scope it raises as follow-up tasks.
6. **Previous ccxp summary**: Read the most recent `dev/JOURNAL/*-daily-summary.md` for continuity (for continuity only — never let a prior note about Slack-unreadability suppress step 5b)
7. **Current weekly focus**: Read the current committed IPM — `IPM_FILE=$(bash <skills-root>/_ipm/current.sh)` (staging-aware: skips the future-dated pre-IPM staging stub `/stage` writes — see T20260604-194697). If `$IPM_FILE` is empty, no IPM commit exists yet — note "No active IPM commit — first IPM happens this Monday" and skip the progress block in 1.2.

#### 1.1a Cheap-hold short-circuit (Option C — T20260614-261293)

On the hourly cadence (`3 * * * *`), the pre-flight gate (`dev/daily-ccxp.sh`) starts a session whenever there is a *signal* — but it sees only the signal, not whether the work is actually **doable** this tick. A tick that fires on a real `task-due`/`inflight-task`/`pr-activity` signal but where every candidate turns out **gated** (peer-owned / supervised-release / VPN-not-clearable / maintainer-owned-fork) would otherwise pay a **full Phase-1 standup + a per-tick doc PR for zero forward progress** — the dominant residual spend (~$6–14/standup; see the cost note in `dev/daily-ccxp.sh`). This short-circuit makes that tick **cheap**.

**It is a gate, evaluated here using checks 1.1 already gathered (plus two cheap peeks) — it never skips a mandatory check.** A "cheap hold" requires **all** of:

- **No new maintainer reply** — `/slack-check-reply all` (step 1.1#5b, already run — *mandatory, never skipped*) returned nothing actionable.
- **Nightly all-green** — a cheap peek (`gh run list --branch main --created ">=<last-tick>"`, conclusions only — *not* a full Phase-1.5 RCA) shows no new `failure`.
- **No drainable PR** — Phase 0 (`/address-pr`) already exited non-actionable (every open PR `owned:`/draft/blocked, nothing `mine`/`free`/`untracked` + mergeable).
- **No clean autonomous leg** — `/todo next` yields nothing workable: Tier-1 + Tier-2 all peer-owned / supervised / external-blocked. This is the **genuine-gate** determination from Phase 3 ("VPN and the Workflow tool are tools, not walls"), **not** the reflexive "all gated" bail — each candidate maps to a concrete gate.
- **Not a Monday or Friday tick** — the IPM (2a) and retro (2b) always run the full ritual; a cheap hold is weekday/weekend Tier-3 only.

**When the gate holds — cheap-hold action:**

1. Post a **compact, bulleted** hold note to `#claude-notification`, **threaded under the day's
   standup parent** (discover it live, exactly as `/slack-check-reply` does —
   `slack_search_public_and_private` for the latest `"Daily Standup"`, reply with `thread_ts`).
   Same scannability principle as the full standup's Weekly focus/Attribution/Blockers sections
   (maintainer feedback, 2026-07-19) — a dense single line is still hard to read even when it's
   short. Format:

   ```
   *hold HH:MMZ*
   • slack: 0 new
   • nightly: green
   • drainable PR: 0
   • clean leg: 0 ({1-line why each top candidate is gated, e.g. "T298901 peer, T240817 supervised"})
   ```

   Still one Slack message (`slack_send_message` with `thread_ts`) — "compact" means brief
   content, not a literal single text line. Omit a bullet only if that check genuinely didn't
   run this tick (don't pad with "N/A"); never collapse back to the `·`-joined prose form.
2. **Exit the tick** — do **not** run 1.2–1.4 (full standup regeneration), do **not** open a per-tick doc PR. The day's `dev/JOURNAL/YYYY-MM-DD-daily-summary.md` (written by the day's first full standup) is the durable record; the **standup Slack thread is the daily rollup** (each hold tick = one reply). The mandatory Slack-reply + nightly checks already ran above — nothing safety-critical is skipped.

**Why Slack-thread, not a doc append:** `main` requires a PR for any doc change, so appending a `## Hold ticks` line to the daily-summary would still cost one doc PR per tick — the very churn this removes; and the cron wrapper restores `main` between sessions (`restore-default-branch`), so a rollup can't accumulate locally across ticks. The Slack thread is already the canonical archive of session activity, so it *is* the rollup.

**This is a hold-tick optimization, not a work-skip.** If *any* gate input is non-clear — a reply landed, a nightly red, a drainable PR, or a genuinely workable task — fall through to the full standup (1.2 onward) and do the work. The first full standup of the day always runs (the daily-floor signal guarantees it), so the day always has its summary doc; cheap holds only collapse the *subsequent* all-gated ticks.

**Addendum ticks (the common in-practice middle ground) still owe 1.2.2a.** In practice, a
non-hold intra-day tick rarely re-runs the *entire* 1.2–1.4 sequence from scratch — it appends
a `## Standup addendum (HH:MMZ)` section to the day's existing `dev/JOURNAL/YYYY-MM-DD-daily-summary.md`
via its own small PR, recording just what changed this tick (new failure classified, PR merged,
etc.), rather than regenerating the whole doc. That's a reasonable, established pattern — but an
addendum that classifies a **new nightly failure** is still doing Phase 1.2's job for that
failure, so it must still run **1.2.2a** (search for the original `#slack-automation-alerts`
post, reply with the RCA) before the tick is done — recording the reply outcome in the addendum
the same way 1.2.4 does. Skipping straight from "classified in the addendum" to "done" reproduces
the exact gap 1.2.2a exists to close (confirmed live: a recurring known-flaky-check failure was
classified and journaled in an addendum, but no RCA reply ever reached the original alert
thread — caught only because a human checked the alert directly).

> **Between-iterations weekday note (T20260614-261293, Component 2 — decided "not worth it").** A separate wrapper-side weekday throttle for "between-iterations" hold-days was considered and **rejected**: the pre-flight actionability gate (`dev/daily-ccxp.sh:497`) already skips a no-signal weekday tick, and this Phase 1.0 short-circuit handles the fired-but-gated case more precisely than a blunt calendar throttle. Re-introducing a weekday throttle would re-add the calendar-gating complexity the 2026-06-27 `HOLDDAY_THROTTLE=0` decision deliberately removed.

#### 1.2: Nightly health check

*(Slot formerly "1.2 (Removed in T20260513-422869)" — zombie session-claim pruning + Project-mirror sync, retired alongside the `_claims/` coordinator; one-session-per-clone made it unnecessary. This is unrelated, newer content reusing the freed number.)*

Check whether last night's workflow runs on `main` are healthy. Run RCA on any failures, create tasks for real bugs. **Moved here (2026-07-18, from a standalone "Phase 1.5" that ran after the standup Slack post) so the result is available for the unified standup message in 1.4** — the standup message should carry the nightly RCA inline, not as a separate ping issued after the fact. A held tick (1.1a) never reaches this step, so the cost profile is unchanged: full RCA still only runs on a tick that's doing a full standup anyway.

##### 1.2.1 List nightly runs

Determine the lookback window based on today:

- **Normal day**: SINCE = yesterday's date
- Use `date -v-1d +%Y-%m-%d` (macOS) or `date -d yesterday +%Y-%m-%d` (Linux) for SINCE

List **all** runs on main in the window (not just failures — we need the total count for the health summary):

```bash
bash <skills-root>/_gh/gh.sh run list --branch main --created ">=SINCE" --limit 100 \
  --json databaseId,name,conclusion,createdAt \
  --jq '.[] | "\(.databaseId) \(.name) \(.conclusion) \(.createdAt)"'
```

The explicit `--limit 100` overrides `gh`'s default page size (20). On a busy night a recurring single-workflow failure can be the 21st-newest run and silently fall off the default page — so the recurrence (the thing the nightly RCA most needs to catch) is exactly what gets dropped. 100 comfortably covers a normal day's run volume; bump it if a real window ever overflows. **Do not remove it** — the small over-fetch is the cost of never hiding a recurrence (T20260604-173894).

Filter failures from the result. If no failures, record "Nightly runs: all green ({N} runs checked)" and proceed to 1.2a.

> **Single-workflow recurrence safety-net**: `--limit 100` makes a dropped recurrence very unlikely, but the count is still a global page across all workflows. `/rca`'s own "has it happened before?" check (Step 4) sidesteps the busy-window problem entirely by querying *per workflow* (`run list --workflow <name> --limit 5`), so once a failure is being RCA'd its recurrence history is robust regardless of this page size.

##### 1.2.2 Run RCA on each failure

For each failed run, invoke `/rca <run-id>`. The rca skill will:

- Extract error evidence from logs
- Classify the failure (Our code, Infrastructure, Upstream, Transient, Configuration)
- Create a task in `dev/TODO/` if actionable (Our code, Upstream, Configuration, or recurring Transient)
- Retry Infrastructure failures automatically

**Record one line per failure** (workflow name, run ID, classification, task ID if one was created) as you go — 1.2.4 and 1.3/1.4 (the standup doc + Slack message) all consume this list, and re-deriving it after the fact means re-reading every RCA report.

##### 1.2.2a Reply RCA in the original alert thread

`.github/workflows/slack-notify.yml` fires an immediate, unclassified alert to `#slack-automation-alerts` for a subset of release/build workflows the moment they fail on `main` (not every workflow on `main` — see 1.2.5's note). Until now, whoever's watching that channel saw only the raw "build failed" ping and a lone `:eyes:` reaction — the classification, task ID, or "this is a known issue" only ever reached the standup digest (1.2.4 → 1.4) in `#claude-notification`, a different channel. **Design rationale (T20260726-296410)**: anyone watching the alert itself should see the RCA there too, not have to cross-reference the standup. For each failure just classified in 1.2.2, check whether it has a matching alert and reply on it:

1. **Find the alert message.** `slack-notify.yml` posts via a bare webhook, whose response carries no usable `ts` — nothing stashes the alert's `channel_id`/`message_ts` for a later tick to look up directly, so this is a **search**, not a lookup (same shape as `/slack-check-reply` Step 4's fallback):

   ```
   slack_search_public_and_private: "actions/runs/<run-id>" in:#slack-automation-alerts
   ```

   Sort by `timestamp` descending, take the first match. If nothing comes back — no alert posted for this workflow, the run predates the webhook, or the channel/format changed — skip to step 4 and note the miss.

2. **Dedup.** `slack_read_thread` the matched message and check its replies. If one already starts with `*RCA —` (this automation's own marker, shared with `/labrun-rca`), don't post again — either an earlier tick or a manually-run `/labrun-rca` on the same permalink already covered it.

3. **Post the reply.** Reuse `labrun-rca`'s Step 5 format exactly (error / root cause / classification / impact / action / log link) via `slack_send_message` with `thread_ts` = the matched message's `ts`. Don't invent a second format here — this automated path and a manually-pasted permalink through `/labrun-rca` are two entry points to the same behavior, and should read identically to whoever's watching the thread.

4. **Record the outcome** next to the per-failure line from 1.2.2 (`replied in thread` / `no matching alert` / `already replied`) — 1.2.4 surfaces a miss so it stays visible rather than silently dropped.

##### 1.2.3 PR new tasks

If any new tasks were created in `dev/TODO/`:

1. Run `/gcpr nightly RCA — new tasks from failed runs`
2. This creates a PR with the new task files so they enter the backlog through the normal review flow

If no tasks were created (all failures were transient or infrastructure), skip this step.

##### 1.2.4 Carry the result forward

Hold onto this tick's nightly-health facts — **do not write them to a file yet**; 1.3 renders them as the initial `## Nightly health` section of the daily summary (the doc doesn't exist until 1.3, since this step now runs first):

- Runs checked: {N total from 1.2.1}
- Failures: {M} ({list of workflow names, or "None"})
- Tasks created: {K} ({list of task IDs, or "None"})
- Classification breakdown: {e.g., "1 our code, 1 transient", or "All green"}
- Alert-thread replies (from 1.2.2a): {P} posted, {Q} no matching alert found, {R} already replied — omit this line entirely on an all-green tick (no failures means no alerts to search for)

##### 1.2.5 (Retired — folded into 1.4)

Previously a standalone "Slack the nightly health result" step posted a second, separate message, because Phase 1.5 used to run *after* the standup Slack post (1.4) had already gone out (T20260704 finding) — there was no other way for nightly results to reach Slack same-tick. Now that this whole check runs *before* 1.4 (as 1.2), the results are already in-hand when 1.4 composes the single unified standup message (see 1.4's `*🌙 Nightly*` section) — no second post needed. This is a **distinct signal from `.github/workflows/slack-notify.yml`**, unchanged: that workflow fires an immediate, unclassified "build failed" ping at CI-failure time for a handful of release/build workflows and doesn't cover every workflow on `main` (e.g. `Upstream Sync`); expect some nights to see both a same-night raw alert from `slack-notify.yml` and this tick's classified summary in the standup — they answer different questions ("is it red right now" vs. "what actually broke and is someone tracking it").

#### 1.2a Gather PRs needing dev's attention

Not every open PR needs a human — most are either actionable (Phase 0 will drain them in due course) or simply waiting on their own CI. Flag a PR here only when it's stuck on something this loop can't resolve by itself, so the section stays a short exceptions list, not a full PR roster.

Fetch open PRs with body + mergeability (extends 1.1 step 3's PR list):

```bash
bash <skills-root>/_gh/gh.sh pr list --state open --json number,title,body,mergeable,updatedAt
```

Flag a PR as needing attention when **any** of:

- Its body has an unchecked `- [ ]` pre-merge item whose text names a human decision (grep case-insensitive for `maintainer`, `your call`, `decision`, `approve`, `escalation`) — this is exactly the shape of a real incident: weeks open on a "maintainer release-strategy call ... no reply yet" item.
- `mergeable` is `CONFLICTING`.
- CI has been `failure` for 2+ consecutive checks (not a transient one-off that's likely to clear on retry).
- Its task (resolve via `bash <skills-root>/_session/pr_task_id.sh <number>`) has an unresolved entry in `.claude/state/drive-threads.json`.

For each flagged PR, record: PR number, title, and the one-line reason it's flagged (which condition above matched). Anything not flagged is left to Phase 0's normal drain — don't list it.

#### 1.2b Compute top 5 next

Run the `/todo next` logic (same walk that skill documents: queue order top-to-bottom, skipping blocked / peer-claimed / lint-frozen candidates) to get the top 5 actionable tasks. This is the same computation `/ipm` step 2 does for the Monday IPM budget-cut — reuse it here for the daily glance; this call **reports only, commits nothing**.

**Peer mode (the default; opt out with `CCXP_PEER_MODE=0`):** ccxp runs as a
**parallel peer** alongside interactive sessions (even ones sharing GitHub
state), coordinated by the durable `claimed_by:` task-claim lock on `main`
(`_session/task_claim.sh`). In
that mode ccxp does **not** globally HOLD focused work just because an
interactive session is alive — it runs `/drive`, which claims its task before
working, so two sessions pick up *different* tickets and never race. Default-on
makes every session (cron + interactive) claim, so there is no env-var-symmetry
gap. Set `CCXP_PEER_MODE=0` to restore the old one-session-per-clone global hold.

#### 1.3 Generate daily summary

Create `dev/JOURNAL/YYYY-MM-DD-daily-summary.md`. **Four sections carry the real content (Resolved, Nightly, Attention, Top 5); everything else is supporting context** — this is the maintainer-facing rewrite from the 2026-07-18 revision (previously "Yesterday"/"Today's plan" one-liners plus a separate nightly-health Slack ping):

```markdown
# Daily Summary: YYYY-MM-DD

## Resolved
{one bullet per PR merged yesterday — a HIGHLIGHT, not just a number/title:
"<…|Tid> — {what it does or fixes, and why it mattered, in one line} (PR #N)".
Draw the highlight from the task's `## Closed` section if the task/journal entry
resolves (richer than a PR title); fall back to the PR title only when no task
resolves. "Nothing merged yesterday" if empty — never an empty section.}

## Nightly health
(From 1.2 — computed BEFORE this doc is written, not appended after.)
- Runs checked: {N total from 1.2.1}
- Failures: {M} ({list of workflow names, or "None"})
- Tasks created: {K} ({list of task IDs, or "None"})
- Classification breakdown: {e.g., "1 our code, 1 transient", or "All green"}
- Alert-thread replies: {P} posted, {Q} no matching alert found (omit this line when {M} is 0)

## PRs needing attention
(From 1.2a — an exceptions list, not a full PR roster.)

| PR | Title | Why it needs you |
|----|-------|-------------------|
| #NNNN | ... | Maintainer release-strategy call open for weeks, no reply |

"None — every open PR is actionable or already in flight" if empty.

## Top 5 next
(From 1.2b — `/todo next`'s top 5, reporting only, nothing committed.)

1. {<…|Tid> — one-line what + why it's next (queue position, unblocks, deadline)}
2. ...

## Epic progress
(From `epic-status.sh render`, T20260911-347027 — token-free, deterministic; reads
the hub repo's `dev/EPICS.md`. Paste its stdout verbatim; the script itself
prints a one-line note instead of the heading's body when `ROADMAP_TARGET_REPO`
is unset, `dev/EPICS.md` is unreadable, or no epics are defined yet — so this
section, like Resolved/Nightly/Attention/Top-5, is never simply omitted.)

{verbatim output of `bash <skills-root>/ccxp/scripts/epic-status.sh render`}

## Weekly focus progress

(Skip this block if no `*-ipm-weekly.md` exists yet — first IPM hasn't run.)

References: `dev/JOURNAL/{this-week-Monday}-ipm-weekly.md`.

| # | Task | Picked status | Today's status | Note |
|---|------|---------------|----------------|------|
| 1 | T... | Coding | Coding | PR #... awaiting CI |
| 2 | T... | Open   | Coding | Started yesterday |
| 3 | T... | Open   | Open   | Not yet started |

**Summary**: {X}/{N} shipped, {Y} in flight, {Z} not started. **Trend**: {On-track / Slipping / At-risk — based on remaining days vs remaining cumulative estimate}.

## Task attribution by location

(Generated by `_session/attribution.sh` — see 1.3a. Splits yesterday's throughput by `claimed_by` host:clone-path so autonomous-ccxp vs interactive work is measurable. **Omit the whole section on a no-data day** — the helper prints nothing.)

| Location | Class | Shipped | In-flight | Total |
|----------|-------|---------|-----------|-------|
| {host:clone-path} | {ccxp/interactive/unattributed} | {N} | {M} | {N+M} |

## Open escalations
- {list of unresolved Slack threads, if any}

## Housekeeping
- No claim housekeeping needed (one session per clone)
```

**"Today's plan" is retired** — the Top 5 next section supersedes it (item 1 *is* today's plan); keeping both would just duplicate the same ranking under two headings.

#### 1.3a Generate the task-attribution section

Render the `## Task attribution by location` section from the attribution helper
(`_session/attribution.sh`, T20260624-313487). It buckets task counts by the
`claimed_by: cc1-<machine-id>:<path-hash>` identity and labels each location
`ccxp` / `interactive` / `unattributed`, so the maintainer can see how much
shipped from the autonomous cron loop vs interactive sessions:

```bash
# Default window = yesterday (matches the standup "Yesterday" frame).
bash <skills-root>/_session/attribution.sh table "$(pwd)/dev"
```

- **Prints nothing on a no-data day** → omit the whole section (the standup
  "no empty sections" rule). Otherwise paste the emitted markdown table under the
  `## Task attribution by location` heading.
- **Completed-task attribution** recovers the last non-empty `claimed_by` from git
  history, because `task_claim.sh` clears it at close (so a JOURNAL stub's live
  frontmatter is empty). In-flight (`dev/TODO`) tasks use the current claim.
- **Classification** keys on `ATTRIBUTION_CCXP_PATHS` (colon-separated clone
  paths) — required config, no baked-in default (T20260827-280088); set it in
  `~/.claude/.env` to the cron clone the `dev/daily-ccxp.sh` working tree runs
  from (see README Prerequisites). Add another autonomous box's clone path to
  the env var to label it `ccxp` too. Unset means every location classifies
  as `interactive` — a cosmetic degrade, not a failure.

#### 1.3b Lint the standup doc before committing (catch MD032 locally)

The standup doc is committed + PR'd each tick (ad-hoc — there is no scripted commit step here), and
a list glued to a preceding line is the recurring MD032 red that sits on `main` until a fix-PR
lands. Before committing/pushing the daily-summary (and any journal docs written this tick), run the
shared doc-lint guard:

```bash
bash <skills-root>/_docs/lint-docs.sh --fix || true   # doc-lint guard — shared script (T20260719-111051), see /gcpr Step 1.5 (T20260627-192311)
```

It auto-fixes the blanks-around-lists class and folds the correction into the commit; an unfixable
residual surfaces loudly but does not block (the PR's `Markdown Lint` check is the authoritative
gate). Committing docs via `/gcpr` runs this automatically (Step 1.5) — this explicit call covers
the ad-hoc standup-commit path that bypasses `/gcpr`.

#### 1.3c Generate the epic-progress section

```bash
bash <skills-root>/ccxp/scripts/epic-status.sh render
```

Paste the output verbatim under the `## Epic progress` heading in the daily
summary (see 1.3's template). The script degrades gracefully — see its own
fail-quiet notes — so this call never blocks the standup and never needs a
try/catch here.

#### 1.4 Slack the standup

Send daily summary to `#claude-notification` via MCP `slack_send_message`.

**Webhook fallback on MCP send failure (T20260717-433409).** `slack_send_message` has shown
chronic intermittent `MCP error -32603: Internal Server Error` failures — a 7-consecutive-day
miss streak on the daily standup, 2026-07-30 through 2026-08-05 (see that task's Progress notes
for the day-by-day count). Don't let a failed send silently drop the day's standup from Slack:

1. Attempt `slack_send_message` once, then one retry on error — per T20260717-433409's own Plan
   ("don't loop retries in a single session — 2 attempts is enough evidence per occurrence"), not
   a policy documented elsewhere in this file. Looping past that second attempt is not warranted.
2. If both attempts error, capture the standup message text into a variable and fall back
   immediately to the same underlying script the `/slack` skill's `dev` channel uses (routes to
   the same `#claude-notification`):

   ```bash
   STANDUP_MESSAGE="$(cat <<'EOF'
   <the *Daily Standup* (YYYY-MM-DD) mrkdwn block composed above>
   EOF
   )"
   SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL_DEV" bash <skills-root>/slack/scripts/slack-send.sh "$STANDUP_MESSAGE"
   ```

   Requires `SLACK_WEBHOOK_URL_DEV` resolvable via the same three-tier lookup `slack/SKILL.md`'s
   Prerequisites documents for every webhook var: an already-exported env var, then
   `~/.claude/.env` (machine-global, recommended), then the working repo's own `.env`
   (see your own repo's secrets-rotation docs for how that's provisioned, e.g. 1Password-routed).
3. Record which path succeeded in that day's `dev/JOURNAL/YYYY-MM-DD-daily-summary.md`
   Housekeeping section (`Posted via MCP` vs. `Posted via webhook fallback — MCP send failed`), so
   the streak stays visible in the durable record even on a day Slack itself shows no gap.
4. **Known limitations of the webhook path** — accept, don't block on:
   - Posts under the generic webhook-configured identity, not a distinct bot name (the same
     identity gap `SLACK_WEBHOOK_URL_DEV`'s other consumers already have — see
     `T20260720-505253`).
   - The webhook response carries no message `ts`, so this session can't thread a same-tick reply
     directly onto the post it just sent. `/slack-check-reply`'s live
     `slack_search_public_and_private` discovery is unaffected — a webhook-posted message is
     searchable and repliable-to like any other once found — so next-tick reply-checking still
     works; only *this* tick's immediate self-threading is unavailable.
5. If **both** the MCP send and the webhook fallback fail, that's the actual hard-stop worth
   escalating loudly (something's wrong beyond the known MCP flakiness) — note it in Housekeeping.

**Scope note.** This fallback is wired only into this phase and `/ipm` step 6 (Weekly Focus) — the
two sends across this file and `/ipm` that fire unconditionally on their cadence (daily / weekly). The
other `slack_send_message` call sites (Phase 0.5's reclaim-sweep and claim-gap summaries in this
file, the IPM bump-2x note, `/ipm` step 5b's ROADMAP-failure escalation) are conditional — they
post only when something's already been found — so an occasional miss there is lower-stakes than
losing a guaranteed daily/weekly notification. Extending the same pattern to those sites is a reasonable
follow-up, not done here to keep this change scoped to the tracked failure.

**Render every task reference as a clickable link.** Resolve each task ID through
the sidecar helper so the maintainer can jump straight to the task file on GitHub:

```bash
source <skills-root>/_taskid/url.sh
taskid-slacklink T20260427-298901          # -> <https://github.com/…/blob/main/dev/TODO/T…-….md|T20260427-298901>
taskid-slacklink T20260427-298901 --issue  # -> link to the stable issue instead of the file
```

The helper globs `dev/{TODO,PARKING,JOURNAL}/` in the cwd repo (map-free since
T20260610-023106), so the link points at the task's *current* path even after it
moves `TODO → JOURNAL` on close; unresolvable tasks fall back to a code-search
link. Slack
uses mrkdwn — links are `<url|text>`, **not** `[text](url)` (which renders
literally). Build each link with `taskid-slacklink` and drop the `<…|Tid>` string
straight into the message; never paste a bare `T…` ID.

**Epic progress line(s).** One compact line per epic, from the same script as 1.3c's
section, in `--slack` mode:

```bash
bash <skills-root>/ccxp/scripts/epic-status.sh render --slack
```

```
*Daily Standup* (YYYY-MM-DD)

*✅ Resolved* ({N})
{one bullet per merged PR: <…|Tid> — {one-line highlight, what/why it mattered} (PR #N)}
{or "Nothing merged yesterday" if N=0 — never an empty section}

*🌙 Nightly*: {"all green ({N} runs)" if M=0, else "{M} failure(s) / {N} runs"}
{if M>0: one line per failure — <workflow> (run <id>) — <classification> — {<…|Tid> or "no task filed (transient/infra)"}}

*🔀 Needs your attention* ({K})
{one bullet per flagged PR: PR #N — {title} — {why, one line}}
{or "None — every open PR is actionable or already in flight" if K=0}

*📋 Top 5 next*
{numbered 1-5: <…|Tid> — one-line what + why it's next}

*🎯 Epic progress*
{one line per epic from `epic-status.sh render --slack`}
{omit this whole block, header included, when the script emits no lines}

*📌 Weekly focus*
• {X}/{N} shipped, {Y} in flight, {Z} not started
• Trend: {On-track / Slipping / At-risk}

*📊 Attribution*
• ccxp: {S} shipped / {F} in-flight
• interactive: {S} shipped / {F} in-flight

*🚧 Blockers*
• {one bullet per unresolved escalation}
{or "• None" if empty}
```

(Omit the whole `*📌 Weekly focus*` block on days where no `*-ipm-weekly.md`
exists yet. Omit the whole `*📊 Attribution*` block on a no-data day. Omit the
whole `*🎯 Epic progress*` block too when `epic-status.sh render --slack`
emits no lines (unset `ROADMAP_TARGET_REPO`, unreadable `EPICS.md`, or no
epics defined) — same optional-block class as Weekly focus/Attribution, not
one of the four always-render headline sections. Every
other section — Resolved, Nightly, Needs your attention, Top 5 next — always
renders, using its "None"/"Nothing"/"all green" fallback rather than being
cut; those four are the sections a reader scans for first, so a missing one
reads as broken rather than empty. **Blockers always renders** (unlike Weekly
focus/Attribution) — "None" is itself the informative answer to "is anything
stuck," so cutting the section on a clean day would read as unchecked, not
clean.)

**Message-length discipline.** The tool has a 5000-char cap per text element. On
a very busy day (many merges + many flagged PRs), trim rather than truncate
mid-sentence: cap *Resolved* highlights at one line each (drop extra detail,
keep the task link + PR #), and cap *Needs your attention* to the single
clearest reason per PR. Top 5 next is already bounded. If still tight, drop the
whole *📊 Attribution* block first (it's the least actionable of the trailing
context sections) before shortening the four headline sections.

### Phase 2a: Monday IPM (Mondays only)

**Trigger**: Only when today is Monday in the cron's reference frame — `TZ=America/Chicago date +%u` = 1. Skip on all other days.

Why `TZ=America/Chicago`: the crontab sets `CRON_TZ=America/Chicago` so the cron fires at a stable Chicago wall-clock time, but the spawned shell inherits the *server* timezone (often PDT). A plain `date +%u` from a PDT-local shell at "01:00 CDT Mon = 23:00 PDT Sun" returns `7` (Sunday) and skips Monday IPM. Pinning to Chicago time matches the cron's reference frame. See T20260518-170804 in the JOURNAL for the root-cause analysis.

Run `/ipm` to commit the week's Iteration Planning Meeting. `/ipm` reads `CCXP_CRON_MODE` from the environment itself (see `ipm/SKILL.md`), so no extra plumbing is needed here.

1. Run `/ipm` (see `ipm/SKILL.md`)
2. `/ipm` will:
   - Carry over in-flight Tier 1 WIP and seed Tier 2 candidates from `/todo next` + the week's staged candidates
   - Run the pre-IPM design pass (interactive only — skipped whenever `CCXP_CRON_MODE=1`, which is how this cron-triggered call always runs it)
   - Budget-cut into product / infrastructure-tooling / slack lines and write `dev/JOURNAL/YYYY-MM-DD-ipm-weekly.md`
   - Drain the previous iteration (hard gate — the commit isn't final until this passes) and sync the cross-repo ROADMAP doc
   - Slack the weekly focus
3. Report: "IPM committed. {N}h committed ({M} carry-over, {K} new picks). Starting focused work."

If a Monday is missed (holiday, off day), the next Monday's IPM covers the gap — there is no *automatic* mid-week catch-up via this cron trigger. `/ipm` itself can still be invoked ad hoc any day for a deliberate re-plan (see `ipm/SKILL.md`).

### Phase 2b: Friday retro (Fridays only)

**Trigger**: Only when today is Friday in the cron's reference frame — `TZ=America/Chicago date +%u` = 5. Skip on all other days. (See Phase 2a for the rationale — same `CRON_TZ` vs server-TZ mismatch applies.)

Run `/retro` before starting any focused work. This ensures the weekly retrospective happens reliably — `/drive` runs in continuous mode and doesn't return control, so retro must run first.

1. Run `/retro` to generate the weekly retrospective
2. The retro will:
   - Review the full week's work
   - **Grade the week's `ipm-weekly.md`**: shipped / in flight / partial / dropped, plus estimate-vs-actual deltas
   - Flag any task bumped 3+ IPMs in a row (process smell)
   - Create action items as new tasks in `dev/TODO/`
   - Write a retro report to `dev/JOURNAL/`
   - Slack a summary
3. Report: "Retro filed. {N} action items created. Starting focused work."
4. **Optionally propose an `EPICS.md` update** (new task IDs discovered under
   an epic this week, an epic newly done): reuse `update-roadmap.sh`'s
   `clone`/`commit-pr` machinery against the same `ROADMAP_TARGET_REPO`,
   editing `dev/EPICS.md` instead of `dev/ROADMAP.md` in the ephemeral clone.
   This is the **only** write path for `EPICS.md` — Phase 1.3/1.4's daily
   render stays strictly read-only. Skip silently when there's nothing to
   propose; never block the retro on this step.

**If a Friday session is missed**, the next Friday's retro covers the gap (it always looks at the last 7 days).

### Phase 3: Focused work (supervised loop) — interactive only, skipped when `CCXP_CRON_MODE=1`

**Skip this phase entirely in cron mode.** When `CCXP_CRON_MODE=1`, ccxp ends its run after that day's rituals (Phase 1/1.5/0.5, +2a Monday, +2b Friday) — do not invoke `/drive`. Implementation work is reserved for interactive sessions (a human running `/ccxp` or `/drive` directly, where `CCXP_CRON_MODE` is unset/`0`). Report "Rituals done for today — no focused-work loop in cron mode." and exit. The rest of this section describes the interactive behavior.

Invoke `/drive` and monitor it. `/drive` runs in continuous mode (complete task → pick next → repeat), but it can exit for several reasons. ccxp supervises and re-invokes as needed.

**Invoke:** Run `/drive` (no arguments — let it auto-pick via `/todo next`). On Fridays, retro action items are already in the backlog and will be picked up naturally.

**Pick and work the task — do NOT pre-empt `/drive` with a "supervise, nothing's actionable" triage.** `/drive`'s `/todo next` does the picking; your job is to let it run, not to hand-filter the backlog down to "no clean leg" and bail to "supervise." (Audit 2026-06-27: of 16 due-now Open tasks, 12 had an autonomous path — the "all gated" posture was wrong on ~10 of them.) Two capabilities the headless cron HAS — treat them as **tools, never as walls** that justify "supervise":

- **A company VPN is a tool, not a wall.** A task whose only blocker is a company-internal VPN-gated resource (an internal GitLab/registry, inspecting internal source, mirroring an internal image, filing an internal MR) is often still **doable** headless — connect via whatever VPN mechanism your team provides and use the appropriate credential/token over HTTPS. Do NOT reflexively classify such a task "VPN-gated → supervise."
- **The Workflow tool is the substantive-work path — ultracode is NOT required.** Phase 3.1 of `/drive` drives design→implement→test as a sequential Workflow, which runs fine headless. Do NOT defer a substantial task to "supervise" for lack of ultracode.

A task is genuinely **not** an autonomous cron leg ONLY when it: needs a real **production release build**, or a workflow whose **failure posts to a public/product Slack channel**; is **claimed by another clone** (peer-owned); is **external-blocked** (org-admin / upstream-vendor-tag the VPN can't clear); or is genuinely **multi-session-large**. Everything else — BATS / script / config / docs work, and any VPN- or Workflow-clearable task — is fair game: pick it, don't park it.

**Peer mode (default; `CCXP_PEER_MODE=0` to disable):** do **not** hold Phase 3 just because an interactive `claude` session is alive on the box. Run `/drive` normally — its peer-mode claim (`_session/task_claim.sh acquire`, the `claimed_by:` lock on `main`) guarantees it picks a task no other live session holds, so ccxp and the human work different tickets concurrently. The only tasks ccxp skips are those another session has actively claimed (or that it can't claim because the claim-PR conflicts — it re-picks). Set `CCXP_PEER_MODE=0` to restore the old one-session-per-clone global HOLD.

**Monitor and re-invoke:** When `/drive` returns control, check why:

| Exit reason | ccxp action |
|-------------|-------------|
| Task completed + no unblocked tasks remain | Report "All tasks clear." Wait. |
| Task parked + no other unblocked tasks | Report parking lot status. Wait. |
| Escalation sent (design decision, blocker) | Report escalation. Wait for reply (via `/slack-check-reply`). Re-invoke `/drive` once resolved. |
| Error or unexpected exit | Diagnose: read the last tool output, check git status. If recoverable (e.g., transient API error, merge conflict), fix and re-invoke. If not, slack the user and stop. |
| Context budget exhaustion | Report progress so far. The next cron invocation picks up where this left off. |

**Safety valve:** After 3 consecutive re-invocations without completing a task, stop and slack the user — something is stuck.

#### Diagnosing hung sessions

A long-running ccxp child at 0% CPU is **not** proof of hang. ccxp sessions often emit an intermediate "Session summary" + DONE-looking line mid-run, then go silent for 60–120 min, then do 10–20 more turns before the real final DONE. Killing on the intermediate signal wastes the user's attention and discards real work.

**Before escalating, verify with log-activity age — not just DONE markers.** `tail -F` the day's log and check whether new lines (TOOL, text, SESSION) are still landing.

| Signal | Interpretation |
|--------|----------------|
| PID alive + new log lines in last 30 min | Working. No action. |
| PID alive + silence < 3h + last line is DONE or "Stopping here" | Probably still working — wait, do not slack. |
| PID alive + silence ≥ 3h + no external event expected (no open pipeline, no slack-reply gate, no `/loop` tick) | Plausibly hung. Verify FDs/network before escalating. |
| PID alive + silence ≥ 3h + 0% CPU throughout | Slack with kill command. |
| PID dead | Wrapper handles on next cron tick. No action. |

**Expected long-silence patterns** (don't call these hung):

- Babysitting a pipeline run (5–30 min waits between status checks).
- `/loop` tick interval (silent between ticks by design).
- Waiting on a Slack reply (e.g., escalated design decision).
- Other ccxp sessions earlier today showing similar silent patches that finished cleanly.

The decision rule is **log-activity age + intermediate-vs-final DONE**, not CPU%. CPU drops to 0% any time the agent is sleeping between tool calls — that's normal idle, not a hang.

## Day-of-week behavior

This table describes the **cron-mode** (`CCXP_CRON_MODE=1`) schedule — what
`dev/daily-ccxp.sh` actually drives. An **interactive** `/ccxp` or `/drive`
invocation (`CCXP_CRON_MODE` unset/`0`) runs the pre-IPM design pass and
Phase 3 normally, any day, regardless of this table.

| Day | Phase 0 (sync) | Phase 1 (standup, incl. 1.2 nightly RCA) | Phase 2a (IPM) | Phase 2b (retro) | Phase 3 (focus) |
|-----|----------------|-------------------------------------------|----------------|------------------|-----------------|
| Mon | Pull both repos | Normal (with ipm-weekly block — references prior week's focus until `/ipm` writes the new one; checks last night's runs) | **Run `/ipm`** (budget-cut only — step 3 pre-IPM design pass skipped) | Skip | Skipped (cron mode) |
| Tue–Thu | Pull both repos | Normal (with ipm-weekly block; checks last night's runs) | Skip | Skip | Skipped (cron mode) |
| Fri | Pull both repos | Normal (with ipm-weekly block; checks last night's runs) | Skip | **Run retro** | Skipped (cron mode) |
| Sat–Sun | Pull both repos | Normal (with ipm-weekly block; checks last night's runs) | Skip | Skip | Skipped (cron mode) |

## Cron integration

The `dev/daily-ccxp.sh` script is the cron wrapper for this skill. It:

- Stops any previous session
- Sources `.env` for secrets
- Runs `claude --dangerously-skip-permissions -p /ccxp` with `CCXP_CRON_MODE=1`
  in the environment — restricting the session to standup, nightly
  health/reclaim housekeeping, the Monday IPM budget-cut, and the Friday
  retro (see "Cron mode vs. interactive mode" above). The pre-IPM design
  pass and Phase 3 focused work are reserved for interactive pairing
  sessions and never run under this wrapper.
- Logs to `.claude-ccxp-logs/`

Crontab entry — **hourly**, pinned to Chicago wall-clock so the Monday-IPM / Friday-retro day-of-week triggers fire in the cron's reference frame (see Phase 2a):

```bash
CRON_TZ=America/Chicago
3 * * * * /path/to/repo/dev/daily-ccxp.sh
```

The hourly cadence is governed by the wrapper, not by the schedule: a fresh `/ccxp` session starts only when the token-free **pre-flight actionability gate** finds a signal (daily-floor / PR-activity / CI-failure / due-or-in-flight task), and a fired-but-all-gated tick is made cheap by the **Phase 1.0 cheap-hold short-circuit** (above). `HOLDDAY_THROTTLE=1` re-enables a weekend cadence throttle if weekend spend ever spikes again (disabled by default since 2026-06-27 — the root cause was an over-conservative Phase-3 triage, now fixed). See `dev/daily-ccxp.sh`.

## Notes

- **Standup generation is fast; the message is not terse.** "Brief" describes Phase 1's *execution time* (under a couple minutes — no new analysis, just composing from data already gathered in 1.1/1.2), not the Slack message's content. The 2026-07-18 revision (Resolved highlights, Nightly RCA, PRs needing attention, Top 5 next) is richer *because* it's assembled from data the phase already collects, not because the phase runs longer.
- **Cron does rituals, not engineering.** In cron mode the loop's job is standup + nightly health/reclaim housekeeping + the Monday IPM budget-cut + the Friday retro — never the pre-IPM design pass and never Phase 3. Focused implementation work happens in interactive pairing sessions, where a human's judgment on business priority and design readiness is available.
- **Retro is honest.** See the `/retro` skill notes — the retro exists to improve the process, not to report status.
- **Read guidelines first.** Always read `dev/guidelines.md` before making changes — this rule cascades from `/drive`.
- **Escalation protocol.** Inherited from `/drive` — all Slack escalations go to `#claude-notification` via MCP `slack_send_message`.
