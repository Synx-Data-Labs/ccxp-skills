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
  - The ScheduleWakeup prompt is simply `/autopilot on`; no resume token. Wakes are told apart from a typed `on` by the state file: `next_wake_at` (set when a wake is scheduled) and `busy_since` (set while a cycle is dispatched)
    - `on` when `off` starts a fresh run, but if the previous run's cycle is still busy (same 3 h bound) it sets `on`, dispatches nothing and arms nothing (`busy`): that cycle's Phase 4 re-reads `on` and arms the single next wake, like `resume`;  when `on`, it dispatches only if `now >= next_wake_at - 30 s` (tolerance for a wake that fires a moment early) and no cycle is busy (a busy mark older than 3 h is treated as crashed; a cycle can legitimately run for hours while CI is waited out, so the bound is deliberately generous and `status` shows the busy age), else it reports `already on, next cycle at <time>` and does nothing
    - A stale wake (after `off`, or `off` then `on`) finds `off`, or fires before the new `next_wake_at`, and does nothing (an early wake is never re-armed, since `ScheduleWakeup` cannot list pending wakes; that would spawn parallel chains). Every path that hands control back (`on`, `resume`, Phase 4) arms exactly one fresh wake, and `pause`/`off` cancel the pending one
    - `on` while `paused` is a no-op that says so; `status` and the HUD mark a run `overdue` when `now` is more than 10 min past `next_wake_at` with no busy cycle (lost wake after a session restart), and a typed `on` recovers it
  - `busy_since` is set when a cycle is dispatched and cleared by Phase 4's `record`, and by `off`/`pause` once the interrupted sub-agent has reported; `off` clears `next_wake_at` and `skip_ids` but leaves `busy_since` for the skill to clear after the interrupted sub-agent reports
  - Single-chain invariant: only a cycle's Phase 4 (or a fresh `started`/`dispatch`) arms a wake, so `resume` or `on` while a cycle is busy dispatches and arms nothing (the helper prints `busy`); the busy cycle's Phase 4 re-reads `on` and arms the next wake. A due wake that finds a busy cycle is therefore harmless: the busy cycle will arm its own
  - Phase 4 re-reads `status` before scheduling any wake and schedules only if still `on`; `off` also calls `ScheduleWakeup(stop: true)`
  - `off` or `pause` during a cycle does not kill the sub-agent (no `--now`): it `SendMessage`s it to finish or push WIP and report, then the loop stops with the result recorded
  - An old state file (no `"schema": 2`, or `status` of `running`/`stopped`) is read as `off`; `on` overwrites it. A leftover wake prompt in the old format (`/autopilot until <ISO> stuck=<n>`, or `<duration>`) is refused: the skill reports the current status and does nothing
  - `resume` shifts `started_at` forward by the pause length (so HUD elapsed stays frozen across it), sets `status: on` and runs one tick immediately unless `busy_since` shows the interrupted cycle still running (same busy gate as `on`); the pre-pause `last_task` is not special-cased because the claim already holds it
  - State writes are atomic (temp file then `mv`), since the file is now load-bearing, not advisory
- **State** (`dev/.autopilot-state.json`, schema 2): `status` on|paused|off, `started_at`, `paused_at`, `cycle_count`, `merged_count`, `stuck_count`, `waiting_count`, `last_cycle_at`, `last_outcome` (progress|idle|stuck|waiting|capped), `last_task`, `last_stuck_reason`, `dispatch_clone_path`, `idle_notified`, `stuck_notified`, `capped_notified`, `skip_ids`, `day`, `cycles_today`, `merges_today`, `notices` (last 20), `needs_attention`, `waiting_notified`, `next_wake_at`, `busy_since`
- **Loop**: each tick resolves one pick, dispatches one `/drive T<id> --auto-selected` sub-agent into the reused dispatch clone, classifies, then schedules the next wake. One `/drive` at a time
  - progress: wake in 60 s; stuck: back-off 5, 10, 20, 30 min (cap 30); waiting for human approval: same ladder; idle: config `idle_retry_minutes` (default 45, valid 30-60); capped: re-check hourly
- **Eligibility** (guardrails; report under "Needs your attention", never auto-driven)
  - `autopilot-state.sh eligible <task-file>` rejects a status line containing SUPERVISED, BLOCKED, "needs a human", "needs manual" or "sign-off"
  - The dispatch prompt tells `/drive` to stop before claiming and answer `NEEDS-ATTENTION: <reason>` when the design calls for a real build, a publish/promote/tag, a customer-visible post or HashData action; the id joins `skip_ids` so the next tick picks a different task; `skip_ids` clears at the daily rollover and on `off`, so a task a human fixed is retried the next day (a still-flagged task is re-notified once per day, deliberately)
  - Existing merge gates are untouched: green CI, independent review, `gh pr merge --rebase`
- **Idle**: nothing eligible gives outcome `idle`; notify once (`idle_notified`, text names the skipped ids and says retries are silent), stay quiet on retries, notify again only when work resumes (`resumed`, clears `idle_notified`), or on stuck (`stuck_count` reaches 3, once; `stuck_notified` clears on the next progress), or when `waiting` (a PR needs a human approval) repeats twice (`waiting_notified`, cleared on progress). Each newly skipped task also notifies once (`attention`) with its reason, so a needs-attention task is reported even while other tasks keep merging. The cap notice has its own `capped_notified`, cleared at the daily rollover
- **Daily soft cap**: config `dev/.autopilot-config.json` (gitignored) `{"daily_cycle_cap": 24, "daily_merge_cap": 12, "idle_retry_minutes": 45}`; missing file or key means these defaults. Counters roll over at local midnight. At the cap the loop stays `on`, dispatches nothing, notifies once, re-checks hourly
- **Notifier**: `autopilot-state.sh notify <kind> <text>` tries `slack/scripts/slack-send.sh --channel dev`; on any failure (unset env var, network) it still returns 0. Every notice is appended to `notices` with `via: slack|fallback`; `status` lists the last ones and `needs_attention`, so a Slack outage or unset env var loses nothing. The once-flags are set when the notice is sent or durably recorded
- **HUD**: `sl-autopilot-fields` drops its `end_time` checks (`hud/scripts/hud-lib.sh:265-272`) and its `running|paused|stopped` allowlist, accepting schema 2 `on|paused|off`; `off` and legacy files print nothing, and the band shows `AP off` through the existing helper-present path (`hud/model.ts:481`). Field order is unchanged (`hud/scripts/hud-data.sh:95`); `requested_hr` is 0, and `apVariants` (`hud/model.ts:222`) drops the `/requested` part when it is 0. The band prints `AP on 3h ✓2 merged` (`⏸ paused`, `⚠n` when stuck, `idle` marker); `AP off` otherwise. Prefix precedence: `[p]` paused, then `[b]` when `last_outcome` is `stuck`, then `[i]` when it is `idle` or `capped` (cell `AP on idle` / `AP on capped`), else `[r]`; `[i]` counts as on in `isApOn`
- **Alternatives rejected**
  - Detached `claude --bg` loop: no way to receive pause/off or reschedule from a skill today; kept as a later upgrade
  - Daily cap as a command argument: violates the five-command grammar and invites forgetting it
  - New `autopilot: skip` task frontmatter key: needs a `lint_tasks.py` allowlist change; status-line markers and an agent-side refusal need none
  - Notify on every idle retry: noisy; the user asked for one notice

## Test plan

- [ ] Unit: `tests/autopilot_state.bats` covers status normalisation (legacy and malformed files read as off), on/off/pause/resume transitions, delay ladder, cap rollover, notify-once flags, eligibility, notifier fallback with unset env vars
- [ ] Unit: updated `tests/hud_lib.bats` and `tests/hud_data.bats` for schema 2 states; `hud/pure.test.ts` (the `isApOn` case near line 193 and the new cell text)
- [ ] Docs: `.gitignore` ignores the config file; `grep` finds no remaining `/autopilot <duration>`, `until <ISO>` or `stuck=` references outside JOURNAL
- [ ] Post-merge, manual by the maintainer: a real `/autopilot on` session (not run here)

## Done criteria

- [ ] SKILL.md documents exactly five commands; no duration argument (`autopilot/SKILL.md` Argument section; `tests/autopilot_state.bats` grammar test)
- [ ] Loop runs until `off`; idle notifies once (`tests/autopilot_state.bats` idle-once test)
- [ ] Soft daily cap from config, not an argument (`tests/autopilot_state.bats` cap tests)
- [ ] Notifier never errors when Slack env vars are unset (`tests/autopilot_state.bats` fallback test)
- [ ] HUD shows AP on/off for the new states (`tests/hud_lib.bats`, `hud/pure.test.ts`)
- [ ] Docs and references updated (`README.md:106`, `hud/README.md`; `hooks/ask-skills.txt` unchanged by design)
- [ ] Follow-up filed for `agent-pairing/assets/ccxp-agent.md` (its `/autopilot 2h` example and a precise allowance wording): the existing carve-out already permits `/autopilot` bookkeeping Bash, which covers `autopilot-state.sh`; the file is out of scope here because another job has an open PR on that file (`dev/TODO` follow-up task id recorded at close)

## Closed

- Open: filled at close.

## Skills invoked

- Pending until close.
