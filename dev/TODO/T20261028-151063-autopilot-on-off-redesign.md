---
status: Design
estimation: 5
source: Conversation 2026-10-28 (user spec for the /autopilot redesign)
description: Redesign /autopilot as on/off/pause/resume/status with no duration; loops /drive until off, notifies once when idle
claimed_by: cc1-50ac6891:628a122d26bbecbf
claimed_role: interactive
scheduled: 2026-10-26
---

# T20261028-151063: Redesign /autopilot as an on/off background /drive loop

## TLDR

- **Type**: feature
- **Problem**: `/autopilot <duration>` is time-boxed and stops on `elapsed` or `queue-empty`; the user wants a switch that keeps `/drive` running in the background until turned off
- **Solution**: `/autopilot on|off|pause|resume|status` only; a state-file-backed ScheduleWakeup loop with idle notify-once, eligibility guardrails, a daily soft cap and a Slack-or-fallback notifier
- **Verification**: logic lives in `autopilot/scripts/autopilot-state.sh` with BATS tests; `/autopilot on` is never started for real

## Problem

- Current argument grammar is `<duration> | status | pause [--now] | resume | stop [--now]` (`autopilot/SKILL.md:4`); the run ends at `elapsed` (Phase 2) or `queue-empty` (Phase 4, "a stop, not a backoff case")
- The wake prompt carries control values: `/autopilot until <ISO> stuck=<n>` (Phase 1, Phase 4); a duration-less loop has no use for `end_time`
- The HUD reads `end_time`/`started_at` to print `AP running 2/6h` (`hud/scripts/hud-lib.sh:255-304`, `hud/model.ts:217-232`); both must survive the new states
- User ask (2026-10-28): keep `/autopilot` running in the background; when nothing is drivable, Slack a notice, wait, retry `/drive`

## Context

- **Verified**: `/autopilot` must run in the main session, since only it can `ScheduleWakeup` and receive pause/off (`agent-pairing/assets/ccxp-agent.md:21`); that stays
- **Verified**: Slack webhooks resolve from `SLACK_WEBHOOK_URL_<NAME>` and `slack-send.sh` exits 1 when unset (`slack/scripts/slack-send.sh:59-60`); the env vars are currently unset on this machine, so the fallback is the normal path today
- **Verified**: `dev/.autopilot-state.json` is gitignored (`.gitignore:3`) and read by the HUD only through `sl-autopilot-fields`
- **Assumed**: a 16 GB machine can host one dispatched `/drive` at a time, not two; the loop therefore never overlaps cycles

## Solution

- **Commands**: `on`, `off`, `pause`, `resume`, `status`; nothing else. No duration, no `--now`, no `until <ISO>` or `stuck=` resume token
  - The ScheduleWakeup prompt is simply `/autopilot on`; `on` while already `on` is a tick, `on` while `paused` is a no-op that says so, and `off` cancels the pending wake
  - An old state file (no `"schema": 2`, or `status` of `running`/`stopped`) is read as `off`; `on` overwrites it
- **State** (`dev/.autopilot-state.json`, schema 2): `status` on|paused|off, `started_at`, `paused_at`, `cycle_count`, `merged_count`, `stuck_count`, `waiting_count`, `last_cycle_at`, `last_outcome` (progress|idle|stuck|waiting|capped), `last_task`, `last_stuck_reason`, `dispatch_clone_path`, `idle_notified`, `stuck_notified`, `skip_ids`, `day`, `cycles_today`, `merges_today`, `last_notice`
- **Loop**: each tick resolves one pick, dispatches one `/drive T<id> --auto-selected` sub-agent into the reused dispatch clone, classifies, then schedules the next wake. One `/drive` at a time
  - progress: wake in 60 s; stuck: back-off 5, 10, 20, 30 min (cap 30); waiting for human approval: same ladder; idle: config `idle_retry_minutes` (default 45, valid 30-60); capped: re-check hourly
- **Eligibility** (guardrails; report under "Needs your attention", never auto-driven)
  - `autopilot-state.sh eligible <task-file>` rejects a status line containing SUPERVISED, BLOCKED, "needs a human", "needs manual" or "sign-off"
  - The dispatch prompt tells `/drive` to stop before claiming and answer `NEEDS-ATTENTION: <reason>` when the design calls for a real build, a publish/promote/tag, a customer-visible post or HashData action; the id joins `skip_ids` so the next tick picks a different task
  - Existing merge gates are untouched: green CI, independent review, `gh pr merge --rebase`
- **Idle**: nothing eligible gives outcome `idle`; notify once (`idle_notified`), stay quiet on retries, notify again only when work resumes (a later merge) or on stuck (`stuck_count` reaches 3, once). Slack silence while idle is by design
- **Daily soft cap**: config `dev/.autopilot-config.json` (gitignored) `{"daily_cycle_cap": 24, "daily_merge_cap": 12, "idle_retry_minutes": 45}`; missing file or key means these defaults. Counters roll over at local midnight. At the cap the loop stays `on`, dispatches nothing, notifies once, re-checks hourly
- **Notifier**: `autopilot-state.sh notify <kind> <text>` tries `slack/scripts/slack-send.sh --channel dev`; on any failure (unset env var, network) it records the notice in `last_notice` and returns 0. `status` and the HUD show it either way
- **HUD**: `sl-autopilot-fields` accepts schema 2; the `requested` hours field becomes 0 and the band prints `AP on 3h ✓2 merged` (`⏸ paused`, `⚠n` when stuck, `idle` marker); `AP off` otherwise. New prefix `[i]` (idle) counts as on in `isApOn`
- **Alternatives rejected**
  - Detached `claude --bg` loop: no way to receive pause/off or reschedule from a skill today; kept as a later upgrade
  - Daily cap as a command argument: violates the five-command grammar and invites forgetting it
  - New `autopilot: skip` task frontmatter key: needs a `lint_tasks.py` allowlist change; status-line markers and an agent-side refusal need none
  - Notify on every idle retry: noisy; the user asked for one notice

## Test plan

- [ ] Unit: `tests/autopilot_state.bats` covers status normalisation (legacy and malformed files read as off), on/off/pause/resume transitions, delay ladder, cap rollover, notify-once flags, eligibility, notifier fallback with unset env vars
- [ ] Unit: updated `tests/hud_lib.bats` and `tests/hud_data.bats` for schema 2 states; `hud/pure.test.ts` for the new cell text
- [ ] Docs: `grep` finds no remaining `/autopilot <duration>`, `until <ISO>` or `stuck=` references outside JOURNAL
- [ ] Post-merge, manual by the maintainer: a real `/autopilot on` session (not run here)

## Done criteria

- [ ] SKILL.md documents exactly five commands; no duration argument (`autopilot/SKILL.md` Argument section; `tests/autopilot_state.bats` grammar test)
- [ ] Loop runs until `off`; idle notifies once (`tests/autopilot_state.bats` idle-once test)
- [ ] Soft daily cap from config, not an argument (`tests/autopilot_state.bats` cap tests)
- [ ] Notifier never errors when Slack env vars are unset (`tests/autopilot_state.bats` fallback test)
- [ ] HUD shows AP on/off for the new states (`tests/hud_lib.bats`, `hud/pure.test.ts`)
- [ ] Docs and references updated (`README.md:106`, `hud/README.md`, `hooks/ask-skills.txt` unchanged by design)

## Closed

- Open: filled at close.

## Skills invoked

- Pending until close.
