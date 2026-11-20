# Idle wake (the persona checks CI and Slack alerts while you are away)

Owner decision (2026-11-20, n362): when autopilot is off and a session is open, the ccxp-agent persona wakes
itself every 30 minutes and runs only the two read-only checks. Task: T20261120-105513. It closes the gap that a
red CI or a Slack alert was only noticed at the next user turn or autopilot wake.

## What runs

- **Scheduling**: at session start, each user turn and each wake the persona runs `bash <plugin-dir>/agent-pairing/scripts/idle-wake.sh plan`.
  - `schedule <seconds>`: the persona calls `ScheduleWakeup` once with that delay and the prompt `[idle-wake]`.
  - No output (exit 1): nothing to do. Autopilot is on (its own wakes carry the checks), the idle wake is off, or a wake is already pending.
  - A recorded wake counts as pending until it is due plus 2 minutes; after that (it fired, or the session ended) the next `plan` schedules again.
- **The wake** (`[idle-wake]`): the persona runs ONLY
  1. `alerts-due.sh check` and, when it prints a window, the Slack alerts check of the persona (its own 5-minute rate limit applies);
  2. the CI failure detection (one `gh run list --status failure` per repo in scope), as in "CI failure response".
  - A job is started only for something new (an unhandled failed run, an unanswered failure alert). Nothing new: no job, no reply, then `plan` again to schedule the next wake.
  - It never runs the Routines due check, the repo-freshness fetch or anything else, and never replies to the owner just to say nothing happened.

## Opt-out and knobs

- `CCXP_IDLE_WAKE=0` in the environment, or `{"enabled": false}` in `<profile dir>/ccxp-idle/config.json`.
- Interval: `{"minutes": N}` in that file or `CCXP_IDLE_MINUTES` (default 30, never below 5, the alerts check's own rate limit).
- State: `<profile dir>/ccxp-idle/next-at` (epoch of the pending wake). `CCXP_IDLE_DIR` relocates it; `CCXP_IDLE_NOW` is a test hook.
- `bash <plugin-dir>/agent-pairing/scripts/idle-wake.sh status` prints the state in one line.

## Cost and limits

- Each wake is one persona turn (the persona prompt is large) while a session is open; nothing runs when no session is open, so this is not overnight coverage with a closed laptop or terminal.
- The wake count is bounded: one pending wake at a time, no more often than every 5 minutes.
- Tests: `bats tests/idle_wake.bats`.
