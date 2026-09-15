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

- **The pre-IPM design pass (Phase 2a.3).** Reviewing business priorities,
  reading each candidate task, and getting it design-ready (scope, unknowns,
  a real estimate) is a judgment call worth a human's attention, not
  something to run unattended every Monday morning. In cron mode, Phase
  2a.2's Tier 2 candidate pool is filtered to tasks **already at `status:
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
| Planning game | Pre-IPM design pass (interactive-only, Phase 2a.3, run as `/grill-me` per candidate) readies candidates during the week; Monday IPM (Phase 2a, cron) budget-cuts whatever's design-ready → ipm-weekly.md; **continuous pre-IPM staging** via `/stage` (candidates accrue all week under `## Candidates`, IPM folds them in) |
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

### Phase 0: Sync

Pull the latest code and skills, prune stale refs, and clean up local branches whose remote is gone. This ensures the TODO backlog, guidelines, and skill definitions are current — and `git branch` doesn't accumulate stale `t<id>-…` branches from merged PRs.

```bash
bash ../ccxp/scripts/sync-and-prune-branches.sh
```

Fast-forwards the working repo and the shared skills repo, then deletes local branches whose remote tracking ref is gone (PRs already merged + remote branch auto-deleted by `gh pr merge --delete-branch`) — inlining the `/cleanup-branches` skill workflow so the cron-driven ccxp run stays self-contained, no nested skill dispatch needed. The `--prune` in its fetch step is the prerequisite for the branch cleanup — without it, `[gone]` markers don't appear, and the cleanup is a no-op. See `ccxp/scripts/sync-and-prune-branches.sh` for the full recipe.

If the project worktree has uncommitted changes (leftover from a previous session), stash or report them before pulling. If `git pull --ff-only` fails (diverged history), report and continue — don't force-reset. **Do NOT pull sibling repos here** — that's `/drive`'s Phase 1.5 responsibility (just-in-time refresh of the target repo, gated on safety checks). ccxp Phase 0 is scoped to the working repo + the shared skills repo only.

#### Phase 0.5: Prune stale state (resolved escalations)

One cheap, idempotent prune keeps session-coordination state lean.

**1. Resolved drive-thread escalations.** `/drive` records Slack escalations in `.claude/state/drive-threads.json` (gitignored — local session state, never committed) and `/slack-check-reply` flips them to `resolved: true` once a reply lands. Resolved entries are dead weight: nothing reads them, but every `/drive` Phase 0.5 re-reads the whole file. Prune resolved entries older than 7 days (the grace window keeps recently-resolved threads scrollable):

```bash
bash ../ccxp/scripts/prune-drive-threads.sh
```

Idempotent — a no-op on a clean file, and the `&& mv` guard leaves the original untouched if `jq` errors (e.g. a malformed file). Unresolved escalations and recently-resolved ones are always kept; the Slack channel (`#claude-notification`) remains the canonical archive of historical escalations, so this file is only `/drive`'s working index, not a long-term record.

**3. Dead task-claim reclaim sweep.** The peer-mode lock (`_session/task_claim.sh`) is **heartbeat-free by design** — a `claimed_by:` line on `main` is what lets a claim survive restarts, but a claim whose owning CC session *died* (crash / kill / reboot) is never released. The task stays `status: Coding`, `claimed_by: <dead session>`, and peer-mode `/todo next` excludes it from every *other* session, so it silently leaks out of the backlog (this is the orphaned-claim cause behind the recurring "PR stranded under a stale owner" escalations). On-demand reclaim covers the pick path; this sweep is the proactive backstop. Run it once per tick (active by default with peer mode; no-op only on the `CCXP_PEER_MODE=0` opt-out — symmetric with the lock):

```bash
bash ../ccxp/scripts/reclaim-sweep-pr.sh
```

No-op (prints nothing, exits 0) when `CCXP_PEER_MODE=0` or when the read-only detect pass finds nothing to reclaim — nothing branched, nothing committed. Otherwise it branches off main, applies the sweep, runs the doc-lint guard, commits, pushes, opens a PR, and returns to main (never leaves the cron working tree on a branch), printing the reclaimed-lines summary and the PR URL on stdout. Then `/address-pr` the new PR (pure status-change → auto-merge tier) and MCP-Slack each reclaimed line to `#claude-notification` — a reclaimed task may have had real WIP, so a reclaim is never silent.

Detect-on-`main` → branch-only-if-work keeps the cron working tree clean. The reclaim decision reuses the unit-tested `task_claim.sh reclaimable` primitive: a claim is freed only when status is `Coding`/`Review`, `claimed_by` is session-shaped (either the current `cc1-` form or the legacy `<sid>@<machine>` form — a non-session value like a bare human name is never auto-reclaimable, T20260724-312324), there is no caller-observed in-progress GH Actions run on the claim's open PR branch, AND **both** activity signals exceed `TASK_CLAIM_STALE_DAYS` (default 2) — the last commit mentioning it on `main` (the relevant signal for a no-PR task) **and** the open PR's last activity (`updatedAt`: push/comment/review — the relevant signal for an open-PR task). Open PRs are **no longer** auto-excluded (T20260622-404636 — the old "any open PR ⇒ live" rule leaked dead-owner open-PR tasks forever; PR ownership is now *derived* from this same claim, so reclaiming the claim reclaims the PR). Self-reclaim-guarded (never frees this session's own claim) and idempotent (a clean board emits nothing, branches nothing). See `_session/reclaim_sweep.sh` + `tests/reclaim_sweep.bats`. (The prior soft-claim TTL layer this sweep supersedes — `_session/claim.sh`/`heartbeat.sh`/`prune.sh`/`release.sh` + the 4 Project fields `machine`/`clone_path`/`cc_session_id`/`last_heartbeat` — was fully retired in T20260616-308030; `prune.sh` no longer exists.)

**4. Claim-gap detection.** The opposite failure mode from #3: a task whose status is `Coding` but whose `claimed_by` was never set — the gap left by any path that flips status via `_session/status.sh` (board visualization only, no lock) without also calling `task_claim.sh acquire` (`/ccxp` Phase 2a.3 was the confirmed live example — T20260610-248248, fixed above). Detector only, never mutates:

```bash
bash ../_session/claim_gap.sh
```

**Only `Coding` is flagged — `Design`/`Review` + empty `claimed_by` is NOT a gap** (corrected T20260809-310724, 2026-08-09, after this detector re-Slacked the same 7-task list every tick for a day, half of them genuinely misclassified): an abandoned-but-real design/review is the normal resting state of an unclaimed backlog item — `/todo next`'s peer-claim filter only skips a task when `claimed_by` is *non-empty*, so nothing is actually invisible to claim-based coordination there. Verified live: 3 of a previously-flagged set of 4 `Design`-status tasks had simply never been claimed at all (`claimed_by` empty since their seed-migration commit, untouched since) — flagging those was the bug, not a symptom of one. `Coding` is different: a task mid-implementation with no claimant means someone flipped status without acquiring the lock, which IS a real coordination gap.

No-op (prints nothing) when every `Coding` task is properly claimed, **or when the flagged list is unchanged since the last call** (dedup, same T20260809-310724 fix — the script now remembers the last-posted list's hash in `.claude/state/claim-gap-last.json` and stays silent on a repeat). Otherwise, log each `unclaimed <task-id> …` line and Slack the summary to `#claude-notification` — same "never silent" principle as the reclaim sweep, since a genuinely new (or changed) gap is exactly the kind of coordination issue a peer session could step into. See `_session/claim_gap.sh` + `tests/claim_gap.bats`.

### Phase 1: Daily standup

Generate a daily progress summary by reviewing yesterday's work.

#### 1.1 Gather yesterday's data (parallel reads)

1. **Git log**: `git log --since="yesterday 00:00" --until="today 00:00" --oneline --stat`
2. **PRs merged yesterday**: `bash ../_gh/gh.sh pr list --state merged --search "merged:>=YYYY-MM-DD merged:<YYYY-MM-DD" --json number,title,mergedAt` (use yesterday's date then today's date)
3. **PRs opened/updated**: `bash ../_gh/gh.sh pr list --state open --json number,title,updatedAt`
4. **Journal entries**: Check `dev/JOURNAL/` for files dated yesterday
5. **Current drive-threads**: Read `.claude/state/drive-threads.json` for unresolved escalations
5b. **Check for maintainer replies — MANDATORY every tick**: run `/slack-check-reply all`. This is not optional and not skippable on the basis of any prior-tick note: a reply can land between any two ticks, and the maintainer often answers **in the daily standup thread** (one reply resolving several blockers at once), which the patched `/slack-check-reply` discovers and reads. **The MCP slack user CAN read `#claude-notification` even though it is a private channel** — use `slack_search_public_and_private` (NOT `slack_search_public`, which only sees public channels and returns nothing here) and `slack_read_thread` with the channel_id+ts. **Disregard any prior daily-summary note claiming "MCP can't see the channel" / "can't re-read replies from a fresh session" — that was a wrong conclusion from using the public-only search; overwrite it.** A reply preempts: split a batched standup reply into per-task directives, treat each as resolving that blocker, and file any new scope it raises as follow-up tasks.
6. **Previous ccxp summary**: Read the most recent `dev/JOURNAL/*-daily-summary.md` for continuity (for continuity only — never let a prior note about Slack-unreadability suppress step 5b)
7. **Current weekly focus**: Read the current committed IPM — `IPM_FILE=$(bash ../_ipm/current.sh)` (staging-aware: skips the future-dated pre-IPM staging stub `/stage` writes — see T20260604-194697). If `$IPM_FILE` is empty, no IPM commit exists yet — note "No active IPM commit — first IPM happens this Monday" and skip the progress block in 1.2.

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
bash ../_gh/gh.sh run list --branch main --created ">=SINCE" --limit 100 \
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
bash ../_gh/gh.sh pr list --state open --json number,title,body,mergeable,updatedAt
```

Flag a PR as needing attention when **any** of:

- Its body has an unchecked `- [ ]` pre-merge item whose text names a human decision (grep case-insensitive for `maintainer`, `your call`, `decision`, `approve`, `escalation`) — this is exactly the shape of a real incident: weeks open on a "maintainer release-strategy call ... no reply yet" item.
- `mergeable` is `CONFLICTING`.
- CI has been `failure` for 2+ consecutive checks (not a transient one-off that's likely to clear on retry).
- Its task (resolve via `bash ../_session/pr_task_id.sh <number>`) has an unresolved entry in `.claude/state/drive-threads.json`.

For each flagged PR, record: PR number, title, and the one-line reason it's flagged (which condition above matched). Anything not flagged is left to Phase 0's normal drain — don't list it.

#### 1.2b Compute top 5 next

Run the `/todo next` logic (same walk that skill documents: queue order top-to-bottom, skipping blocked / peer-claimed / lint-frozen candidates) to get the top 5 actionable tasks. This is the same computation Phase 2a.2 does for the Monday IPM budget-cut — reuse it here for the daily glance; this call **reports only, commits nothing**.

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

{verbatim output of `bash ../ccxp/scripts/epic-status.sh render`}

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
bash ../_session/attribution.sh table "$(pwd)/dev"
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
bash ../_docs/lint-docs.sh --fix || true   # doc-lint guard — shared script (T20260719-111051), see /gcpr Step 1.5 (T20260627-192311)
```

It auto-fixes the blanks-around-lists class and folds the correction into the commit; an unfixable
residual surfaces loudly but does not block (the PR's `Markdown Lint` check is the authoritative
gate). Committing docs via `/gcpr` runs this automatically (Step 1.5) — this explicit call covers
the ad-hoc standup-commit path that bypasses `/gcpr`.

#### 1.3c Generate the epic-progress section

```bash
bash ../ccxp/scripts/epic-status.sh render
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
   SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL_DEV" bash ../slack/scripts/slack-send.sh "$STANDUP_MESSAGE"
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

**Scope note.** This fallback is wired only into this phase and Phase 2a.6 (Weekly Focus) — the
two sends in this file that fire unconditionally on their cadence (daily / weekly). The file's
other `slack_send_message` call sites (Phase 0.5's reclaim-sweep and claim-gap summaries, the IPM
bump-2x note, the Phase 2a.5b ROADMAP-failure escalation) are conditional — they post only when
something's already been found — so an occasional miss there is lower-stakes than losing a
guaranteed daily/weekly notification. Extending the same pattern to those sites is a reasonable
follow-up, not done here to keep this change scoped to the tracked failure.

**Render every task reference as a clickable link.** Resolve each task ID through
the sidecar helper so the maintainer can jump straight to the task file on GitHub:

```bash
source ../_taskid/url.sh
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
bash ../ccxp/scripts/epic-status.sh render --slack
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

The Iteration Planning Meeting commits the week's focused work. Tier 1 (in-flight) WIP from last week carries over automatically; Tier 2 (not-started) picks are designed-and-estimated before the cut. Output is a single `ipm-weekly.md` file that the daily standup grades against and the Friday retro grades final on.

If a Monday is missed (holiday, off day), the next Monday's IPM covers the gap — there is no mid-week IPM rerun.

#### 2a.0 Capture this IPM's Scheduled date

Snapshot the IPM's Monday date as the `Scheduled` value to stamp on every picked task:

```bash
SCHEDULED=$(date -d 'monday' +%Y-%m-%d 2>/dev/null || date -v-Mon +%Y-%m-%d)
echo "This IPM is Scheduled = ${SCHEDULED}"
```

Every Tier 1 / Tier 2 / Tier 3 task added (or re-committed) to this IPM gets `scheduled: ${SCHEDULED}` written into its task-file YAML frontmatter (handled in Phase 2a.5). The IPM file header (prose document, not a task file) also records `**Scheduled**: ${SCHEDULED}`.

**Source of truth for iteration**: the GH Project (your-org/projects/1) defines iterations with explicit start/end dates. The Scheduled date on each task file maps to whichever iteration contains it. Mapping is done by a separate mirror workflow — the per-repo `.github/scripts/sync-tasks-to-issues.py` (push-triggered `sync`, plus `reconcile`/`backfill` dispatch modes) reads `scheduled` and sets the matching Iteration on add, move, **and in-place edit** (in-place was a no-op until T20260526-277041, which is why an IPM carry-over — a `scheduled:` rewrite on a file that stays in `dev/TODO/` — silently never reached the board). The skill never computes an iteration integer client-side — `ls | wc -l` would silently desync if a Monday IPM is ever skipped or backfilled.

For mid-week Tier 3 additions, the Scheduled date is the current iteration's Monday (i.e. this week's IPM commit).

#### 2a.0.1 Sweep stale tasks before scoping

ccxp runs unattended via cron (see "Cron integration" below — `claude --dangerously-skip-permissions -p /ccxp`). Per maintainer guidance: autonomous-only restrictions on `/todo sweep` are no longer needed — git history is the audit trail; the sweep operation runs with the maintainer's standing permission for autonomous-mode invocations:

1. **Inline the stale-blocker auto-fix** (`/todo sweep` Phase 1 — autonomous; no approval needed because all it does is strike resolved blockers in the Status field and link to the JOURNAL entry that closed them):

   ```bash
   for f in dev/TODO/*.md; do
     # If the file's Status mentions "Blocked by T{id}" and T{id} is no longer
     # in dev/TODO/ (moved to JOURNAL or PARKING), strike that blocker line and
     # update Status accordingly. Implementation lives in /todo's sweep
     # workflow Phase 1; copy that recipe here verbatim.
     # (Idempotent — running daily is a no-op when no stale blockers exist.)
     :  # placeholder; the actual recipe is the awk/sed loop from /todo sweep
   done
   ```

   (The actual recipe is the same logic /todo sweep documents in its "Phase 1: Fix stale blockers" section. Don't duplicate that prose; reference it as the source of truth.)

2. **Run the full prune step** (`/todo sweep` Phase 2 — park / close / consolidate). Same scoring as `/todo sweep` documents — find tasks that look superseded / indefinitely-blocked / consolidatable / `Revisit`-status legacy, then move them to `dev/PARKING/` (park), `dev/JOURNAL/` with a "Closed by sweep" stub (close), or merge related rows into a single consolidated TODO (consolidate). Git history captures every move; if a sweep was over-eager, revert is one `git revert` away.

3. **Skip cleanly if zero candidates.** Don't add a `## Housekeeping` block if there's nothing to surface; daily summaries shouldn't carry empty sections.

Append the sweep summary (counts of struck-blockers, parked, closed, consolidated) to the standup `## Housekeeping` section so the maintainer sees what changed each day.

#### 2a.1 Carry over WIP (Tier 1)

Read all `dev/TODO/*.md` files. Tasks with Status `Coding` or `Review` are **automatic carry-overs** — they are already in flight and the WIP discipline keeps them in this week's commit until they ship. List them and sum their (revised, if previously estimated) Estimations.

**Claimed tasks carry too, regardless of Status.** A task with a non-empty `claimed_by:` is in-flight by virtue of the claim (a live session — this box or a peer `@…` — committed to it), even when its Status is still `Design` or `Open`. Include every claimed task in the carry-over set here, not just `Coding`/`Review`. Otherwise a `Design`+claimed task is invisible to *both* this step *and* 2a.1.5 (it was never in a `## Considered but cut` table), its `scheduled:` never advances, and it silently strands on a stale iteration on the board — the recurring leak that left T20260611-324774 and T20260610-028036 pinned to Iteration 10. **A claim pins ownership of the work, not the iteration it's tracked in:** the IPM still has full discretion to *defer* a claimed task to a later iteration instead of carrying it (set its `scheduled:` to a future Monday in 2a.5). What it must never do is leave a claimed task's `scheduled:` untouched and let the board drift from the IPM's intent.

**Bump-2x reassessment — force a decision before the third commit.** A Tier-1 carry-over carried forward unconditionally becomes a "we'll get to it" comfort blanket: it absorbs IPM accountability week after week without shipping. `/retro`'s bump-3x detector catches this, but only *retrospectively* — after the third wasted week. Catch it here, up front, one step earlier. **Detection (same file-date join key `/retro` uses — no Project-side iteration mapping):** read the **last 2 committed** `*-ipm-weekly.md` files (`PREV_IPM=$(bash ../_ipm/current.sh)` gives the newest committed IPM; the one before it is the next-older `dev/JOURNAL/*-ipm-weekly.md` by date), and for each task in *this* week's Tier-1 carry-over set check whether it appears in the **Tier-1 table of both** prior IPMs. If it does, committing it now would be its **3rd consecutive** Tier-1 commit → flag it **"Bumped 2x — reassess"**. For each flagged task, force an explicit disposition — never a silent re-carry:

- **Re-commit** — keep it in Tier 1, but record a one-line "still the right call" reason in the IPM `## Notes` (e.g. "blocker cleared this week, finishing now").
- **Won't fix** — close it (journal-move stub), exactly as a task was after its third bump in a real observed case.
- **Defer** — move it out of this iteration: advance its `scheduled:` to a future Monday and pre-append it to that Monday's stub, identical to the 2a.5 "Cut candidates — advance, never clear" mechanics.

**Unattended (the cron default): auto-defer + a Slack note.** Do not silently re-commit, and do not hard-block the IPM waiting on a human (a blocking wait would stall the whole unattended commit). Auto-defer the flagged task per the bullet above and post one line to `#claude-notification`: `*IPM bump-2x*: T<id> deferred — carried 3 IPMs without shipping; reassess (re-commit / Won't fix / defer) by reply.` This keeps the IPM moving while taking the zombie off auto-pilot. `/retro`'s bump-3x detection is unchanged — it remains the safety net for anything that still slips through.

#### 2a.1.5 Seed carry-over candidates (from last IPM's cuts)

Cuts must not vanish. Read the previous IPM file — `PREV_IPM=$(bash ../_ipm/current.sh)`. This resolves to last week's IPM because 2a.1.5 runs **before** 2a.5: this week's file still exists only as the pre-IPM staging stub, which the helper excludes (header-sniff), so the newest *committed* IPM is last week's (see T20260604-194697 — a naive `ls -t … | head -1` instead grabbed the future-dated staging stub). Collect the task IDs from its **`## Considered but cut`** table. Drop any whose task file is no longer in `dev/TODO/` (closed/parked since) and any already captured as Tier 1 in 2a.1 (dedupe — in-flight auto-carry wins).

The survivors are **carry-over candidates**: tasks a prior IPM deliberately deferred. They enter this IPM's Tier 2 candidate pool *alongside* `/todo next` (2a.2) — but they are **not** auto-committed, and their `scheduled:` is **not** advanced by being a candidate. The IPM still decides per task in 2a.4: **accept** (place in a Tier → gets `scheduled` in 2a.5) or **re-cut** (re-list under this IPM's `## Considered but cut` with a reason). No silent drops — a perpetually-deferred task then recurs across consecutive IPM files, which is exactly the chronic-deferral signal `/retro`'s bump-counter surfaces.

#### 2a.2 Pick candidates (Tier 2)

Run `/todo next` to get the top 5 ranked Tier 2 tasks (`Design` or `Open`). The `/todo next` ranking already factors deadlines, urgency ratio, and unblocks-others — see `../todo/SKILL.md` Workflow: `next`. Do not second-guess that ordering here; the IPM trusts it.

**Also fold in the staged candidates.** Look for this week's pre-IPM stub at `dev/JOURNAL/${SCHEDULED}-ipm-weekly.md` directly — *not* via `_ipm/current.sh`, which deliberately skips it (the selector returns the last *committed* IPM, never the still-`Pre-IPM staging` stub). If it exists, read its `## Candidates` section. Each entry was appended via `/stage` throughout the week and **carries its own one-line rationale** ("Why this iteration") — the signal `/todo next`'s mechanical ranking can't reconstruct. Merge these into the Tier 2 candidate pool alongside the `/todo next` top-5; dedupe by task ID. A staged candidate is a deliberate human/skill nomination, so weight its rationale when ordering — but it still passes through the 2a.4 budget cut like any other pick.

**Cron-mode eligibility filter.** When `CCXP_CRON_MODE=1`, drop any candidate whose `status:` is still `Open` (i.e., it hasn't been through an interactive pre-IPM design pass — 2a.3 is skipped below, so nothing promotes it to `Design` this run). Only `status: Design` candidates with a non-empty `estimation` are eligible for this week's Tier 2. If the filtered pool is thinner than the product budget line can absorb, that's expected — record it under `## Notes` (e.g. "3 candidates skipped — still `Open`, awaiting a pre-IPM pass") rather than reaching into `Open` tasks to fill the gap. Interactive runs (`CCXP_CRON_MODE` unset/`0`) skip this filter and proceed straight to 2a.3.

#### 2a.3 Pre-IPM design pass — interactive only (skipped when `CCXP_CRON_MODE=1`)

**This step never runs unattended.** It's where business priorities get weighed and a candidate task actually becomes ready to implement — exactly the kind of judgment call reserved for a human at the keyboard (see "Cron mode vs. interactive mode" above). When `CCXP_CRON_MODE=1`, skip straight to 2a.4 with whatever the 2a.2 filter left in the pool. The rest of this step describes the interactive pairing-session flow:

For each Tier 2 candidate, time-box ~10–15 min. **The design pass is `/grill-me`** — run `/grill-me T<id>` (see `grill-me/SKILL.md`), which interviews the human in frontier rounds and, on confirmation, writes the Design section + Test Plan and any estimation revision into the task file. This phase wraps that call with the lifecycle bookkeeping `/grill-me` deliberately does not touch:

1. **Grill it.** `/grill-me T<id>`. It reads the task's Problem (and any existing Design section — a refresh re-validates the assumptions rather than starting cold), asks the frontier rounds, and stops at its synthesis for a go/no-go. Do not run the rounds yourself or summarize on the user's behalf — the whole point is the human answering.
2. **Escalate and skip when a decision can't be made here.** If the synthesis leaves an *Open* item that blocks implementation and needs someone not at the keyboard, file a Slack escalation via the existing protocol (`#claude-notification`) and **skip this task for this week** — do not claim it. It re-enters the candidate pool next IPM. (Non-blocking *Open* items are fine — they stay recorded in the Design section and get resolved in `/drive` Phase 2.)
3. **Confirm the estimate landed.** `/grill-me` step 4 already rewrote `estimation:` and appended `Estimation revised from {old} to {new}: {reason}` to the Design section when the estimate moved; check the frontmatter before the 2a.4 budget cut consumes it. If the pass was a free-text grill (no task file), it wrote nothing — file the task via `/new-task` first, then re-run.
4. **Claim the task before touching its status** (T20260610-248248 — this step
   previously only mirrored to the board, leaving the task unclaimed mid-pass
   and pickable by a peer session's `/todo next`):

   ```bash
   bash ../_session/task_claim.sh release-others <task-id>
   bash ../_session/task_claim.sh acquire <task-id>
   ```

   `acquire` sets `claimed_by` **and** `status: Coding` as a side effect. A
   grilled-but-not-yet-implemented task belongs in `Design`, so correct the
   status back — same two-step pattern `/drive` Phase 1 uses for "a design
   PR will still run":

   ```bash
   bash ../_session/status.sh <task-id> Design
   ```

   Both calls are best-effort; the frontmatter is the source of truth.
5. Tier 1 carry-overs do **not** get a re-grill — once a task is in Coding, the design is presumed adequate. If Coding has revealed the design is wrong, that's a separate "stop and re-scope" event handled outside the IPM ritual.

The grilled task files (Design sections, estimation revisions, claims) are left uncommitted by `/grill-me`; they land together with the IPM file in 2a.5's commit PR, not one PR per candidate.

#### 2a.4 Budget cut

1. Set the weekly budget — start with **20h** of focused-work capacity (≈ half of a 40h week; the other half is PR review, CI watching, RCA, Slack, standup, IPM/retro overhead). **Split it into three explicit lines** so the trade-off is visible instead of absorbed silently:
   - **~12h product** (Tier 1 carry-over + Tier 2 new picks) — the feature/bug/release work below.
   - **~4h infrastructure / tooling** — internal `/drive` + `/ccxp` skill iteration, task-mirror / Project-board plumbing, CI / test scaffolding, and other process work that ships no product artifact but recurs nearly every week. Historically this lands *off*-IPM and preempts product work invisibly (a real observed retro: the task-mirror feature consumed two days and cut a paired feature from that iteration; the two prior iterations showed the same pattern). Budgeting it as a first-class line surfaces the trade-off rather than letting it eat slack or preempt Tier 2.
   - **~4h slack** — nightly RCA churn, Slack escalations, and the unexpected. This line **is** the ~20% buffer; Tier 3 mid-week additions eat from it.

   The retro grades estimate-vs-actual across all three lines and feeds back into next week's budget.
2. Subtract Tier 1 carry-over from the **~12h product** line first.
3. Walk Tier 2 candidates top-down (with revised estimations), accumulating against the remaining product budget. The cut line is: "next task would exceed the ~12h product line."
4. **Pick the infrastructure / tooling line explicitly** — treat it like Tier 2: name the commitments (task file IDs, estimation, "why now") in the IPM file's `## Infrastructure / tooling` table, rather than letting them happen invisibly. Skill-iteration / plumbing / CI-scaffolding tasks tracked in `dev/TODO/` are eligible; if the foreseeable work isn't filed as tasks, file it so it enters the board. Don't pre-commit the full ~4h — leave part open for the week's emergent tooling needs, but record what you *do* foresee so it's planned, not preemptive.
5. If after all candidates fit the product line still has ≥ 10h headroom, expand the candidate pool (re-run `/todo next` excluding already-picked tasks) and keep packing until the product line is reasonably committed.
6. Don't pad to 100% — the **~4h slack line is the buffer (≈20%)**. Aim for ~80% commit (product + infra/tooling = ~16h), ~20% slack.

#### 2a.5 Write ipm-weekly.md + tag Tier-1/2 task files with Scheduled

Write `dev/JOURNAL/YYYY-MM-DD-ipm-weekly.md`. **Revise-in-place if a `/stage` stub already exists at this path** — when candidates were staged during the prior week, `/stage` already created `dev/JOURNAL/${SCHEDULED}-ipm-weekly.md` with header `**Status**: Pre-IPM staging` and a populated `## Candidates` section. In that case do NOT create cold (it would clobber the staged rationale): edit the existing file in place — populate the Tier tables, and **drop the `**Status**: Pre-IPM staging` marker line** so the file reads as a committed IPM (this is what makes `_ipm/current.sh` start selecting it). Only create the file cold when no stub exists. The IPM's deliverables are: (a) Tier 1/2 commit, (b) cuts with reasons, **(c) recommended execution order interleaving the two tiers**, (d) notes/escalations, and (e) a disposition for every carry-over candidate from 2a.1.5 (accepted into a Tier, or re-cut under `## Considered but cut`). The execution order is what `/drive` consumes day-to-day; without it, the IPM is just a wishlist.

**Render every task reference as a clickable markdown link (T20260608-353422).** In every table below (Carry-over, Carry-over candidates, New picks, Infrastructure/tooling, Tier 3, Considered but cut, Recommended execution order), the `Task` column is a link, not bare text — `[T<id>](<issue-url>)`, built via the same map-free resolver the daily standup uses (Phase 1.4):

```bash
source ../_taskid/url.sh
taskid-mdlink T20260427-298901      # -> [T20260427-298901](https://github.com/…/issues/…)
```

`taskid-mdlink` defaults to `--issue` mode (unlike `taskid-slacklink`'s blob-mode default) — the *right* choice here, because an IPM file is written once and never regenerated: a blob-mode link baked in at write time can still rot if the referenced task later moves (`dev/TODO/` → `dev/JOURNAL/` on close), while the issue URL never does.

In the same step, for each Tier 1 / Tier 2 task picked, edit the task file in `dev/TODO/` to set `scheduled: ${SCHEDULED}` in its YAML frontmatter. **Always overwrite**, never skip — when a task moves between IPMs (Tier 1 carry-over from a previous week, or business-priority shift pulling it from a later iteration), the new IPM's Monday becomes the authoritative scheduled date. The git log of the task file preserves the full `scheduled` history; retro's bump-counter walks the IPM files themselves rather than reading the task file's current `scheduled` value.

**This applies to claimed / peer-owned tasks too — being claimed does not exempt a task from `scheduled:` advancement.** Editing only the `scheduled:` field of a peer-claimed task is an IPM planning action — it re-tracks which iteration the work belongs to; it does **not** touch the peer's branch/PR/work and is therefore **not** a violation of the anti-steal / collective-ownership rule. The board's Iteration field is *derived* from `scheduled:` (via the per-repo `sync-tasks-to-issues.py`), so a carry-over whose `scheduled:` is left stale stays pinned to the old iteration on the board even though the IPM prose "carried" it. That is exactly how T20260320-000029 ended up in the 06-22 Tier 1b table yet still displayed on Iteration 10 — listed but never re-`scheduled:`. Carrying a task in the prose and advancing its `scheduled:` are one action, not two: do both, every claimed task included.

**Cut candidates — advance, never clear.** For every task placed under this IPM's `## Considered but cut`, set `scheduled:` in its `dev/TODO/` frontmatter to **next** Monday — never delete the field (`scheduled` is update-forward-only). Compute next Monday from `${SCHEDULED}`:

```bash
NEXT_MON=$(date -d "${SCHEDULED} +7 days" +%F 2>/dev/null || date -j -v+7d -f %Y-%m-%d "${SCHEDULED}" +%F)
```

Then **pre-append** each cut task to next-Monday's pre-IPM stub `dev/JOURNAL/${NEXT_MON}-ipm-weekly.md` under `## Candidates`, as a `### Re-surfaced YYYY-MM-DD (cut at IPM)` sub-section (the same shape `/stage` uses for duplicates). If that stub doesn't exist yet, create it from the `/stage` header template first. This keeps the board (`iteration:@next`) and the doc stub consistent between now and next Monday. Phase 2a.1.5 re-folds the same cut at next IPM and **dedupes by task ID**, so a pre-appended cut is not double-listed.

```markdown
# Weekly Focus: YYYY-MM-DD (Mon) → YYYY-MM-DD (Fri)

**Scheduled**: {SCHEDULED}
**Budget**: 20h focused-work
**IPM duration**: ~{N} min ({start time}–{end time})

## Carry-over (Tier 1 — finish first)

| # | Task | Status | Est | Cumulative | Deadline |
|---|------|--------|-----|------------|----------|
| 1 | T... | Coding | 2h  | 2h         | 2026-04-30 |

## Carry-over candidates (deferred at {prev IPM date})

*Seeded in 2a.1.5 from last IPM's `Considered but cut`. Each must be dispositioned: accepted into a Tier above (gets `scheduled`) or re-cut below. Omit the section if there were no prior cuts.*

| Task | Prior cut reason | Disposition this IPM |
|------|------------------|----------------------|
| T... | {reason from last IPM} | Tier 2 / re-cut: {reason} |

## New picks (Tier 2)

| # | Task | Original est | Revised est | Cumulative | Deadline | Why |
|---|------|--------------|-------------|------------|----------|-----|
| 2 | T... | 1h | 1h     | 3h  | —          | Unblocks T... |
| 3 | T... | 4h | 8h (1d)| 11h | 2026-05-08 | ARM deadline next week |

**Cut line at 11h** — leaves the ~12h product line ~1h spare; the rest of the 20h is the infra/tooling + slack lines below.

## Infrastructure / tooling (~4h line)

*The explicit budget line for skill iteration / plumbing / CI-scaffolding work (2a.4 step 4). Named here at IPM commit so it's planned, not preemptive. Leave part open for emergent needs; don't pre-commit the full ~4h. Empty is fine on a light week — but record it as a deliberate `(none foreseen)`, not a silent omission.*

| # | Task | Est | Why this iteration |
|---|------|-----|--------------------|
| i1 | T... | 2h | `/ccxp` Phase-X fix surfaced by last retro |

## Tier 3 — Mid-week additions (appended after IPM commit)

*Initialize empty at IPM commit. Tasks added throughout the week — via `/rca` red-pipeline auto-promotion (see `/rca` Step 6), `/stage` skill (T20260513-103349), or manual append — land here.*

| # | Task | Est | Added | Why this iteration |
|---|------|-----|-------|--------------------|
| (none yet) | | | | |

**Tier 3 budget rules**:
- No fixed budget — Tier 3 eats from the slack reserved at IPM (typical: 4h of slack on a 20h budget after ~80% commit across Tier 1 + Tier 2 + the infra/tooling line).
- Hard cap: if cumulative Tier 3 hours exceed the slack reserve, the additions are stretch goals — flag in retro that they pushed Tier 1/Tier 2 work into next week.
- Red-pipeline auto-promotions (from `/rca` Step 6) are exempt from the cap — recurring pipeline failures compound; they always belong in the current iteration regardless of budget.

## Recommended execution order

Sequenced by **dependency unblock + business priority + parallelism (labrun async ↔ foreground)**. Tier 1 and Tier 2 are interleaved so customer-facing / high-business-priority work starts early; tech-debt items land after the high-priority track is moving. List the tasks 1..N across the week, day-by-day, with a one-line "why this slot" each.

### Mon (Day 1) — {theme} (~Xh focused)

| # | Task | Est | Why this slot |
|---|------|-----|---------------|
| 1 | T... | 30m | Unblocks tasks 3, 7 — small, fast |
| 2 | T... | 2h  | Depends on #1 |

### Tue (Day 2) — {theme} (~Xh)

| # | Task | Est | Why this slot |
|---|------|-----|---------------|
| 3 | T... | 3h  | Foreground while #4 labrun runs async |
| 4 | T... | 2h  | Long labrun — dispatch early to amortize |

(Continue through Wed / Thu / Fri.)

### Parallelism that makes the budget fit

| Slot | Async (labrun running) | Foreground |
|---|---|---|
| Mon PM | T...A labrun (~2h) | T...B foreground |

### Critical-path checkpoints

| Day | Checkpoint | If missed |
|---|---|---|
| End of Mon | T... merged; T... dispatched | Slip everything 1 day |

## Considered but cut

| Task | Reason |
|------|--------|
| T... | Design pass revealed 3d effort, breaks budget — re-rank next IPM |
| T... | Blocked on customer reply — waiting |

## Notes

- Design pass on T... raised ABI compatibility question → escalated to Slack thread {url}
```

#### 2a.5a Drain the previous iteration (HARD GATE — the IPM commit is not final until this is green)

2a.5 advances `scheduled:` for the Tier-1/2 picks (carry-overs) and for cut candidates. But a third class slips through **both** paths: an `Open`/`Design` task with an **empty** claim that was scheduled into the *previous* iteration and neither got picked this IPM nor cut. The 2a.1 carry covers in-flight (`Coding`/`Review`) + `claimed_by` tasks; 2a.5's cut-advance covers what this IPM explicitly cuts; an unclaimed not-started task that nobody touched is caught by **neither** and silently strands on the now-closed iteration on the board (the recurring leak — T20260320-000029 sat on Iteration 10 while the prose "carried" it; T20260622-147834 filed the gate for exactly this).

The maintainer rule: **at IPM end, every previous-iteration board item that is not terminal (`Done`/`Parked`) must be migrated out.** Enforce it with the hard gate `../_ipm/ipm-iteration-drain-check.sh` (shipped by T20260622-147834; T20260623-811944 wires it here; moved out of build-pipeline's own scripts/ and generalized by T20260719-111051). Run **after** 2a.5 (so the picks' `scheduled:` are already advanced) and **before** the IPM is considered committed:

1. **List the strand-class offenders.** Query the board for items still on the previous iteration whose status is non-terminal — the gate does this for you (run it; on a non-zero exit it *prints* each offender). The previous iteration is resolved by the board's iteration **start-date window** (the current iteration is the latest `startDate` ≤ today; the previous is the next-earlier distinct `startDate`) — **never** a client-side counter (`ls | wc -l` desyncs the instant a Monday IPM is skipped or backfilled). Same date-window discipline as `_ipm/current.sh`. The gate **partitions** offenders by repo (Option C — T20260628-592642): **same-repo** offenders (the `--home-repo`, auto-detected from this clone's `git remote get-url origin`) are **blocking** (exit 1 — the IPM can drain them by editing their task files); **cross-repo** offenders (e.g. `hub-repo` items the build-pipeline clone cannot edit) are printed as **non-blocking `⚠` warnings** so the unattended commit is never deadlocked on items it has no way to drain. (Forward-compatible with end-state options A/B in T20260628-592642 — Option C is the deadlock-safety valve, not the final design.) **Lint-frozen sub-partition (T20260628-951477):** a same-repo offender whose task file fails the changed-mode `Lint task frontmatter` check — pre-existing non-allowlisted fields, the unresolved T20260626-353630 schema-fork class — **cannot** have its `scheduled:` advanced without an unrelated lint red. The gate probes each same-repo offender (`lint_tasks.py --changed`) and downgrades the **lint-frozen** ones to the same non-blocking `⚠` warning; only **clean** (editable) same-repo offenders block (fail-safe: anything the probe can't classify stays **blocking** — no silent exemption). So an IPM whose only remaining same-repo offenders are lint-frozen reaches **exit 0** instead of deadlocking — the real fix is resolving T20260626-353630.
2. **Drain each offender** — this applies to the **clean** same-repo (blocking) offenders; cross-repo and lint-frozen warnings are surfaced for the maintainer, not drained here (a lint-frozen file can't be edited until T20260626-353630 lands). For every listed same-repo task, decide and act exactly like 2a.5's per-task disposition: **carry** it (advance its task-file `scheduled:` to this IPM's `${SCHEDULED}` and place it in a Tier) or **defer** it (advance `scheduled:` to a future Monday and pre-append it to that Monday's `## Candidates` stub, per 2a.5's "Cut candidates — advance, never clear"). Either way `scheduled:` moves **forward** — never deleted. The board's Iteration field is *derived* from `scheduled:` via the per-repo `sync-tasks-to-issues.py`, so bumping `scheduled:` is what actually re-tracks the item off the closed iteration.
3. **Gate the commit.** Re-run the check; the IPM is **not committed** until it exits **0**:

   ```bash
   # Runs in ccxp's home clone; reads the live board via `gh project item-list`.
   # Default terminal set is "Done|Parked"; --home-repo/--owner auto-detected
   # from this clone's git remote `origin` (T20260719-111051) — no repo/org
   # hardcoded in the script itself.
   bash ../_ipm/ipm-iteration-drain-check.sh
   #   exit 0 → previous iteration clean of CLEAN (drainable) SAME-REPO offenders (cross-repo AND lint-frozen offenders, if any, were printed as ⚠ warnings and do NOT block) — proceed to 2a.5b
   #   exit 1 → it printed CLEAN (editable) same-repo offenders still pinned to the previous iteration — drain them (step 2) and re-run
   #   exit 2 → usage error (bad flag/arg, or --home-repo/--owner could not be auto-detected and none was given)
   ```

   Overrides (rarely needed — the defaults are correct for a normal Monday run):
   - `--prev-start YYYY-MM-DD` — force the previous iteration's start date, skipping date-window resolution (useful when a skipped/backfilled Monday makes the window ambiguous, or for a dry-run against a known iteration).
   - `--today YYYY-MM-DD` — override "today" for the window resolution.
   - `--terminal "Done|Parked"` — the regex alternation of statuses that count as drained. `Parked` is terminal **on purpose** (a parked task is deliberately set aside in `dev/PARKING/`, not stranded work to force-migrate); don't narrow it to just `Done` or the gate will demand you migrate parked items.
   - `--home-repo OWNER/NAME` — the repo whose offenders **block** (default: auto-detected from this clone's `git remote get-url origin` — the repo ccxp runs in and can drain). Offenders in any **other** repo are reported as non-blocking warnings. Override only when the clone's remote doesn't match the repo you want treated as home (e.g. a fork).
   - `--repo-path DIR` — where same-repo task files are resolved for the lint-frozen probe, AND the source of the `--home-repo`/`--owner` auto-detect (default `.`, the IPM's own clone). `LINT_TASKS_PY` overrides the linter path (default `../repo-conventions/scripts/lint_tasks.py`); `IPM_DRAIN_FROZEN_IDS` forces the frozen set for tests. (T20260628-951477)
   - `--project N` — board number (default `1`). `--owner ORG` — board owner (default: auto-detected from this clone's git remote, same source as `--home-repo`).

   The gate is **non-destructive** (read-only — it lists, it doesn't edit); the draining in step 2 is what mutates `scheduled:`. A clean previous iteration (or the very first IPM, when no previous iteration exists) is a no-op exit 0.

#### 2a.5b Update the ROADMAP doc in the configured hub repo (cross-repo)

The multi-IPM ROADMAP doc lives at `dev/ROADMAP.md` in a separate hub repo (filed by T20260510-836314) — the hub is **required config, not a hardcoded repo name** (`ROADMAP_TARGET_REPO="<owner>/<repo>"`, resolved the same way as every other `~/.claude/.env`-backed var in this suite: already-exported wins, else `~/.claude/.env`; T20260827-280088). After writing this week's IPM file, propagate the commit forward into the ROADMAP via an ephemeral clone of that hub repo (same pattern as `/drive` Phase 1.5 cross-repo dispatch — T20260513-403409). The ccxp run never touches the maintainer's working clone of the hub repo.

```bash
TARGET=$(bash ../ccxp/scripts/update-roadmap.sh clone)
cd "$TARGET"
```

`update-roadmap.sh clone` clones `ROADMAP_TARGET_REPO` into a fresh `/tmp` directory on a dated `roadmap/ipm-*` branch and prints its path — the ccxp run never touches the maintainer's working clone of that repo. It exits with a clear error (no clone attempted) if `ROADMAP_TARGET_REPO` is unset.

If `dev/ROADMAP.md` doesn't yet exist (first run before T20260510-836314 Phase 1 ships), create it from the template in the task file's "Initial content shape" section, then proceed. Otherwise, apply these updates in place:

1. **Promote this week's commitments** from "Deferred / on watch" → "Near-term" (or shift them within the near-term table if already there). Pull the task list from Phase 2a.4's budget cut output (Tier 1 + Tier 2 picks).
2. **Demote anything cut** in Phase 2a.4 → "Deferred / on watch" with a 1-line "why cut" reason (mirrors the "Considered but cut" section of the IPM file).
3. **Advance the "Last updated" line** to today's date + link to this IPM's commit PR (resolve the PR URL after Phase 2a.5's IPM file is pushed and PR'd in build-pipeline).
4. **Archive shipped entries**: any near-term entries whose week is now in the past AND whose tasks shipped (per `dev/JOURNAL/<date>-T<id>-*.md` evidence in build-pipeline) move to a `## Recently shipped` section at the bottom of ROADMAP.md. **"Drop off" semantics**: keep this section to the last 4 weeks; older entries roll out of the live table — git blame on ROADMAP.md preserves the row-by-row edit history, and per-week JOURNAL entries (`<date>-ipm-weekly.md`, `<date>-retro-weekly.md`) remain unchanged in build-pipeline. The 4-week window is a display budget, not a data-loss window.

After edits, once this IPM's build-pipeline commit PR is up and its URL known:

```bash
bash ../ccxp/scripts/update-roadmap.sh commit-pr --target "$TARGET" --bp-pr-url "<build-pipeline IPM PR URL>"
```

Runs the doc-lint guard (shared script, runs for real here too now — T20260719-111051), commits, pushes, opens the PR against the configured `ROADMAP_TARGET_REPO`, and removes the ephemeral clone.

This is a small, focused PR (~5-10 lines changed per IPM). Auto-mergeable per `dev/guidelines.md` carve-out — pure status-shift content, no design decisions inside.

If any step fails (clone, edit, commit, push, PR-create): slack the maintainer `*IPM 2a.5b*: ROADMAP update aborted — {step} failed: {error}`. The IPM file in build-pipeline is already committed; the ROADMAP can be hand-updated later or retried via a re-run of just Phase 2a.5b.

#### 2a.6 Slack the focus

Send to `#claude-notification` via MCP `slack_send_message`. On send failure, apply the same
webhook fallback as Phase 1.4 (T20260717-433409) — this is a weekly, guaranteed-to-fire send in
the same failure-prone path:

```
*Weekly Focus* (YYYY-MM-DD)
- Budget: 20h, committed: {N}h
- Carry-over: {M} tasks ({list})
- New picks: {K} tasks ({list})
- Top deadline: {task} due {date}
```

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
| Mon | Pull both repos | Normal (with ipm-weekly block — references prior week's focus until 2a writes the new one; checks last night's runs) | **Run IPM** (budget-cut only — 2a.3 pre-IPM design pass skipped) | Skip | Skipped (cron mode) |
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
