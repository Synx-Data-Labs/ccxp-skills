---
name: labrun-rca
description: Use when the input is a Slack permalink to a failure notification — RCA the announced GitHub Actions run and reply in the thread
argument-hint: "<slack-message-url>"
---

Run root cause analysis on a GitHub Actions failure that was announced in Slack, and post the RCA report as a thread reply on the original notification.

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

## Argument

`$ARGUMENTS` is the permalink of the Slack message that announced the failure:

```
/labrun-rca https://example-workspace.slack.com/archives/C000EXAMPLE/p1600000000000000
```

One URL per invocation. The permalink copy-path in Slack is _Copy link_ on the message's "more actions" menu.

## Workflow

### 1. Parse the Slack URL

```bash
bash <skills-root>/labrun-rca/scripts/labrun.sh parse "<slack-message-url>"
```

Prints `channel_id=<id>` and `message_ts=<10 digits>.<6 digits>` (the `p...` digits with a dot inserted 6 characters from the end); exit 2 on a malformed URL (channel must start with `C`/`G`/`D`) — fail fast and show the expected format.

### 2. Read the notification

Use MCP `slack_read_thread` with `channel_id` + `message_ts` to fetch the parent message (and any existing replies — if someone has already posted an RCA, stop and report the thread URL rather than duplicating work).

From the parent message text / attachments, extract:

- **Workflow name** (e.g. "Release AcmeDB")
- **Run ID** — pipe the message text through `bash <skills-root>/labrun-rca/scripts/labrun.sh extract-run`: it prints `run_id=<id>` (plus `run_url=` when a link was present); exit 3 = no run id, exit 4 = several distinct ids (`candidate=` lines) — either way take the ambiguous path below, never guess
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

Delegate to `/rca <run-id> --no-post` (`--no-post` suppresses `/rca` §5.5's channel-root Slack post — step 5 below is the one and only post, in the thread). That skill handles:

- Run lookup (`gh run view`)
- Failed job + step identification
- Error log extraction (`gh run view --log-failed`)
- Classification (Our code / Infrastructure / Upstream / Transient / Configuration)
- Impact assessment (is `main` red?)
- Task creation in `dev/TODO/` when actionable

Let `/rca` write the normal RCA report to the conversation. Capture its output structure (root cause, classification, confidence, impact, task ID if any).

### 5. Post the RCA report to the thread

Render the reply from the `/rca` result, then post it via `slack_send_message` with `thread_ts=message_ts` (the script only renders; posting stays here):

```bash
bash <skills-root>/labrun-rca/scripts/labrun.sh render-reply --workflow "<workflow>" --run-id <run-id> \
  --run-url "<run-url>" --error "<one-line error from logs>" --root-cause "<1–2 sentence explanation>" \
  --classification "<Our code|Infrastructure|Upstream|Transient|Configuration>" \
  --confidence "<Confirmed|Unconfirmed>" --impact "<what's blocked>" \
  --action "<task-id if created, otherwise 'None — <reason>'>"
```

It prints the `mrkdwn` reply (`*RCA — <workflow> run <run-id>*` header, Error / Root cause / Classification / Confidence / Impact / Action, then `Logs: <run-url|run>`). Exit codes:

- `5` — classification/confidence not in the enum; fix the input.
- `6` — the reply contains a token-like string; redact the offending text and re-render, never post around it. The scrub is best-effort pattern matching, not a guarantee, so still spot-check.
- `2` — usage (every value is one line).

The reply escapes `&`, `<`, `>` as Slack requires and swaps backticks in the error for `'`.

Keep it compact. A Slack thread reply is for a quick read, not the full transcript — the run URL is the escape hatch for anyone who wants the raw logs.

### 6. Task creation

`/rca` already handles task creation per its classification rules. If it creates a task:

- Mention the task ID in the thread reply (see step 5).
- No extra action required from this skill — the task file lands in `dev/TODO/` on the feature branch where `/rca` was invoked.

If the caller is not in a repo context (e.g., running this from a personal dir), `/rca` will still classify the failure but may not be able to create a task. In that case the thread reply ends with `Action: needs manual follow-up — RCA above`.

## Edge cases

| Situation | Handling |
|-----------|----------|
| Malformed URL (no `/archives/…/p…`) | `labrun.sh parse` exits 2 — fail fast, print the URL format expected |
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

- **Thread-only replies.** Never post to the channel root when replying with RCA findings — always use `thread_ts`. This keeps `#acme-automation-alerts` readable.
- **One RCA per failure.** Check the thread before starting so concurrent ccxp sessions don't race on the same message.
- **No secrets in replies.** Paste log excerpts, not environment variables or tokens. The `gh run view --log-failed` output is generally safe but spot-check before sending.
- **Respect `/rca`'s classification and confidence.** Don't editorialize. If `/rca` says Transient, the Slack reply says Transient — and if it says Unconfirmed, the reply says Unconfirmed, not a bare classification that reads as definitive.
