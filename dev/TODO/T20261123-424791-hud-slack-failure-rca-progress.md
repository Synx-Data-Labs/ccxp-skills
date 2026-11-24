---
status: Open
estimation: 5
scheduled: 2026-11-23
source: owner message 2026-11-23 (job 1357)
description: Show in the HUD the RCA progress of every failure reported in the Slack alert channel
type: feature
---

# T20261123-424791: HUD shows RCA progress for each failure reported in Slack

## Problem

- **Type**: feature
- Owner (Shine, 2026-11-23): "my expectation is that, we can monitor the 'slack' channel, and make sure, any failure reported will be RCAed, and we should show that progress in the HUD."
- Today the HUD shows only the one configured CI (`ci`) and customer issues. Nothing shows whether each failure announced in the Slack alert channel has an RCA under way or done.

## Design (to settle in /incept)

- Unit: one Slack failure alert (a thread in the alert channel, run id in the message). States: reported, RCA running (a job context file or ledger row carries the run id or thread ts), RCA done (task filed or thread replied), unhandled.
- Source ideas: `agent-pairing/scripts/alerts-due.sh plan` already decides "handled" from the thread reply, a context file or a ledger row; reuse it rather than a second rule. The Slack read stays with the persona (MCP); the HUD reads local state only, so the persona must record each alert it sees (ts, run id, state) in a small local file the HUD polls.
- Cell shape to decide: `RCA 3/5` (done of reported in the last 7 days), red when any alert is unhandled beyond a grace period, with `/hud details` listing them (run id, workflow, state). Ties to the retired unhandled-CI cell (d143): this replaces it for failures that reach Slack.
- Open questions for the owner: which channel(s); how far back; does "RCAed" mean a filed task, a thread reply, or a merged fix.

## Test plan

- [ ] Fake alert file and ledger in bats; model tests for each state and width.
