---
status: Done
estimation: 1h
source: /ccxp session 2026-09-11 (01:03Z tick), discovered while verifying the 2026-09-11 retro's Slack post
related: T20260717-433409
claimed_by:
claimed_role:
scheduled: 2026-09-21
---

# T20260910-872316: Retro's Slack summary has no webhook fallback, unlike standup/IPM

## TLDR

- **Type**: bug
- **Problem**: `/retro` Phase 6's Slack summary is a bare `slack_send_message` call with no retry/webhook fallback, unlike `ccxp/SKILL.md` Phase 1.4 (standup) and 2a.6 (IPM) — a weekly, unconditional send that can silently drop.
- **Solution**: port the exact `ccxp/SKILL.md` Phase 1.4 retry-then-webhook-fallback pattern (T20260717-433409) into `retro/SKILL.md` Phase 6, and add a `## Housekeeping` line to the retro report noting which send path succeeded.

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

## Context

- `ccxp/SKILL.md` Phase 1.4 (`ccxp/SKILL.md:422-469`) already implements and
  documents the pattern this task ports: 1 retry on `slack_send_message`,
  then fall back to `SLACK_WEBHOOK_URL_DEV` via `slack/scripts/slack-send.sh`
  (`ccxp/SKILL.md:443`), recording which path succeeded in that day's
  journal's Housekeeping section (`ccxp/SKILL.md:450-452`).
- `ccxp/SKILL.md`'s own "Scope note" (`ccxp/SKILL.md:465-469`) limits the
  fallback to the two *unconditional* cadence sends in that file (standup,
  IPM) — `/retro` Phase 6's weekly summary is the same shape of send but
  lives in a separate skill file, so it was never covered.
- `retro/SKILL.md` Phase 6 (`retro/SKILL.md:516-532`) currently sends via a
  single, unguarded `slack_send_message` call with no retry or fallback.
- `retro/SKILL.md`'s Phase 5 report template (`retro/SKILL.md:437-514`) has
  no `## Housekeeping`-equivalent section today — this task adds one line to
  it, not a new heavyweight section.

## Solution

- Port the `ccxp/SKILL.md` Phase 1.4 retry-then-webhook-fallback block
  (`ccxp/SKILL.md:426-463`) into `retro/SKILL.md` Phase 6, adapted to the
  retro summary text and `RETRO_SLACK_CHANNEL` instead of
  `#claude-notification`:
  1. Attempt `slack_send_message` once, then one retry on error (same
     2-attempts policy as T20260717-433409 — no unbounded retry loop).
  2. On a second failure, fall back to
     `SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL_DEV" bash ../slack/scripts/slack-send.sh "$RETRO_MESSAGE"`.
  3. Record which path succeeded as a one-line addition to the retro
     report — a `## Housekeeping` section (new, appended after `## Prior
     retro follow-up` in the Phase 5 template) with `Posted via MCP` /
     `Posted via webhook fallback — MCP send failed`, mirroring Phase 1.4's
     convention exactly.
  4. If both the MCP send and the webhook fallback fail, that's the
     hard-stop worth flagging loudly in the report — same as Phase 1.4 step
     5.
- **Alternatives rejected**:
  - *Reuse a shared helper function instead of duplicating the retry+
    fallback block* — rejected for this task's scope: `ccxp/SKILL.md`'s
    block is skill-doc prose (not a callable script), and extracting a
    shared bash helper is a larger refactor (`_ipm`/`_session`-style
    extraction) than this 1h bug fix warrants; note it as a possible
    follow-up only if a third cadence-send site appears.
  - *Skip the Housekeeping record and just fix the send* — rejected: Phase
    1.4's own rationale (`ccxp/SKILL.md:450-452`) is that the fallback path
    has known limitations (no message `ts`, generic identity) that should
    stay visible in the durable record; the retro report is the equivalent
    durable record for `/retro`.

## Test plan

- [x] `retro/SKILL.md` Phase 6 documents the same retry-then-webhook-fallback
      structure as `ccxp/SKILL.md` Phase 1.4 (side-by-side read-through —
      this is a skill-doc change, not executable code, so verification is a
      documentation/structure diff, not a test run).
- [x] The new `## Housekeeping` section appears in the Phase 5 report
      template (`retro/SKILL.md`) with both the `Posted via MCP` and
      `Posted via webhook fallback` wording, matching Phase 1.4's exact
      phrasing.
- [x] `_docs/lint-docs.sh retro/SKILL.md` and
      `repo-conventions/scripts/lint_paragraphs.py --changed retro/SKILL.md`
      both pass clean on the changed file.
- [ ] Post-merge: exercised live during the next Friday `/retro` run,
      whichever send path it takes.

## Done criteria

- [x] `/retro`'s Slack-summary step (`retro/SKILL.md` Phase 6) gets the same
      1-retry-then-webhook-fallback pattern as `ccxp/SKILL.md` Phase 1.4 and
      2a.6, reusing `SLACK_WEBHOOK_URL_DEV` + `slack/scripts/slack-send.sh`
      — satisfied by the `retro/SKILL.md` Phase 6 diff in this task's PR.
- [x] On fallback use, the retro doc's own record (a new `## Housekeeping`
      section in the Phase 5 report template) notes which path succeeded,
      mirroring Phase 1.4's "Posted via MCP" vs. "Posted via webhook
      fallback" convention — satisfied by the `retro/SKILL.md` Phase 5
      template diff in this task's PR.

## Closed (2026-09-22)

- Shipped in **PR #66** (`t20260910-872316-slack-webhook-fallback`).
- Both Done criteria met — `retro/SKILL.md` Phase 6 now carries the same
  1-retry-then-webhook-fallback pattern as `ccxp/SKILL.md` Phase 1.4/2a.6,
  and the Phase 5 report template gained a `## Housekeeping` line recording
  which send path succeeded.
- External/unverified: the fallback path itself (webhook send succeeding on
  an MCP failure) is exercised live only the next time a `/retro` run
  actually hits 2 consecutive `slack_send_message` failures — same
  post-merge-only verification posture as the original `ccxp/SKILL.md`
  Phase 1.4 fallback (T20260717-433409) had at its own close.
- No follow-up tasks filed — scope stayed within the 1h estimate.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class change, no
  executable code
- Verification (`superpowers:verification-before-completion`): yes —
  design-score gate (81/100), `lint-docs.sh`, `lint_paragraphs.py`,
  `lint_tasks.py`, and a Done-criteria-to-diff mapping check before PR
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck
- Receiving code review (`superpowers:receiving-code-review`): pending —
  addressed as part of PR #66's `/address-pr` loop
