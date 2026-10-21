---
status: Design
estimation: 1
source: this conversation, 2026-10-21 (user request)
related: T20261012-373882
claimed_by: cc1-50ac6891:aa0777f53e013582
claimed_role: interactive
scheduled: 2026-10-19
---

# T20261021-266225: customer-support lifecycle: rename labels (accepted->triaged, triage->new) and auto-close delivered issues after 14 days

## Problem

- **Type**: feature
- **A. Label rename** (user renamed the live labels): `accepted` -> `triaged`, `triage` -> `new`.
  - Verified 2026-10-21 via `gh label list --repo Synx-Data-Labs/synxdb-support`: `new`, `in-progress`, `triaged`, `blocked`, `needs-upstream`, `delivered` exist; `triage` and `accepted` do not.
  - Old names still hardcoded in `customer-support/SKILL.md:13`, `customer-support/scripts/{labels,audit}.sh` (`CS_PRIMARY_LABELS`), `state_machine.sh`, `transition.sh`, and `tests/customer_support_{audit,labels,transition}.bats`.
  - The `triage` subcommand keeps its name (it is the verb) but now moves `new` -> `triaged`.
  - Readers (audit, state machine) must alias old names to new so stale issues do not trip `audit`.
  - Do not rename the support-team `accept` subcommand (delivered -> closed).
  - Follow-up scan of synxdb-build-pipeline (read-only): no label-name references found, only `/customer-support` mentions in its task files; nothing to edit there.
- **B. Delivered timeout**: an issue in `delivered` for 14 days with no rejection is closed (completed) with an explanatory comment; support team or customer can reopen via the existing `start` revert path (`delivered -> in-progress`).
  - Clock starts when the `delivered` label was applied (issue timeline events API).
  - Skip `blocked` / `needs-upstream`; skip and flag issues with a comment from anyone other than the delivering account after delivery.
  - Idempotent; default dry-run, `--apply` to act; `--days` default 14.
  - New `sweep` subcommand through `transition.sh`, clearly distinct from identity-gated `accept` (marked close, comment prefix, not an acceptance).
  - Design PR decides whether a cron workflow calls it; otherwise file a follow-up task.
  - Update `SKILL.md`, lifecycle docs, and design reference T20261012-373882.
- Constraints: dry-run only against real issues (expect roughly #30, #32, #33 to be reported); no real issue is closed or relabelled; no Slack steps (escalations recorded in this file).
