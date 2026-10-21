### E1 — Customer support skill

Goal: customer-reported GitHub issues get intake into a `support` task type, status updates with an ETA (daily, 4h, hourly near the due date), and a simplified repro plus an e2e regression test committed with the fix
Done when: every member below is closed (in `dev/JOURNAL/`) and open questions Q1-Q11 are answered in their owning member

Migrated from the task-form epic T20261012-333879 (maintainer decision 2026-10-21). Phases P1-P4 are T20261012-109735, T20261012-949870, T20261012-383399, T20261012-278418 (chain P1 -> P2 -> P3 -> P4); the rest is customer-support work done or in flight around them. Open questions, each answered in the owning member's Closed section: Q1 tone/approval, Q2 deadline format, Q3 opt-in storage, Q4 quiet hours, Q5 past-due cadence, Q6 hourly comment style, Q7 who posts, Q8 engine host, Q9 e2e test location, Q10 due-date source, Q11 Slack mirroring. Cross-repo reference only: T20261012-612044 (reconcile close-support-issue) lives in synxdb-build-pipeline and is not a member.

- [T20261012-109735](../JOURNAL/2026-10-12-T20261012-109735-support-skill-p1-intake-and-gates.md) — P1: intake, `support` task type, lint keys, gates
- [T20261012-949870](../TODO/T20261012-949870-support-skill-p2-reporter-dry-run.md) — P2: status reporter engine in dry-run
- [T20261012-383399](../TODO/T20261012-383399-support-skill-p3-live-reporting.md) — P3: live reporting
- [T20261012-278418](../TODO/T20261012-278418-support-skill-p4-ci-enforcement-and-tuning.md) — P4: CI enforcement and cadence tuning
- [T20261012-373882](../JOURNAL/2026-10-12-T20261012-373882-support-status-label-lifecycle-design.md) — status label lifecycle design
- [T20261019-181127](../JOURNAL/2026-10-19-T20261019-181127-triage-accept-no-tracking-link-comment.md) — triage tracking-link comment
- [T20261020-131330](../TODO/T20261020-131330-customer-support-skill-automate-full-support-issue-lifecycle.md) — orchestrator (absorbed T20261019-311265)
- [T20261021-266225](../JOURNAL/2026-10-21-T20261021-266225-customer-support-lifecycle-rename-labels-and-delivered-autoclose.md) — label rename and 14-day delivered auto-close
- [T20261021-332125](../JOURNAL/2026-10-21-T20261021-332125-customer-support-deliver-clickable-links.md) — clickable download links
- [T20261021-291375](../TODO/T20261021-291375-schedule-delivered-autoclose-sweep-synxdb-support.md) — schedule the delivered auto-close sweep
- [T20261021-289402](../TODO/T20261021-289402-customer-support-triage-tracking-comment-full-url.md) — triage tracking comment carries a full clickable URL (in flight, PR #403 claim)
