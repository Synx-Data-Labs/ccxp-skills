---
name: email-triage
description: Use when the user explicitly asks to triage the Gmail inbox — summarize, surface the top action item, Slack the result
disable-model-invocation: false
argument-hint: "[--window 7d] [--no-slack]"
---

Daily email triage: read the inbox, separate notifications from action items, summarize the notifications, surface the single most important action item, and Slack the result.

## Mental model

```
                   ┌────────────────────────────────────┐
in:inbox last N ─► │ Classify each thread:              │
                   │   • notification (auto/bot/list)   │ ──► summarize → digest
                   │   • actionable (human, deadline,   │ ──► rank → top 1
                   │     financial, @-mention, etc.)    │
                   └────────────────────────────────────┘
                                   │
                                   ▼
                   Slack: digest + top-1 action item
                                   │
                                   ▼
                   User decides what to archive / reply / act on
```

The skill is **read-only** on Gmail. Cleanup (archive, label, reply) is the user's job.

## Argument

`$ARGUMENTS` is optional:

- `/email-triage` — default: 7d window, Slack the result
- `/email-triage --window 24h` — narrower window
- `/email-triage --window 14d` — wider sweep
- `/email-triage --no-slack` — print to user only (dry-run / debug)

## Prerequisites

- Gmail MCP server connected with **read scope** (`search_threads`, `get_thread`, `list_labels`)
- Slack MCP server connected with `slack_send_message` (DMs to user)
- The user's Slack user ID is known (the tool description usually surfaces it; otherwise use `slack_search_users`)

## Workflow

### Phase 1: Pull inbox

Search: `in:inbox newer_than:7d` (or `--window`). Walk the thread list; keep sender, subject, date, snippet, recipient list.

### Phase 2: Classify each thread

For each thread, decide **notification** vs **actionable** using these signals:

**Notification (low-attention):**

- Sender contains `noreply`, `no-reply`, `notifications`, `notification`, `automated`, `donotreply`
- Sender is a known automated address pattern (e.g. `notifications@<service>`, `git@<host>`, `*@notification.<service>`, support tickets in informational mode, marketplace event emails, event platform notifications, newsletter senders matching `*@info.*` or similar)
- Subject is auto-generated (e.g., contains repository/PR templates, bracketed prefixes, "agreement", "offer accepted", "payment success")
- `to:` is a mailing list (e.g. ASF lists, GitHub subscription addresses)
- Marketing keywords: `newsletter`, `unsubscribe`, `webinar`, generic cold-outreach phrasings (heuristic)

**Actionable (everything else):**

- Real human sender (firstname.lastname@company.com style)
- Direct `to:` includes user only
- Subject implies action: `invoice`, `due`, `deadline`, `expir`, `urgent`, `please review`, `approve`, `sign`, `confirm`, money/currency mentions
- Active reply thread the user is participating in

Edge cases — keep in mind:

- A vendor support address often mixes informational ("scheduled on <date>") and actionable ("ticket update / Re:"). Look at subject — payment-scheduled / debited subjects are informational; ticket replies are actionable.
- Recurring balance / cash-flow reminders configured by the user are typically **actionable** even though the sender is automated. When the skill repeatedly demotes such reminders incorrectly, add an explicit rule.

When uncertain, default to **actionable** (false positives are cheap; missed action items are expensive).

### Phase 3: Summarize notifications

Group by sender domain or category. For each group, list 1 line per thread:

```
*Email digest — last 7d* (N notification threads)

*<group A>* (count)
- <subject snippet> — <1-line gist>
- ...

*<group B>* (count) — <one-line summary if homogeneous>

*<group C>* (count)
- <subject snippet> — <1-line gist>
```

Aim for short. The user shouldn't have to expand the digest to know nothing is on fire.

### Phase 4: Rank actionable items

For each actionable thread, score additively:

| Signal | Points |
|--------|--------|
| Sender is a real human (not bot/noreply/notifications) | +3 |
| Subject contains money pattern (`$`, USD, CNY, RMB, "invoice", "debit") | +2 |
| Subject contains time pressure ("due", "deadline", "expir", "urgent", "EOD", date in next 7d) | +2 |
| `to:` is `me` only (not a list) | +1 |
| Newer than 24h | +1 |
| Sender is on a user-configured "key contacts" list (cofounders, partners, etc.) — list lives outside the skill | +2 |
| Older than half the window (e.g. >3.5d in default 7d run) | -1 |
| Already replied to (you're in the thread, last message is from you) | -1 |

Sort desc, ties broken by recency.

### Phase 5: Top-1 detail

For the #1 ranked thread, optionally `get_thread` to read the body and produce a real summary:

- 2-3 sentence "what this is about"
- Suggested action (1 line: "Reply to X", "Approve in Y", "Pay Z by D", etc.)
- Direct link: `https://mail.google.com/mail/u/0/#inbox/<threadId>`

Cap deep reads at 3 per run (top-1 + maybe top-2/top-3 if score is close, for context).

### Phase 6: Output

To the user (always):

```
🔝 Top action item:
   <subject>
   from <sender>, <age>
   <2-3 sentence summary>
   Action: <suggested action>
   Link: <gmail url>

📬 Digest:
   (summarized notification groups)
```

To Slack (unless `--no-slack`), **DM the user directly** — never a public channel:

```
slack_send_message(channel_id=<dm_or_user_id>, message=<below>)
```

`channel_id` for a DM should be a DM conversation ID (typically `D...`). Two ways to obtain it:

1. **Reuse a known DM channel ID** — if the user has previously DM'd the bot, the `D...` ID is stable and can be cached in the user's environment.
2. **Pass the user ID directly** — Slack's `chat.postMessage` API auto-opens an IM when given a user ID (`U...`), and most Slack MCP wrappers pass this through. If `slack_send_message` rejects a `U...` ID, fall back to looking up / opening the DM channel via the MCP (e.g. `slack_search_users` to find the user, then use a conversations-open call if exposed).

The MCP tool description often surfaces the logged-in user's ID. Do **not** use the `slack` webhook skill here — webhooks are bound to a public channel.

```
*Email triage — last 7d*

🔝 *Top action:* <subject> — <action> — <gmail url>

📬 *Digest:*
*<group A>* (count) — ...
*<group B>* (count) — ...
...
```

## Cron (optional)

Run daily via the `schedule` skill:

```
/schedule daily 08:00 /email-triage
```

## Notes

- **Read-only by design.** This skill never archives, labels, or replies. The Anthropic Gmail connector is read-only as of writing — and that's fine: the user decides what to do with each item.
- **Top-1 is a recommendation.** The user decides whether to act, snooze, or override.
- **Digest grouping is sender-domain based** for resilience — new senders still group sensibly.
- **No deep reads outside top-3.** Phase 1–4 use thread snippets only (cheap). Phase 5 reads up to 3 full threads.
- **The score weights are tunable.** If wrong things keep surfacing, edit the points table. Promote categories the user keeps acting on; demote ones they keep ignoring.
- **Classification is heuristic, not rules-based.** When in doubt, default to actionable.
- **Do not embed user-specific data in this file.** Names, dollar amounts, thresholds, vendor identities, real subjects/senders all belong in the user's environment or a private companion config — not in the shared skill.
