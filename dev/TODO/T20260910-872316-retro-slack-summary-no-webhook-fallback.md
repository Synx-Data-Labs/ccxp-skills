---
status: Coding — Design approved in-conversation 2026-09-22 (self-evident, mirrors ccxp/SKILL.md Phase 1.4/2a.6 pattern)
estimation: 1h
source: /ccxp session 2026-09-11 (01:03Z tick), discovered while verifying the 2026-09-11 retro's Slack post
related: T20260717-433409
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260910-872316: Retro's Slack summary has no webhook fallback, unlike standup/IPM

## Problem

- `ccxp/SKILL.md` Phase 1.4 (daily standup) and Phase 2a.6 (Monday IPM) both
  document a documented retry-then-webhook-fallback for `slack_send_message`
  (1 retry, then `SLACK_WEBHOOK_URL_DEV` via `slack/scripts/slack-send.sh`),
  per T20260717-433409. Phase 2b (Friday retro, delegated to `/retro`) has no
  equivalent — its Slack-summary step is a bare `slack_send_message` call with
  no retry or fallback wired in.
- The 2026-09-11 retro (a downstream consumer repo's build-pipeline PR) hit
  this gap directly:
  the retro doc committed cleanly, but its Slack summary never posted. Only
  caught because the next hourly tick's mandatory `/slack-check-reply all`
  re-read the standup thread and found no matching "Weekly Retro" post; sent
  manually via the webhook fallback after 2 consecutive MCP
  `slack_send_message` Internal Server Error failures (the same chronic
  intermittent-500 class T20260717-433409/`reference_slack_send_mcp_intermittent_500`
  already documents for the daily/weekly sends).
- `ccxp/SKILL.md`'s own "Scope note" under Phase 1.4 explicitly limits the
  fallback to "the two sends in this file that fire unconditionally on their
  cadence (daily / weekly)" — Phase 2b's retro summary is exactly such an
  unconditional weekly send, but it lives in the separate `/retro` skill, so
  it was never included when that fallback was added.

## Done criteria

- `/retro`'s Slack-summary step (its own SKILL.md, not `ccxp/SKILL.md`) gets
  the same 1-retry-then-webhook-fallback pattern as `ccxp/SKILL.md` Phase 1.4
  and 2a.6, reusing `SLACK_WEBHOOK_URL_DEV` + `slack/scripts/slack-send.sh`.
- On fallback use, the retro doc's own record (e.g. a `## Housekeeping` or
  equivalent line) notes which path succeeded, mirroring Phase 1.4's
  "Posted via MCP" vs. "Posted via webhook fallback" convention.
