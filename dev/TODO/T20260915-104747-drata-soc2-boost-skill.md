---
status: Open
estimation: 1w
source: conversation 2026-09-15, driven from synxdb-team T20260418-124634
owner: Xin Zhang (Shine)
---

# T20260915-104747: Build a drata-boost skill — weekly SOC2 compliance-automation driver

## Problem

- synxdb-team's [T20260418-124634](https://github.com/Synx-Data-Labs/synxdb-team/blob/main/dev/TODO/T20260418-124634-drata-soc2-readiness.md)
  drives SOC 2 Type 1 readiness via ad hoc `/drive` sessions and manual Drata
  MCP pulls — there is no repeatable, invocable skill to run a
  compliance-boost iteration on demand or on a cadence.
- Live pull 2026-09-15: 71/256 controls ready (~27.7% all-frameworks); SOC 2's
  own 33 in-scope requirements still 0/33 ready; 33 monitoring tests failing,
  unchanged day-over-day from 2026-09-14.
- Shine's target: **+10% control readiness per week** — nothing today tracks
  week-over-week delta or flags when the pace is behind.
- Of the 33 failing tests, ~19 are AWS infra-hardening findings (S3
  versioning/encryption, VPC flow logs, IAM least-privilege, NACLs/security
  groups, EBS encryption, DynamoDB PITR, Lambda alarms, etc.) — mechanically
  similar to the CPU-alarm fix already landed by hand in T20260418-124634, and
  a strong automation candidate.
- 3 are the GitHub branch-protection gap already root-caused in
  T20260418-124634 (2026-09-14), blocked on choosing a bypass-list identity
  (human account vs. the `claude` GitHub App) — this skill should apply
  whichever gets decided, not make that call itself.
- The remaining ~11 are personnel/policy/training gaps gated on human/HR
  action (contractor onboarding, training completion, policy sign-off) — out
  of scope for automation, but should still be surfaced and tracked.
- No Google Workspace-side compliance automation exists yet at all (MFA
  enforcement, admin config) — greenfield connector work, no existing shared
  lib to build on (unlike `_gh/` for GitHub).

## Scope (decided in-conversation 2026-09-15; full design still lands in `/drive` Phase 2)

- New skill, working name `drata-boost` (open to renaming during design) —
  model + user invocable, per `ccxp-skills:skill-conventions`.
- Pulls live Drata status (controls, SOC 2 requirements, monitoring tests,
  personnel) via the `Drata_*` MCP tools already proven out in this
  conversation and in T20260418-124634.
- Appends a snapshot (date, controls-ready %, SOC2-ready %, failing-test
  count) to a durable log and diffs against the prior run to report progress
  against the 10%/week target — escalates via `/slack` if behind pace.
- Triages every failing test into: **auto-fixable now** (a whitelisted set of
  idempotent AWS hardening fixes), **needs confirmation** (anything touching
  access control — IAM policy, GitHub branch protection, Workspace admin
  roles/MFA), or **needs a human** (personnel/training/contract items — same
  Slack-escalation pattern `/drive` already uses).
- **Safety model (decided 2026-09-15)**: auto-apply only the low-risk
  whitelist (versioning/encryption/logging/alarm-type fixes); anything
  touching access control always stops and shows the exact diff/CLI/API call
  for an explicit go-ahead before applying.
- Connectors: AWS (`aws` CLI, same `synx-mgmt` profile as
  [T20260914-219969](https://github.com/Synx-Data-Labs/synxdb-team/blob/main/dev/TODO/T20260914-219969-aws-sso-refresh-synx-mgmt.md)),
  GitHub (`_gh/gh.sh` + branch-protection API), Google Workspace (Admin SDK —
  net-new, no existing lib; flag as the least-mature connector for v1).
- Records progress back into synxdb-team's T20260418-124634 journal (or a
  dedicated compliance-progress log) each run.

## Test plan

- [ ] Skill authored per `superpowers:writing-skills` (RED baseline run
  without the skill, GREEN with it, REFACTOR closed loopholes) +
  `ccxp-skills:skill-conventions`
- [ ] A dry run against live Drata data reproduces this conversation's
  2026-09-15 numbers (71/256 controls, 0/33 SOC2, 33 failing tests)
- [ ] At least one AWS whitelist fix applied end-to-end and re-verified
  against a subsequent Drata sync
- [ ] A confirmation gate is demonstrated on an access-control-class fix
  (does not auto-apply)
- [ ] A progress snapshot is written and diffed against a prior run

## Done criteria

- [ ] Skill merged to `ccxp-skills` main, invocable (e.g. `/drata-boost`)
- [ ] First live run against SynxDB's Drata workspace produces a triage
  report plus at least one applied whitelist fix
- [ ] Weekly delta tracking wired, even with only one data point at merge
  time
