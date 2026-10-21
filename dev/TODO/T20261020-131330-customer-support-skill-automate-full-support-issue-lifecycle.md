---
status: Open
estimation: 1
source: this conversation, 2026-10-20 (user: "refactor the skill to automate the entire lifecycle of addressing the customer issue from triage to deliver")
related: [T20261012-333879, T20261012-373882]
description: Orchestrating flow that drives a synxdb-support issue end to end, triage through deliver
---

# T20261020-131330: customer-support skill: automate the full lifecycle of a support issue (triage -> deliver)

## Problem

- **Type**: feature
- Part of epic T20261012-333879 (customer support skill track P1-P4); builds on T20261012-373882 (label lifecycle). `/customer-support` shipped in [PR #346](https://github.com/Synx-Data-Labs/ccxp-skills/pull/346); [PR #369](https://github.com/Synx-Data-Labs/ccxp-skills/pull/369) added the triage tracking-link comment and `--task`. Relates to T20261012-612044 in synxdb-build-pipeline (reconcile close-support-issue).
- Today each `/customer-support` subcommand (triage, start, deliver, links, request-confirm, accept, reject, block, needs-upstream) moves one step. The engineer chains them by hand and separately creates the task, claims, builds, verifies and publishes.
- Goal: given a support issue URL, one flow drives it end to end:
  - triage, create or link the backing task via `/new-task`, post the `--task` tracking comment
  - start (claim + label in-progress), then drive the task (e.g. `/drive`), including builds and releases when the issue is a package request
  - run the evidence gate (links/verify), deliver (label `delivered` + links comment), request-confirm
  - automatic blocked / needs-upstream handling, plus status reporting

## Design requirements (hard constraints)

- `accept` stays support-team-only and identity-gated; never automated.
- `deliver` stays evidence-gated, never self-reported (regression case: synxdb-support#21).
- Secrets (entitlement tokens, 1Password API keys via `op run`) are never printed, posted, or put on command lines.
- Real builds, promotions and publishes need explicit human consent per issue (consent checkpoint), and a dry-run first.
- Idempotent and resumable: re-entering resumes at the current label.
- All label writes go through `transition.sh`.

## Open questions

- Where does the orchestrator live: new subcommand (`run` / `auto`) or a new skill?
- How are long builds dispatched and awaited: background jobs or scheduled wakeups?
- How is consent captured (per issue, per action, expiry)?
- How is ETA reported (see `/eta`)?
- Cross-repo handling: hub synxdb-build-pipeline vs ccxp-skills.
- First real exercise: synxdb-support#30 (4.8.1 for i2c, delivered via manual chaining today) and #32 (PXF 4.5.4-3, T20261020-247249).

## Done criteria

- Design doc.
- Implementation with bats tests, including gate-bypass regression tests (`accept` identity gate, `deliver` evidence gate, synxdb-support#21 case).
- Dry-run on a test issue.
- One real issue driven end to end.
