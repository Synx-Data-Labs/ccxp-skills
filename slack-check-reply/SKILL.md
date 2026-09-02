---
name: slack-check-reply
description: Use when the user explicitly asks to check for replies on the Slack escalation threads /drive opened, or on the daily standup thread
disable-model-invocation: false
argument-hint: "<task-id> | all | standup"
---

Check for replies on Slack messages sent by `/drive` escalations.

## Argument

`$ARGUMENTS` is one of:

- A task ID (e.g., `T304536`) — check replies on that task's escalation thread
- `all` — check all pending (unresolved) escalation threads **and the latest daily standup thread**
- `standup` — check only the latest daily standup thread
- Empty — same as `all`

> **Why the standup thread matters.** The maintainer often answers blockers by
> replying to the **daily standup summary** itself — one reply resolving several
> escalations at once — rather than replying inside each per-task escalation
> thread. Those individual escalation threads are the only ones in
> `drive-threads.json`, so a reply on the standup thread is invisible to a
> state-file-only check: a headless `/ccxp` cron loop that only polls the
> per-escalation threads can run indefinitely and never notice a
> standup-thread reply that batch-resolves several of them at once. `all` and
> `standup` MUST therefore always check the standup thread, which is
> discovered live (below), not tracked in the state file.

## State File

Thread references are stored in `.claude/state/drive-threads.json`:

```json
{
  "T304536": {
    "channel_id": "C0ABC123",
    "message_ts": "1712764200.001234",
    "type": "design-decision",
    "summary": "Design decision needed — auth middleware approach",
    "sent_at": "2026-04-10T14:30:00Z",
    "resolved": false
  }
}
```

Create the directory and file if they don't exist (`mkdir -p .claude/state`).

## Prerequisites

`SLACK_STANDUP_CHANNEL` — the channel the daily standup summary (and
escalation threads) are posted to, e.g. `claude-notification` (no leading
`#`; the queries below add it). Required for the standup-thread check
(step 1a) and its search fallback (step 4); there is **no baked-in
default**. The search follows this order, first hit wins:

1. Already-exported env var
2. `~/.claude/.env` (machine-global, same convention as `SLACK_WEBHOOK_URL`
   — see `slack/SKILL.md`'s Prerequisites, `vpn/scripts/vpn.sh`'s
   `load_vpn_env`, `_session/_lib.sh`'s `_session_load_env`)

```
SLACK_STANDUP_CHANNEL=claude-notification
```

If unset, the standup-thread search (step 1a) is skipped with a one-line
note instead of failing, and the search fallback (step 4) can't recover a
stale channel_id either — normal escalation-thread reads (using the
`channel_id`/`message_ts` already stored in the state file) are unaffected.

## Workflow

1. **Read state file** `.claude/state/drive-threads.json`
   - If task ID given: filter to that entry; error if not found — then skip step 1a (a task ID targets one escalation thread, not the standup).
   - If `all` or empty: filter to entries where `resolved` is `false`. A missing/empty file is **not** a stop condition here — still run step 1a (the standup thread is the common case and lives outside this file).
   - If `standup`: skip the state file entirely; go straight to step 1a.

1a. **Resolve the latest daily standup thread** (run for `all`, empty, and `standup`):

- If `SLACK_STANDUP_CHANNEL` is not configured (see Prerequisites), skip this
  step entirely and report: "no standup channel configured — skipping
  standup-thread check, escalation threads only." Continue with the
  escalation threads (for `standup`, there is then nothing to check).
- `slack_search_public_and_private` with query: `from:me in:#$SLACK_STANDUP_CHANNEL "Daily Standup"`
- Sort by `timestamp` descending; take the **first** match — that's today's (or the most recent) standup parent.
- Extract its `channel_id` and `message_ts`. This is the standup thread; it is discovered live every run, never written to `drive-threads.json` (it's per-day and ephemeral).
- If the search returns nothing, report "No standup thread found" for this section and continue with the escalation threads.

2. **For each pending thread** (the standup thread from 1a, plus each escalation entry), call `slack_read_thread` MCP tool:
   - Pass `channel_id` and `message_ts`
   - Read all replies (skip the parent message itself)

3. **Report results** for each thread:
   - Task ID, escalation type, summary, when sent
   - If no replies: "No replies yet (sent {relative time})"
   - If replies: show each reply — who, when, content
   - Highlight actionable directives (e.g., "go with option A", "skip this", "merge it")
   - **For the standup thread specifically**: a single reply usually batches decisions for **multiple** tasks (one paragraph or bullet per task, each citing a task link/ID). **Split it** — attribute each directive to the task it references, and treat each as resolving that task's blocker exactly as if it had been posted in that task's own escalation thread. Replies may also raise *new* scope (follow-up tasks, new concerns) not tied to an existing escalation — surface those verbatim under a "New scope raised" note so the caller can file them; do not silently drop them.

4. **Search fallback**: If `slack_read_thread` fails (e.g., stale channel_id), recover:
   - If `SLACK_STANDUP_CHANNEL` is not configured, this fallback can't search
     by channel either — report the original `slack_read_thread` failure for
     that thread and move on (no query attempted, no crash).
   - `slack_search_public_and_private` with query: `{task_id} from:me in:#$SLACK_STANDUP_CHANNEL`
   - Sort by `timestamp` descending, take the first match
   - Extract `channel_id` and `message_ts` from the result
   - Update the state file with corrected values
   - Retry `slack_read_thread`

5. **Return structured output** (for callers like `/drive`):

   ```
   ## Escalation replies

   ### Standup thread (replied 2h ago)
   - @maintainer: batched reply covering 3 tasks
     → T304536: proceed with the dry-run-after-commit proposal
     → T304537: fix at source, rebuild the image
     → T304538: pick the cdn_url option
   - New scope raised:
     → file follow-up: env var to bypass the upstream proxy (cost)
     → file follow-up: a package-registry read token for the release SBOM

   ### T304536 — design-decision (sent 2h ago)
   - (also answered in the standup thread above)

   ### T304537 — blocker (sent 1d ago)
   - No replies yet
   ```

## Examples

```
/slack-check-reply T304536
/slack-check-reply all       # escalation threads + standup thread
/slack-check-reply standup   # standup thread only
/slack-check-reply
```
