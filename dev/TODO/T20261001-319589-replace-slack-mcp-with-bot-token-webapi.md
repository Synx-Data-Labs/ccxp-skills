---
status: In Progress
estimation: 3
source: User report 2026-10-01 — two labrun Slack alerts (synxdb-build-pipeline
  #C0ALGAPRCA3/p1790829253605319, p1790860307828209) never got an RCA thread
  reply despite the failures being correctly classified and tracked internally
related: T20260724-176269 (prior, "corrected" occurrence of this exact symptom,
  closed 2026-08-17 as a tool-naming mismatch — see Root cause below for why
  that closure doesn't explain the current recurrence)
blocked-by: none (code-side work is NOT blocked; final activation is — see
  "Manual step" below)
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-28
---

# T20261001-319589: retire MCP-based Slack access for ccxp automation — move to a bot-token Web API

## Problem

- **Type**: bug (recurring, now architectural)
- `/ccxp` Phase 1.2.2a (reply RCA in the original `#slack-automation-alerts`
  thread) and `/slack-check-reply`'s maintainer-reply check both depend on
  `mcp__claude_ai_Slack__*` tools (`slack_search_public_and_private`,
  `slack_read_thread`, `slack_send_message`). These are OAuth-connector tools
  that require an interactively-granted session — and are **unavailable in
  cron/headless (`CCXP_CRON_MODE=1`, `-p` mode) sessions**, which is every
  ccxp automation tick.
- Confirmed from `synxdb-build-pipeline`'s `dev/JOURNAL/2026-10-01-daily-summary.md`:
  Slack MCP was unavailable for **4 consecutive ticks in one day**
  (standup, 06:03Z addendum, 15:03Z addendum — PR #3636 — and the prior day
  per "2nd day running" in Housekeeping), each explicitly logging
  "Alert-thread RCA reply (1.2.2a) ... skipped: Slack MCP tools are
  unavailable in this session."
- **User-visible consequence** (what was reported): two real nightly
  failures — `Build SynxDB Cloud Offline Package` nightly #123
  (2026-09-30 23:34 CDT, Phase 800 E2E, <https://synxdatalabs.slack.com/archives/C0ALGAPRCA3/p1790829253605319>)
  and `Upstream Mirror` run 36862058067 (2026-10-01 08:11 CDT,
  <https://synxdatalabs.slack.com/archives/C0ALGAPRCA3/p1790860307828209>) —
  were both internally classified correctly by the nightly health check
  (tasks/links exist: T20261001-497190 for the first; T20260907-214135 /
  T20260917-186533 as known-recurring for the second) but **neither alert
  thread ever got the RCA reply**, so from Slack's perspective they look
  completely unaddressed (only a stray `:eyes:` reaction, no reply).
- **This is a recurrence of [T20260724-176269](https://github.com/Synx-Data-Labs/ccxp-skills/blob/main/dev/JOURNAL/2026-08-16-T20260724-176269-slack-mcp-tools-entirely-unavailable-one-session.md)**,
  which was closed 2026-08-17 as "not an OAuth/headless limitation — just a
  tool-naming mismatch in the `ToolSearch select:` probe query." That
  closure doesn't hold up against the current evidence: neither `ccxp` nor
  `labrun-rca`'s skill files contain any `ToolSearch`/`select:` probe string
  to regress in the first place (grepped both, zero matches) — the 2026-10-01
  sessions simply didn't have the tools available when they tried to call
  them directly. The original (pre-"correction") theory in that task —
  "cron sessions structurally cannot hold an interactively-granted OAuth
  grant" — looks like the real, still-unfixed cause.
- **Decision (made with the maintainer, 2026-10-01)**: stop depending on the
  OAuth-based MCP connector for ccxp automation entirely. Two different
  needs, two different mechanisms:
  1. **One-way notifications** (standup post, hold-tick note, generic
     pings) — already supported today via the existing incoming webhooks
     (`SLACK_WEBHOOK_URL` / `_DEV` / `_RELEASE`, all three already in
     `.env`/`.env.tpl`, 1Password item "SynxDB Build Bot (Slack
     SynxDataLabs)"). No MCP needed for these; keep using the webhook path
     (`/slack` skill) as-is.
  2. **Anything needing read or thread-reply** (1.2.2a's RCA reply,
     `/slack-check-reply`'s maintainer-reply search, `/labrun-rca`'s
     dedup-check + reply) — incoming webhooks structurally cannot do this
     (no read/search API, and the POST response carries no usable `ts` to
     thread off of). These need a **Slack bot token** (`chat:write` +
     `channels:history` + `channels:read` scopes) and the Slack Web API
     (`chat.postMessage`, `conversations.history`, `conversations.replies`)
     called directly via `curl` — no MCP, no OAuth-connector dependency,
     works identically in cron and interactive sessions.
  - Additionally, `synxdb-build-pipeline`'s `.github/workflows/_slack-notify.yml`
    (the workflow that posts the original failure alert) should switch from
    a bare webhook POST to `chat.postMessage` with the same bot token, so
    the alert itself is posted via an API that *could* return a real `ts`
    (useful for debugging/logging even though later retrieval still goes
    through `conversations.history`, since the GH Actions job that posts
    the alert is a different, ephemeral process from the later ccxp tick
    that replies to it — there's no cheap way to hand the `ts` directly
    across that process boundary without adding new persistence, which is
    out of scope here).

## Manual step (blocks activation, not the code-side work)

The Slack App "SynxDB Build Bot (Slack SynxDataLabs)" currently only has
**Incoming Webhooks** configured (verified via `op item get` on the
1Password item — fields are `webhooks configuration` / `slack-automation-alerts`
/ `claude-notification` / `synxdb-cloud`, all type URL; no bot-token field).
Someone with admin access to <https://api.slack.com/apps> for this
workspace needs to, on that existing app:

1. **OAuth & Permissions** → **Bot Token Scopes** → add `chat:write`,
   `channels:history`, `channels:read` (add `groups:history`/`groups:read`
   too if any target channel is private — `#slack-automation-alerts`
   (`C0ALGAPRCA3`), `#claude-notification` (`C0APS68QMND`), and
   `#synxdb-cloud` (`C0AGT86QKMF`) all look public from their `C`-prefixed
   IDs, but confirm).
2. **Reinstall the app** to the workspace (required after adding scopes) —
   this generates/refreshes the **Bot User OAuth Token** (`xoxb-...`).
3. **Invite the bot** to all three channels above (`/invite @SynxDB Build Bot`
   in each, or grant `channels:join` and let the bot self-join public
   channels via `conversations.join`).
4. Copy the Bot User OAuth Token and either hand it to Claude to store, or
   add it directly:
   - 1Password: new field on the same item (e.g. "bot-token"), vault
     `SynxDB Build`, item `tbngljcqu3ck6o44w3ld6ls6bu`.
   - `synxdb-build-pipeline` GitHub Actions secret: `SLACK_BOT_TOKEN` (needed
     by `_slack-notify.yml`).
   - Any repo whose ccxp cron needs read/reply (same secret name,
     `SLACK_BOT_TOKEN`, sourced into `.env` the same way the webhook URLs
     are today).

Until this manual step is done, none of the code below can be activated —
but it can all be written, reviewed, and merged dark (new code paths simply
no-op / fall back when `SLACK_BOT_TOKEN` is unset), so the manual step
doesn't block landing the implementation.

## Done criteria

- [x] A small Slack Web API helper (curl-based, no MCP) added to this repo:
      `_slack/webapi.sh` — `post` (optionally `thread_ts`), `history`
      (time-windowed), `thread-replies` (`conversations.replies`, the
      `slack_read_thread` replacement), and `find-by-text` (history + `jq`
      substring filter, the single-channel `slack_search_public_and_private`
      replacement — a bot token can't call Slack's `search.messages`, that's
      user-token-only). 20 BATS tests (`_slack/webapi.bats`), shellcheck
      clean, wired into `tests.yml`'s bats glob (was missing it — the test
      file alone wouldn't have run in CI otherwise).
- [ ] `ccxp/SKILL.md` rewritten to use the helper instead of
      `mcp__claude_ai_Slack__*` tools. **Scope turned out larger than this
      task's original estimate** — grepping `ccxp/SKILL.md` for MCP Slack
      calls found 7 distinct call sites, not just 1.2.2a:
      - L142 — 1.1#5b mandatory maintainer-reply check (delegates to
        `/slack-check-reply all`, so fixing that skill covers this one)
      - L162, L175 — 1.1a cheap-hold note (search for standup parent +
        threaded reply)
      - L237–251 — **1.2.2a itself** (search alert + dedup-read + reply) —
        the direct cause of the two misses reported 2026-10-01; do this one
        first if doing this incrementally
      - L453–496 — the main standup-message post (already has a webhook
        *send* fallback for T20260717-433409; the search/read side of this
        block still needs the `find-by-text` swap)
      - L721 — `/drive`-inherited escalation protocol
      Recommend doing 1.2.2a (the confirmed-broken one) first as its own
      PR, then the rest as a second pass — not one giant rewrite, so each
      piece can be verified against the real API independently once the
      manual step below is done.
- [ ] `labrun-rca/SKILL.md` steps 2–5 rewritten the same way.
- [ ] `slack-check-reply/SKILL.md`'s maintainer-reply search + standup-thread
      discovery (step 1a) rewritten the same way — note its `from:me` search
      filter has no direct Web API equivalent once posting moves off the
      OAuth-connector identity; `find-by-text`'s text match (e.g. "Daily
      Standup") is the replacement, not a user filter. This skill already
      degrades gracefully today (explicit "skip if `SLACK_STANDUP_CHANNEL`
      unset" path) so it's lower urgency than 1.2.2a.
- [ ] `synxdb-build-pipeline`'s `.github/workflows/_slack-notify.yml` posts
      via `chat.postMessage` (bot token) instead of the bare webhook, with a
      fallback to the existing webhook if `SLACK_BOT_TOKEN` isn't configured
      (keeps the workflow safe to merge before the manual step completes).
- [ ] `dev/SECRETS-ROTATION.md` (both repos, wherever it's duplicated) gets
      a `SLACK_BOT_TOKEN` entry documenting scope, rotation procedure, and
      which channels the bot must stay joined to.
- [ ] Once the manual step is done and the secret is live: verify end-to-end
      on a real (or deliberately triggered) failure — alert posts, a
      subsequent ccxp tick finds it via history-scan, replies in-thread with
      the RCA, and `/slack-check-reply` can find/read a maintainer reply —
      before closing this task.
