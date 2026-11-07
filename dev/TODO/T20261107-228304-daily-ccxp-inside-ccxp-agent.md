---
status: Open
estimation: 1
source: owner request 2026-11-07 (job 1001)
related: T20261107-406028, T20261107-431002
---

# T20261107-228304: Daily ccxp (standup, ipm, retro) runs from ccxp-agent on any platform

## Problem

- **Type**: feature
- Owner: "deprecate daily-ccxp.sh, and fold that feature back into ccxp-agent ... I want the daily-ccxp behavior (ipm, standup, retro) can run across platforms, as long as they have the ccxp-skills plugin with ccxp-agent loaded." Also: "the clone there should always following the main, and jobs should be done inside subagent worktree, instead of on the branch itself."
- Today the schedule lives outside the plugin: each consumer hub carries a `dev/daily-ccxp.sh` wrapper (about 1000 lines of bash) fired hourly by cron or a macOS launchd job. It only runs on the one machine that has the job installed, with machine-specific paths.
- What the wrapper does today (the behavior to keep or consciously drop; read-only study 2026-11-07):
  - Trigger and gating: hourly tick, pre-flight gate (daily floor 23h, open PR activity, CI failure on main, task due, in-flight task); Monday `/ipm` once per day (Chicago-frame date, attempt marker plus completed `ipm-weekly.md` check); Friday retro is inside `/ccxp`; `CCXP_CRON_MODE=1` skips Phase 3 focused work.
  - Locking and supervision: PID file lock, skip when a session is alive, reap finished-but-hung, rotate on age, wedge or skills update, resume via `--continue`.
  - Alerts: Slack notice on auth error, cron failure, repo-in-use, auth unreachable; usage-cost warning.
  - Logging: daily log file, stream-json filtered through jq, log rotation.
  - Env and credentials: token env for headless auth, Keychain reachability probe, minimal PATH.
  - Clone hygiene: skip when the clone is on a non-main branch (human in use), otherwise restore main before running.
- Open tasks in the hub that this makes obsolete or reshapes: T20260929-120342 (launchd migration), T20261002-182634 (dead-man switch), T20261103-413260 (Slack credentials in cron), T20260917-403652 (document the per-repo script).

## Requirements

- The persona (or a skill it calls) triggers the standup every day, `/ipm` on Mondays and the retro on Fridays, on macOS and Linux, with no machine-specific path.
- A day is never run twice: durable per-day state (marker per ritual plus the completed journal check) that survives a restart and is shared by whatever trigger fires.
- Every ritual job runs in a subagent worktree; the main clone only follows `main` and is never switched to a job branch.
- Failure notice (Slack) and a log trail survive the move; credentials come from the profile or environment, never from a file in the repo.
- Design lists the scheduling options with a recommendation (see below); the mechanism is an owner decision.

## Scheduling options (design to compare)

- Claude Code routine via the `schedule` skill (cloud cron agent): platform-neutral, no local machine; needs the repo reachable from the cloud environment and credentials there.
- `CronCreate` / `/loop` inside a long-lived `claude --agent ccxp-agent` session: simple, but only fires while the session is alive; `ScheduleWakeup` has the same limit.
- `claude --bg` detached jobs started by a tiny per-OS trigger: still needs one OS scheduler per machine.
- GitHub Actions cron in the hub: fully platform-neutral and durable, but runs on a runner, not the owner's machine and Keychain.
- Recommendation (to confirm with the owner): a routine as the primary trigger, with the persona's on-start catch-up (marker check) as the fallback whenever a session opens.

## Done

- Design merged; implementation behind it merged; a day's standup, a Monday `/ipm` and a Friday retro each verified once on a platform other than the original macOS job, with the idempotency marker proven by a second trigger that does nothing.
