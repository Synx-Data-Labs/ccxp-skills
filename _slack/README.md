# `_slack/` — Slack Web API (bot token) lib

Shared helper for calling the Slack Web API directly via `curl` + a bot
token — no MCP. Built for [T20261001-319589](../dev/TODO/T20261001-319589-replace-slack-mcp-with-bot-token-webapi.md):
the `mcp__claude_ai_Slack__*` OAuth-connector tools require an
interactively-granted session and are unavailable in headless/cron
(`CCXP_CRON_MODE=1`, `-p` mode) ccxp sessions — confirmed recurring, not a
one-off. A bot token works identically in cron and interactive sessions
because it's a plain `Authorization` header, not a per-session OAuth grant.

**Scope — read + reply only.** Simple one-way notifications (standup post,
hold-tick note, a generic ping) don't need any of this: keep using the
existing incoming webhooks via `slack/scripts/slack-send.sh`. Reach for
`_slack/webapi.sh` only when a skill needs to **find** a message, **read**
a thread, or **reply inside** one — things an incoming webhook structurally
cannot do (no read/search API, and its POST response carries no usable
`ts` to thread off of).

## Setup (one-time, manual — see T20261001-319589 for the full checklist)

1. On the Slack App used for the existing webhooks ("SynxDB Build Bot" or
   equivalent), add **Bot Token Scopes**: `chat:write`, `channels:history`,
   `channels:read` (add `groups:history`/`groups:read` too for any private
   target channel).
2. **Reinstall the app** to the workspace — this is what generates/refreshes
   the **Bot User OAuth Token** (`xoxb-...`).
3. **Invite the bot** to every channel it needs to post to or read (or grant
   `channels:join` and let it self-join public channels).
4. Set `SLACK_BOT_TOKEN` the same way `SLACK_WEBHOOK_URL` is set today —
   `~/.claude/.env` (machine-global, recommended) or the consumer repo's
   `.env`.

Every function below fails closed with a clear message if `SLACK_BOT_TOKEN`
isn't resolvable — there's no silent partial-availability state.

## Surface

```bash
bash _slack/webapi.sh post <channel_id> <text> [thread_ts]
bash _slack/webapi.sh history <channel_id> [oldest_ts] [latest_ts] [limit]
bash _slack/webapi.sh thread-replies <channel_id> <message_ts>
bash _slack/webapi.sh find-by-text <channel_id> <search_text> [oldest_ts] [latest_ts]

# sourceable:
source _slack/webapi.sh
slack-api-post "$CHANNEL_ID" "hello" "$THREAD_TS"
```

- **`post`** — `chat.postMessage`. Omit `thread_ts` for a top-level message,
  pass it to reply inside an existing thread. Prints the raw JSON response;
  read `.ts` from it if the *same process* needs the new message's own ts
  right after posting — a *different, later* process (e.g. tomorrow's ccxp
  tick) can't rely on that ts being handed to it and should rediscover the
  message with `find-by-text` instead.
- **`history`** — `conversations.history`, time-windowed (`oldest`/`latest`
  are Slack ts strings, either bound optional).
- **`thread-replies`** — `conversations.replies`: parent + every reply, for
  a dedup check ("does this thread already have a `*RCA —` reply?") before
  posting a new one — the `slack_read_thread` replacement.
- **`find-by-text`** — the `slack_search_public_and_private` replacement,
  scoped to one channel in a time window: a bot token can't call Slack's
  `search.messages` (user-token-only API), so this fetches `history` and
  filters client-side (`jq`) for a substring in the message text or its
  attachments. Returns a JSON array, `[]` on no match or any API error —
  callers get a clean "nothing found" rather than having to distinguish
  "zero results" from "the call failed."

## Tests

`_slack/webapi.bats` (run with `bats _slack/webapi.bats`, or `bats tests/`
for the whole suite — `tests.yml`'s discovery globs include this path).
