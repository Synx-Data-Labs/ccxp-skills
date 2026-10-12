---
status: Open
estimation: 1
blocked-by: T20261012-949870
blocks: [T20261012-278418]
source: this conversation, 2026-10-12 (customer-support skill plan, phase 3 of 4)
---

# T20261012-383399: support skill P3: live reporting (manual-approved one-shot, then scheduled tick on one real task)

## Problem

- **Type**: feature
- Requirement (user): daily status updates to the customer issue with progress and ETA, tightening to 4-hourly and hourly as a due date nears. P2 built the engine in dry-run; this phase makes it post for real, with a human in the loop first.
- Phase 3 of 4. Ordering: blocked-by `T20261012-949870` (P2: cadence, renderer, marker, tick in dry-run); blocks P4 `T20261012-278418`. Planned size: 3 points (filed at `estimation: 1`; `/incept` revises).
- Scope, manual path:
  - `/support-report` skill (thin, `disable-model-invocation: true`): the reporter tick for every open support task, also runnable by hand.
  - `/support report T<id>` one-shot post, `/support status [T<id>]`, `/support stop T<id>`.
  - First comment for a task is human-reviewed: show the rendered draft, user approves (y/edit/n) before the first post and before enabling automatic ticks; later ticks are templated-only.
  - Consent at intake: prints "Report cadence will post to <url> as <account>. Enable? (y/N)" and records `support-report: on` only on yes.
  - On task Done: one final "resolved, pending your confirmation" comment (marker `final`), then stop.
- Scope, scheduled path:
  - Composite action `actions/support-report` (shape of `actions/slack-send`) wrapping `_support/tick.sh`, with a consumer-repo workflow snippet in `_support/README.md` (`schedule: "7 * * * *"`, `workflow_dispatch`, `concurrency: group: support-report`, `actions/checkout` of the hub repo, settings as Actions `vars`/`secrets`; examples use `acme/support-repo`). Local launchd/cron calling the same `tick.sh` documented as the alternative.
  - Posting identity, internal Slack audit/escalation note via `slack-send.sh --channel $SUPPORT_SLACK_CHANNEL`, transition notice when cadence tightens ("moving to more frequent updates"), `SUPPORT_DRY_RUN` kill switch and `support:paused` label honored.
  - Enable the scheduled tick on ONE real, opted-in task first and observe it for a few days before wider use.
- Safeguards (outward-facing, hard to reverse): opt-in per task, default off; deny-list lint aborts a post and alerts the owner; per-failure-class daily alert, no hot-loop retries.
- Evals: `evals/evals.json` for the prose parts of `/support` and `/support-report` (skill-conventions section 5).
- Done: one real support issue receives correct, deduplicated updates at the right cadence with no manual intervention, and the first comment was human-approved.
- Source plan: scratchpad `support-skill-plan.md`, sections 2.3, 3.2, 3.6, 6, 7.

## Open questions

- Q7: who posts: a personal gh account, or a bot/GitHub App (`_gh/gh-app-token.sh`)? Does the support repo permit a bot? Is the repo public to customers or private per customer?
- Q8: engine: GitHub Actions in the hub repo (recommended) vs local launchd/cron? Which repo hosts the workflow and holds the task files?
- Q1: customer-facing language and tone: English only? Who approves the template wording (assumed: the user, once, at this phase)?
- Q3: opt-in storage: `support-report: on` frontmatter key (assumed) vs a separate config file?
- Q11: should internal Slack mirror every customer post, or only escalations?
- Q6: new comment each time vs editing one status-board comment at hourly cadence (affects what the one-shot and tick post)?
