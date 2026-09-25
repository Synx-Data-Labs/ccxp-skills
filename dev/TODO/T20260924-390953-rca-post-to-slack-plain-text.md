---
status: Open
estimation: 1h
source: memory-to-skill 2026-09-24 (synx-data-labs/synxdb-build-pipeline)
---

# T20260924-390953: Amend /rca to post results to Slack automatically, plain text (no tables)

## Problem

- **Type**: feature
- `rca/SKILL.md` today has zero Slack integration — no mention of Slack
  anywhere in the file (verified: `grep -i slack rca/SKILL.md` matches
  nothing).
- This behavior only lived in one user's auto-memory
  (`feedback_rca_always_slack.md`, `feedback_rca_no_tables.md`), not in
  the shared skill, meaning any other session running `/rca` wouldn't
  post results anywhere:
  - Always post the RCA results to Slack immediately after producing
    the report — don't ask "want me to post to Slack?" first (channel
    `#claude-notification` if the primary build-alerts channel is
    inaccessible).
  - Format the RCA summary as plain text / bullet points and bold
    key-value pairs — never a markdown table, since tables don't render
    in Slack.
- `labrun-rca/SKILL.md` (the sibling skill for Slack-sourced alerts)
  already posts via MCP `slack_send_message` in Slack `mrkdwn` — `/rca`
  itself (run directly on a run URL/ID, not from a Slack alert) has no
  equivalent step.

## Notes

- Consider whether to reuse `labrun-rca`'s existing `mrkdwn` formatting
  conventions for consistency, or keep `/rca`'s own formatting simpler
  since it doesn't reply in an existing thread.
