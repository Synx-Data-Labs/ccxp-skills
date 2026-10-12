---
status: Open
estimation: 1
blocked-by: T20261012-109735
blocks: [T20261012-383399]
source: this conversation, 2026-10-12 (customer-support skill plan, phase 2 of 4)
---

# T20261012-949870: support skill P2: status reporter engine in dry-run (cadence, renderer, marker, tick)

## Problem

- **Type**: feature
- Requirement (user): a daily status update to the customer issue with progress and ETA; when a due date exists, report every 4 hours within 3 days and hourly within 24 hours.
- Phase 2 of 4. Ordering: blocked-by `T20261012-109735` (P1: intake, `support-issue` key, lint allowlist); blocks P3 `T20261012-383399`. Planned size: 5 points (filed at `estimation: 1`; `/incept` revises). Riskiest phase (dedup, scheduler semantics): expect an extra review round.
- Nothing is posted to any issue in this phase: everything runs with `SUPPORT_DRY_RUN=1`, printing what would post, and is exercised against a sandbox repo issue.
- Scope, pure logic:
  - `_support/cadence.sh`: pure function of (now, deadline, last report, status) to interval or `stop`. No deadline or over 72h: daily; 24h to 72h: 4h; within 24h: hourly; past due: hourly with "Past target date" copy (see Q5). Thresholds env-tunable (`SUPPORT_REPORT_{DAILY,NEAR,URGENT}_H`, `SUPPORT_NEAR_WINDOW_H`, `SUPPORT_URGENT_WINDOW_H`); due iff `now - last >= interval - 5min`. "Daily" means once per calendar day in `SUPPORT_TZ` at or after `SUPPORT_DAILY_AT`. Immediate post on meaningful state change regardless of cadence. A date-only deadline means end of that day local time.
  - `_support/render-comment.sh`: whitelisted fields only (mapped status phrase, bullets from `## Customer summary`, ETA band, next-update time); status-mapping table; deny-list lint on rendered text (task IDs, `/Users/`, IPs, tokens, `SUPPORT_DENY_REGEX`) aborts the post.
  - ETA: points times `hours_per_point` via the existing `eta/scripts/eta.sh`, shown as a band, never a promise; before claim: "triage pending", no numeric ETA.
  - `_support/marker.sh`: hidden marker `<!-- ccxp-support:T<id>:<ts>:<seq>:<hash> -->`, last-report time derived from the newest marker comment by `SUPPORT_BOT_LOGIN` (state lives in the issue, not the task file).
- Scope, engine:
  - `_support/tick.sh`: idempotent, read-only on the repo, per-task isolation (`|| continue`), fresh re-read of comments before posting, no-news hourly heartbeat, stop conditions (issue closed, task moved to JOURNAL, `support:paused` label, not opted in via `support-report`, dry run).
  - Failure handling: auth/403/rate-limit/deleted issue logged, no hot-loop retry; a late tick catches up with ONE comment; DST-safe (UTC math, `SUPPORT_TZ` for display).
- Scope, tests (bats): `support_cadence` (every threshold edge, 72h/24h boundaries, DST, past-due, no-deadline, quiet hours), `support_render` (whitelist plus deny-list), `support_marker_dedup` (stub `gh`: two ticks yield one post); extend `_support/README.md` with the env-var table.
- Done: `tick.sh` in dry-run against a sandbox issue prints the correct due/not-due decision and rendered comment for each cadence band, and never posts.
- Source plan: scratchpad `support-skill-plan.md`, sections 3, 5, 6, 7.

## Open questions

- Q4: quiet hours/weekends: should daily and 4h updates pause overnight and on weekends (assumed yes), with hourly never pausing (assumed)?
- Q5: past the due date: stay hourly forever, or fall back to 4h after N hours (assumed: hourly for 24h, then 4h)?
- Q6: hourly cadence in a customer thread: a new comment each time vs editing one "status board" comment (recommended: edit plus heartbeat, new comment on state change and at daily cadence)?
- Q2: is `deadline:` date-only enough, or is a time plus timezone needed? Hourly bands near the deadline may need one.
- Q1: customer-facing language and tone: English only? Who approves the template wording?
- Q11: should internal Slack mirror every customer post, or only escalations (past due, at risk, failures)?
