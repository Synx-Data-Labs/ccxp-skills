---
status: Open
estimation: 1
source: design review of T20261020-131330, 2026-10-28 (maintainer approved filing it)
related: [T20261020-131330]
description: `transition.sh triage --task` posts an internal task ID, hub repo path and task title into a customer-readable issue comment
---

# T20261028-392844: triage --task posts internal task ID/hub path/title into a customer-visible issue comment

## Problem

- **Type**: bug
- `/customer-support triage <issue> --task <repo>#T<id>` (added in [PR #369](https://github.com/Synx-Data-Labs/ccxp-skills/pull/369)) posts `Tracked internally as [<ref>](<url>) — <title>` plus the bare permalink (`customer-support/scripts/transition.sh`, `triage|start|request-confirm` branch; format documented in `customer-support/SKILL.md` "Tracking comment").
- The synxdb-support issues are readable by the reporting customer, so the comment exposes:
  - the internal task ID (`T<yyyymmdd>-<nnnnnn>`)
  - the hub repo and file path inside the permalink
  - the task title, which is frequently customer-bearing (names the customer or their environment)
- Expected behavior: a customer-readable issue never receives an internal ID, hub path or task title unless the repo is confirmed internal-only.
- Reproduction expectation (BATS, stubbed `gh`):
  - run `transition.sh triage <owner/repo> <n> --task <repo>#T<id>` against a stubbed task whose title contains a customer name
  - capture the `gh issue comment` body; today it contains the task ID, the permalink path and the title
  - assert the fixed behavior below (fails on current main)

## Fix direction

- **Option A (preferred): private link**. Default to no tracking comment; record the link in the hub task file (`source-url:`) only. Add an explicit opt-in flag (e.g. `--task-comment`) for repos confirmed internal-only.
- **Option B**: keep the comment but make it opt-in only and run the customer-text deny-list lint (task IDs, customer names, internal paths) on it before posting; fail closed on a hit.
- Either way: add `--no-task-comment`/opt-in semantics to `transition.sh triage`, keep the label move independent of the comment, update `SKILL.md` "Tracking comment", and add BATS covering default, opt-in and lint-fail paths.
- Consider whether existing comments already posted on synxdb-support issues need a manual edit (maintainer decision; do not mass-edit from a script).
- `T20261020-131330` (`/customer-support run`) depends on the default-off behavior (`run` always skips this comment); sequencing is free, either can land first.
