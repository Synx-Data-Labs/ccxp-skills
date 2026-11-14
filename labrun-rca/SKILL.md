---
name: labrun-rca
description: Use when the input is a Slack permalink (or channel id + message ts, or a run id) of a failure notification — RCA the announced GitHub Actions run and reply in the thread
argument-hint: "<slack-message-url> | <channel_id> <message_ts> | <run_id>"
---

Run root cause analysis on a GitHub Actions failure that was announced in Slack, and post the RCA report as a thread reply on the original notification.

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

## Argument

`$ARGUMENTS` is the permalink of the Slack message that announced the failure:

```
/labrun-rca https://example-workspace.slack.com/archives/C000EXAMPLE/p1600000000000000
```

One alert per invocation.

- Permalink: _Copy link_ on the message's "more actions" menu.
- A job that holds no URL passes the pair instead: `/labrun-rca C000EXAMPLE 1600000000.000000`.
- A bare run id (6+ digits) skips step 1's channel guard and steps 2-3 (no thread exists, so nothing is read or posted): it only runs the RCA in the working repo and reports to the caller.

## Workflow

### 1. Resolve the input and apply the channel guard

```bash
bash <skills-root>/labrun-rca/scripts/labrun.sh input "<slack-message-url>" | <channel_id> <message_ts> | <run_id>
```

Prints `channel_id=<id>` and `message_ts=<10 digits>.<6 digits>` (a permalink's `p...` digits get a dot inserted 6 characters from the end; a pair is validated as given), or `run_id=<id>`. Exit 2 on a malformed input (channel must start with `C`/`G`/`D`) — fail fast and show the expected formats. `labrun.sh parse <url>` stays for URL-only callers.

**Channel guard (before any read or post):** `bash <skills-root>/labrun-rca/scripts/labrun.sh channel-guard <channel_id>` must exit 0, i.e. the channel is `$SLACK_AUTOMATION_ALERTS_CHANNEL_ID` (#slack-automation-alerts). Exit 8 or 2: stop, post nothing. Every post of this skill goes to the thread of the given message in that channel, never anywhere else.

### 2. Read the notification

Use MCP `slack_read_thread` with `channel_id` + `message_ts` to fetch the parent message and any existing replies. Feed the replies (one `ts<TAB>text` line per reply, newlines flattened, parent excluded) to `bash <skills-root>/labrun-rca/scripts/labrun.sh thread-state --now "$(date +%s)" --live-job yes|no`:

- `done` (exit 10): a reply starts with `*RCA` — stop and report the thread URL rather than duplicating work.
- `wait` (exit 11): only the step 3 ack is there and it is under 60 minutes old, or a job for this alert is live and the ack is all the thread has — stop.
- `continue` (exit 0): no replies, or an ack-only thread older than 60 minutes with no live job (the job that posted the ack died) — go on and reply under it.

From the parent message text, **blocks and attachments** (older composite-action alerts carry the run link only in a button: save the whole message JSON to a file and give that to `extract-run`, which also reads `\/`-escaped URLs), extract:

- **Workflow name** (e.g. "Release AcmeDB")
- **Run ID** — pipe the message text through `bash <skills-root>/labrun-rca/scripts/labrun.sh extract-run`: it prints `run_id=<id>` (plus `run_url=` when a link was present); exit 3 = no run id, exit 4 = several distinct ids (`candidate=` lines) — either way take the ambiguous path below, never guess
- **Branch** (usually `main` for lab runs)
- **Conclusion** (should be `failure`)

Then decide whether to answer at all:

- Feed the whole message (text plus the flattened blocks/attachments JSON, so a block-only alert is seen) to `bash <skills-root>/labrun-rca/scripts/labrun.sh alert-kind --branch <branch> --default-branch <the repo's default branch>` (default `main` when omitted).
- Exit 9 (`not a failure alert`: no failure signal, success or recovered wording, or another branch) means **stay silent**: post nothing, report `not a failure alert` to the caller. Never reply "run is green"; one reply per failure thread.

Repo guard:

- `bash <skills-root>/labrun-rca/scripts/labrun.sh repo-of <run-url>` gives `owner/repo`; `bash <skills-root>/labrun-rca/scripts/labrun.sh repo-allowed <owner/repo>` must exit 0.
- With no run url (bare run id) the RCA runs in the working repo: check that one (`gh repo view --json nameWithOwner`).
- Exit 7 (outside `LABRUN_SERVED_OWNERS`): post a short thread reply "run belongs to <owner/repo>, outside this profile's accounts — needs manual RCA" and stop.

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

## Edge cases and reuse

The edge-case table and the list of skills this one reuses (`/rca`, `/slack`, `/slack-check-reply`, `/drive`, `/ccxp` 1.2.2a) are in [reference.md](reference.md).

## Headless sessions

The MCP `slack_send_message` and `slack_read_thread` calls above work in an interactive session (and the ccxp-agent persona). A headless cron session has no Slack MCP: it must read and post through `<skills-root>/_slack/webapi.sh` (bot token path, as `/ccxp` Phase 1.2.2a does) instead of failing; the channel guard, thread-state and alert-kind checks are identical.

## Notes

- **Thread-only replies.** Never post to the channel root when replying with RCA findings — always use `thread_ts`. This keeps `#slack-automation-alerts` readable.
- **One RCA per failure.** Check the thread before starting so concurrent ccxp sessions don't race on the same message.
- **No secrets in replies.** Paste log excerpts, not environment variables or tokens. The `gh run view --log-failed` output is generally safe but spot-check before sending.
- **Respect `/rca`'s classification and confidence.** Don't editorialize. If `/rca` says Transient, the Slack reply says Transient — and if it says Unconfirmed, the reply says Unconfirmed, not a bare classification that reads as definitive.
