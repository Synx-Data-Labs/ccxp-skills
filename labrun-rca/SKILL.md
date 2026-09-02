---
name: labrun-rca
description: Use when the input is a Slack permalink to a failure notification — RCA the announced GitHub Actions run and reply in the thread
disable-model-invocation: false
argument-hint: "<slack-message-url>"
---

Run root cause analysis on a GitHub Actions failure that was announced in Slack, and post the RCA report as a thread reply on the original notification.

## Argument

`$ARGUMENTS` is the permalink of the Slack message that announced the failure:

```
/labrun-rca https://example-workspace.slack.com/archives/C000EXAMPLE/p1600000000000000
```

One URL per invocation. The permalink copy-path in Slack is _Copy link_ on the message's "more actions" menu.

## Workflow

### 1. Parse the Slack URL

Extract `channel_id` and `message_ts` from the permalink:

```
https://{workspace}.slack.com/archives/{channel_id}/p{ts_without_dot}
                                       ^^^^^^^^^^^^  ^^^^^^^^^^^^^^^
```

`message_ts` = the `p...` digits with a dot inserted 6 characters from the end:

```bash
# p1600000000000000  ->  1600000000.000000
ts_raw="${url##*/p}"
message_ts="${ts_raw:0:${#ts_raw}-6}.${ts_raw:${#ts_raw}-6}"
channel_id="$(echo "$url" | sed -E 's#.*/archives/([^/]+)/p.*#\1#')"
```

Validate: `channel_id` must start with `C`/`G`/`D`, `message_ts` must match `^[0-9]{10}\.[0-9]{6}$`. Fail fast with a clear message if either is malformed.

### 2. Read the notification

Use MCP `slack_read_thread` with `channel_id` + `message_ts` to fetch the parent message (and any existing replies — if someone has already posted an RCA, stop and report the thread URL rather than duplicating work).

From the parent message text / attachments, extract:

- **Workflow name** (e.g. "Release AcmeDB")
- **Run ID** (numeric, usually embedded in a `/actions/runs/<id>` link or a bare number in the message)
- **Branch** (usually `main` for lab runs)
- **Conclusion** (should be `failure`; if it's `success` because the run was retried, stop and note so)

If the notification format is ambiguous (no run ID visible, multiple run IDs, no workflow name), post a short "needs manual RCA input" reply in the thread and stop.

### 3. Acknowledge in-thread

MCP does not expose `reactions.add` and no `SLACK_BOT_TOKEN` is configured, so use an acknowledgment _message_ instead of a reaction. Post via MCP `slack_send_message` with `thread_ts=message_ts`:

```
🔍 Running RCA on <workflow> run <run-id> — will reply with findings.
```

This is the functional equivalent of a `:eyes:` reaction: it tells the channel that someone is on it, and anchors a single thread for the subsequent report. Capture the returned `ts` so the acknowledgment can be referenced if you need to edit it later.

### 4. Run RCA

Delegate to `/rca <run-id>`. That skill handles:

- Run lookup (`gh run view`)
- Failed job + step identification
- Error log extraction (`gh run view --log-failed`)
- Classification (Our code / Infrastructure / Upstream / Transient / Configuration)
- Impact assessment (is `main` red?)
- Task creation in `dev/TODO/` when actionable

Let `/rca` write the normal RCA report to the conversation. Capture its output structure (root cause, classification, impact, task ID if any).

### 5. Post the RCA report to the thread

Format the RCA for Slack `mrkdwn` (`*bold*`, `_italic_`, `` `code` ``, `<url|label>`) and post via `slack_send_message` with `thread_ts=message_ts`:

```
*RCA — <workflow> run <run-id>*

*Error:* `<one-line error from logs>`
*Root cause:* <1–2 sentence explanation>
*Classification:* <Our code | Infrastructure | Upstream | Transient | Configuration>
*Impact:* <what's blocked>
*Action:* <task-id if created, otherwise "None — <reason>">

Logs: <run-url|run>
```

Keep it compact. A Slack thread reply is for a quick read, not the full transcript — the run URL is the escape hatch for anyone who wants the raw logs.

### 6. Task creation

`/rca` already handles task creation per its classification rules. If it creates a task:

- Mention the task ID in the thread reply (see step 5).
- No extra action required from this skill — the task file lands in `dev/TODO/` on the feature branch where `/rca` was invoked.

If the caller is not in a repo context (e.g., running this from a personal dir), `/rca` will still classify the failure but may not be able to create a task. In that case the thread reply ends with `Action: needs manual follow-up — RCA above`.

## Edge cases

| Situation | Handling |
|-----------|----------|
| Malformed URL (no `/archives/…/p…`) | Fail fast, print the URL format expected |
| Private channel the user can't see | `slack_read_thread` will error — surface the error verbatim |
| Message already has a thread reply from labrun-rca | Read the thread, note "already analyzed by <ts>", stop |
| Notification message has no run ID | Post a short "couldn't auto-detect run ID" reply and stop |
| Run succeeded on retry before RCA ran | Post "Run <id> is now green (retry succeeded) — no RCA needed" and stop |
| `/rca` itself errors (e.g., run not accessible) | Post the error verbatim to the thread so the channel isn't left hanging |

## Reuse from existing skills

- `/rca` — all the analysis, classification, and task-creation logic. Do not duplicate it here.
- `/slack` — used today only for fire-and-forget webhook announcements; this skill intentionally bypasses the webhook path in favor of MCP so it can target a specific thread.
- `/slack-check-reply` — reference for the Slack thread state pattern (`.claude/state/drive-threads.json`). labrun-rca does _not_ write to that file; drive-threads is escalations-from-Claude, labrun-rca reacts to alerts-to-Claude.
- `/drive` — uses MCP `slack_send_message` the same way; same channel_id/message_ts conventions apply.
- `/ccxp` Phase 1.2.2a — runs this exact reply behavior automatically every standup tick, for every failure `/rca` classifies during the nightly health check, by searching for the matching alert instead of starting from a copy-pasted permalink (it has a run ID, not a URL). Reuses this skill's Step 5 reply format so both entry points read identically. Invoke `labrun-rca` directly only for ad-hoc cases 1.2.2a won't cover: a failure outside last night's window, or a channel/workflow the automated search didn't match.

## Notes

- **Thread-only replies.** Never post to the channel root when replying with RCA findings — always use `thread_ts`. This keeps `#slack-automation-alerts` readable.
- **One RCA per failure.** Check the thread before starting so concurrent ccxp sessions don't race on the same message.
- **No secrets in replies.** Paste log excerpts, not environment variables or tokens. The `gh run view --log-failed` output is generally safe but spot-check before sending.
- **Respect `/rca`'s classification.** Don't editorialize. If `/rca` says Transient, the Slack reply says Transient.
