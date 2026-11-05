---
estimation: 1
status: In Progress
source: Owner chat 2026-11-03
description: Raise the autopilot defaults (merge cap 64, cycle cap 64, idle retry 32 min, max visits 4) and ship /autopilot config in a release
claimed_by: cc1-50ac6891:42c26fb875d726e0
claimed_role: interactive
scheduled: 2026-11-02
---

# T20261103-169088: Add /autopilot config and raise autopilot default caps

## Problem

- **Type**: feature
- Owner request, verbatim: "in ccxp-repo skills, let's create a new task to add the \"/autopilot config\" to it, and also, let's update the default for the cap, e.g. daily_merge_cap: 64, daily_cycle_cap: 64, idle_retry_minutes: 32, max_visits: 4"
- The `/autopilot config` subcommand (`config-show`, `config-set`, `config-reset`) was already implemented and merged in [PR #558](https://github.com/Synx-Data-Labs/ccxp-skills/pull/558) with no version bump.
  - It is not in an installed release yet: a 5.10.0 session rejects `/autopilot config` as unsupported.
  - Reaching users needs a release (version bump PR, tag) and then `/plugin update`.

## New defaults

| Key | Old | New | Bounds |
|---|---|---|---|
| `daily_merge_cap` | 12 | 64 | 1-1000 |
| `daily_cycle_cap` | 24 | 64 | 1-1000 |
| `idle_retry_minutes` | 45 | 32 | 30-60 |
| `max_visits` | 3 | 4 | 1-20 |

## Done when

- [x] Defaults changed in `autopilot/scripts/autopilot-state.sh` (cap check, `delay idle`, visit limit, `config-show` table, comments).
- [x] `autopilot/SKILL.md` prose and the config JSON example state the new defaults.
- [x] `tests/autopilot_state.bats` asserts the new defaults; the suite passes.
- [ ] Maintainer step (separate PR, not part of this task's code change): bump the plugin version (MINOR: new subcommand), `claude plugin validate .` with zero warnings, tag, then `/plugin update` so `/autopilot config` works in installed sessions.
