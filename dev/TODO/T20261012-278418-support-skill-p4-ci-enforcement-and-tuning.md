---
status: Open
estimation: 1
blocked-by: T20261012-383399
source: this conversation, 2026-10-12 (customer-support skill plan, phase 4 of 4)
---

# T20261012-278418: support skill P4: CI enforcement of the regression-commit rule and cadence tuning

## Problem

- **Type**: feature
- **Note (T20261012-373882, 2026-10-12)**: `/support` was renamed and
  generalized to `/to-task` (generic any-URL intake); the live-reporter
  subcommands this phase tunes (P3's `/support report`/`status`/`stop`) now
  live on `/customer-support` instead — see `T20261012-383399`'s updated
  scope. This phase's own scope (CI enforcement of the regression-commit
  rule, cadence tuning) is unaffected beyond that renaming.
- Requirement (user): support tasks always get a simplified repro and a new e2e regression test, committed together with the fix. P1 enforces it inside `/drive` and `/address-pr`; this phase enforces it in consumer-repo CI and tunes the live reporter from real usage.
- Phase 4 of 4 (last). Ordering: blocked-by `T20261012-383399` (P3: live reporting, which supplies the real-usage data for tuning); also builds on P1 `T20261012-109735` (`check-regression-commit.sh`). Planned size: 3 points (filed at `estimation: 1`; `/incept` revises).
- Scope, CI enforcement:
  - Composite action `actions/support-regression-check`, a wrapper over `_support/check-regression-commit.sh`, for consumer repos' PR checks; non-support PRs skip (detected from branch `t<id>-...` mapped to the task file's `Type: support`).
  - Cross-repo: the check runs in the target clone where the commit lives; the e2e glob is per-target-repo config (`SUPPORT_E2E_GLOB`); the hub task is resolved via `target-repo:`.
  - Exemption path stays the `No-regression-test:` trailer plus explicit approval; the gate fails closed.
  - Workflow snippet in `_support/README.md` (example repo `acme/support-repo`); bats coverage for the action's skip/fail/pass paths.
- Scope, tuning, from the P3 live run:
  - Evaluate noise: new comment vs edit-in-place status board, heartbeat wording, quiet-hours behavior, past-due fallback, cadence thresholds.
  - Apply the decisions to `cadence.sh`/`render-comment.sh` defaults and docs; adjust only what real data supports.
  - Record the outcome (decisions and the observed comment counts per cadence band) in the task's Closed section.
- Done: a support PR lacking fix+e2e test in one commit fails the CI check in a consumer repo, a non-support PR is untouched, and reporter defaults reflect the P3 observations.
- Source plan: scratchpad `support-skill-plan.md`, sections 4, 7 (rollout P4).

## Open questions

- Q9: regression test location/glob and framework for the target product's e2e tests (which repo)? Is a single commit with fix+test truly required even for cross-repo fixes where the test lives in a different repo?
- Q6: hourly cadence in a customer thread: new comment each time vs editing one status-board comment (the P4 noise evaluation decides, subject to the user's preference)?
- Q5: past the due date: stay hourly forever, or fall back to 4h after N hours?
- Q4: quiet hours/weekends for daily and 4h updates (assumed pause; hourly never pauses)?
