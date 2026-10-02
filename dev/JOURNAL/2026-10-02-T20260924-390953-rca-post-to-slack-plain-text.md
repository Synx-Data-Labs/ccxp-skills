---
status: Done
estimation: 1
source: memory-to-skill 2026-09-24 (synx-data-labs/build-pipeline-repo)
claimed_by:
claimed_role:
scheduled: 2026-09-28
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

## Investigation (2026-10-02, /drive)

This task was filed 2026-09-24 against `synx-data-labs/build-pipeline-repo`
(a private predecessor repo), citing `grep -i slack rca/SKILL.md` matching
nothing there at the time. By the time this `ccxp-skills` repo's "Initial
public release" was cut (commit `5051a9e3f`, 2026-09-28 — 4 days *after*
this task was filed, and squashed/rewritten history per this repo's own
origin story — see `CLAUDE.md`: "Split from a private company repo"),
`rca/SKILL.md` already carried a `### 5.5 Post to Slack` section
(`rca/SKILL.md:116-120`) that satisfies all three requirements verbatim:

- "Always post... immediately... don't ask 'want me to post to Slack?'
  first" → `rca/SKILL.md:118`: "Immediately post the report to Slack via
  `slack_send_message` — don't ask 'want me to post this?' first; that
  just adds friction and stalls the loop."
- "`#claude-notification` if the primary build-alerts channel is
  inaccessible" → `rca/SKILL.md:118`: "Post to `#claude-notification` (or
  whatever the repo's configured standup/alert channel is — see
  `SLACK_STANDUP_CHANNEL`) if a more specific build-alerts channel isn't
  reachable."
- "plain text / bullet points and bold key-value pairs — never a markdown
  table" → `rca/SKILL.md:120`: "**Plain text, not a markdown table**...
  render it as bold key-value lines / bullets, not a table... Slack does
  not render markdown tables."

Verified via `git log -S"5.5 Post to Slack" --oneline -- rca/SKILL.md`,
which shows the line was already present in the squash commit — no later
commit introduced it. Confirmed `rca/SKILL.md` on `main` at task-pickup
time (`main@625733b`) still has this section, unchanged in substance from
the squash. No code change needed; closing as already-satisfied.

## Closed (2026-10-02)

Already implemented — no PR needed, no code change. `rca/SKILL.md`'s
`### 5.5 Post to Slack` section already matches this task's three
requirements verbatim (see Investigation above): immediate posting (no
confirmation prompt), `#claude-notification` fallback channel, and
plain-text/bullet formatting (no markdown table). This journal-move PR is
the only artifact for this close.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — docs-class, and no
  code change was made (investigation found the work already done)
- Verification (`superpowers:verification-before-completion`): yes — git
  archaeology (`git log -S`) plus a line-by-line requirement match against
  the current `main` confirmed the closure before writing it
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck
- Receiving code review (`superpowers:receiving-code-review`): no — no
  Claude Code review comments (docs-only close, pending this PR's own
  review pass)
