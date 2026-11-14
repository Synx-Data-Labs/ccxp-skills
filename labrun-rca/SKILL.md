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
- A bare run id (6+ digits) skips step 1's channel guard, the Slack read, the thread-state check, the ack and the thread post (no thread exists): the repo guard of step 2 still applies, then step 4 runs the RCA and the result goes to the caller, not to Slack.

## Workflow

### 1. Resolve the input and apply the channel guard

```bash
bash <skills-root>/labrun-rca/scripts/labrun.sh input "<slack-message-url>"   # or: input <channel_id> <message_ts>  |  input <run_id>
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
- **Run ID** — pipe the message text through `bash <skills-root>/labrun-rca/scripts/labrun.sh extract-run`: it prints `run_id=<id>` (plus `run_url=` when a link was present); exit 3 = no run id, exit 4 = several distinct ids (`candidate=` lines) — either way post a short "needs manual RCA input" thread reply and stop, never guess
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

Delegate to `/rca <run-id> --repo <owner/repo> --no-post` (the repo from step 2's guard; `--no-post` suppresses `/rca` §5.5's channel-root Slack post — step 5 below is the one and only post, in the thread). That skill handles:

- Run lookup (`gh run view`)
- Failed job + step identification
- Error log extraction (`gh run view --log-failed`)
- Classification (Our code / Infrastructure / Upstream / Transient / Configuration)
- Impact assessment (is `main` red?)
- Task (`/rca` step 6 files it)

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

Run this before posting step 5. `/rca` step 6 files the task itself (the `/new-task` procedure; never file a second one): Our code, Configuration, Upstream, any Unconfirmed result, Transient or Infrastructure per its plan. This skill then adds `/top <id>` and, after the reply, a background `/drive <id>`:

- **Reuse first.** An open task found by `/rca` step 3.5 gets `/top` and its id.
- Step 5's Action carries the task id.
- No repo context, nothing filed: `Action: needs manual follow-up — RCA above`.

### 7. Several alerts at once

Steps 1-3 run per alert; `labrun.sh group-alerts` ([reference.md](reference.md)) then groups the survivors by run id: steps 4 and 6 run once per run id (the `rca` line first), each alert gets its own step 5 reply.

## Edge cases and reuse

The edge-case table and the list of skills this one reuses (`/rca`, `/slack`, `/slack-check-reply`, `/drive`, `/ccxp` 1.2.2a) are in [reference.md](reference.md).

## Headless sessions

The MCP Slack calls above work in an interactive session (and the ccxp-agent persona). A headless cron session has no Slack MCP: read and post through `<skills-root>/_slack/webapi.sh` (as `/ccxp` Phase 1.2.2a does) instead of failing; the guards are identical.

## Notes

- **Thread-only replies.** Never post to the channel root; always use `thread_ts`.
- **One RCA per failure.** Check the thread first (step 2) so concurrent sessions don't race.
- **No secrets in replies.** Log excerpts only, never environment variables or tokens; spot-check `--log-failed` output.
- **Respect `/rca`'s classification and confidence.** Don't editorialize: Transient stays Transient, Unconfirmed stays Unconfirmed.
