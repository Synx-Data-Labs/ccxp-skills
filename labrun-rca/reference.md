# labrun-rca reference

Detail moved out of SKILL.md to keep its context budget (the skill-quality ratchet).

## Edge cases

| Situation | Handling |
|-----------|----------|
| Malformed URL (no `/archives/…/p…`) | `labrun.sh input` (or `parse`) exits 2 — fail fast, print the URL format expected |
| Private channel the user can't see | `slack_read_thread` will error — surface the error verbatim |
| Message already has thread replies | `thread-state` `done` (a reply starts with `*RCA`) or `wait` (fresh ack only): stop; `continue`: proceed (step 2) |
| Notification message has no run ID | Post a short "needs manual RCA input" thread reply and stop |
| Run succeeded on retry before RCA ran, or the alert is a success/recovered/other-branch post | `alert-kind` exits 9 (no failure signal, success/recovered wording or other branch): no thread reply; report `not a failure alert` to the caller |
| `/rca` itself errors (e.g., run not accessible) | Post the error verbatim to the thread so the channel isn't left hanging |

## Reuse from existing skills

- `/rca` — all the analysis, classification, and task-creation logic. Do not duplicate it here.
- `/slack` — used today only for fire-and-forget webhook announcements; this skill intentionally bypasses the webhook path in favor of MCP so it can target a specific thread.
- `/slack-check-reply` — reference for the Slack thread state pattern (`.claude/state/drive-threads.json`). labrun-rca does _not_ write to that file; drive-threads is escalations-from-Claude, labrun-rca reacts to alerts-to-Claude.
- `/drive` — uses MCP `slack_send_message` the same way; same channel_id/message_ts conventions apply.
- `/ccxp` Phase 1.2.2a — runs this exact reply behavior automatically every standup tick, for every failure `/rca` classifies during the nightly health check, by searching for the matching alert instead of starting from a copy-pasted permalink (it has a run ID, not a URL). Reuses this skill's Step 5 reply format so both entry points read identically. Invoke `labrun-rca` directly only for ad-hoc cases 1.2.2a won't cover: a failure outside last night's window, or a channel/workflow the automated search didn't match.
