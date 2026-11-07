---
status: Design
estimation: 1
source: owner request 2026-11-07 (job 1001)
related: T20261107-406028, T20261107-431002
claimed_by: cc1-50ac6891:124c776dbc3570af
claimed_role: interactive
scheduled: 2026-11-02
---

# T20261107-228304: Daily ccxp (standup, ipm, retro) and fast CI-failure response run from ccxp-agent on any platform

## TLDR

- **Type**: feature
- **Problem**: the daily rituals live in a per-machine cron/launchd wrapper (`dev/daily-ccxp.sh` in the build hub), and the persona only notices CI failures at a user turn or autopilot wake.
- **Solution**: make "what is due now" a plugin-owned, idempotent check that the persona runs on any trigger (session start, routine, CI event); add an event-driven CI-failure trigger so a failure wakes a job in minutes, not at the next turn.
- **Open owner decision**: the trigger mechanism (see `## Decision needed` below, recommendation given).

## Problem

- Owner: "deprecate daily-ccxp.sh, and fold that feature back into ccxp-agent", "so that we can respond to the CI failures much faster, and also be able to do the daily standup, ipm and retro", on any platform with the plugin and ccxp-agent loaded. Also: "the clone there should always following the main, and jobs should be done inside subagent worktree, instead of on the branch itself."
- Goal 1, fast CI response. `agent-pairing/assets/ccxp-agent.md` (section "CI failure response", line 39 onward) detects failures only "at the start of each user turn and on each autopilot wake; no background watcher exists". A failure while the session is idle waits for the next turn (verified by reading the persona).
- Goal 2, daily rituals. Today they run only on the machine holding the job: an hourly tick of `dev/daily-ccxp.sh` (hub repo, 1019 lines) via cron or a launchd plist with machine paths (verified by reading both).
- Verified wrapper behaviors (`dev/daily-ccxp.sh` in the hub at commit 82258f75, 1019 lines by `wc -l`, function names from `grep`):
  - Gating: `preflight-actionable` (signals: daily floor 23h, PR activity, CI failure on main, task due, in-flight task); `ipm-due` (Monday, Chicago-frame date, once per day via attempt marker plus completed `dev/JOURNAL/<monday>-ipm-weekly.md`); `holdday-cadence-skip` (disabled by default).
  - Lock and supervision: PID file, `previous-alive`, `session-done-but-hung`, `session-wedged`, `session-too-old`, rotate via `--continue`.
  - Alerts: `alert-auth-error`, `alert-cron-failure`, `alert-repo-in-use`, `alert-auth-unreachable`, `usage-warn`.
  - Logging: daily log, stream-json through a jq filter, `rotate-logs`.
  - Env and credentials: `preflight-auth-reachable` (Keychain probe), token env, minimal PATH.
  - Clone hygiene: `repo-in-use`, `restore-default-branch` (skip when a human has the clone on a non-main branch).
  - Cron mode: `CCXP_CRON_MODE=1` makes `/ccxp` skip Phase 3 focused work (`ccxp/SKILL.md` lines 17-36).

## Context

- The persona is a dispatcher: it hands real work to background subagents and only does read-only lookups itself (`ccxp-agent.md` line 9 and line 19). Its tools include `ScheduleWakeup`, which only fires while the session lives (`dev/guidelines.md` of the hub documents that a pending wakeup never fires once a headless session exits).
- Existing building blocks to reuse, not rebuild: `/ccxp` (standup plus Friday retro), `/ipm` (Monday, no day-of-week check of its own, `ipm/SKILL.md` line 13), `/rca` plus `/new-task` plus `/drive` for failures (persona CI section), `/autopilot` (main-session loop), plugin hooks (`hooks/hooks.json`: SessionStart and UserPromptSubmit already run `persona-check.sh`), `hud/scripts/ledger.sh` (job ledger and dedupe record).
- Related hub tasks this makes obsolete or reshapes: T20260929-120342, T20261002-182634, T20261103-413260, T20260917-403652.
- Platform facts not verified in this study (labelled assumed in the options): that a Claude Code routine can be started by a GitHub event or an HTTP API call, and that `CronCreate` survives a session exit.

## Solution

- One plugin-owned entry point, `ccxp/scripts/daily-due.sh` (new), prints what is due now as lines `standup`, `ipm`, `retro`, `ci <run-id>`, empty when nothing. It is token-free, read-only, portable bash (no `date -d`/`-v` split without a helper), and every trigger calls it; the trigger never decides what to run.
  - Day gating lives here: standup every day, `ipm` on Monday, `retro` on Friday, in a configurable timezone (default `America/Chicago`, as the wrapper does).
  - Idempotency is derived from artifacts that live in git or GitHub, never from a local marker file, so a cloud run with a fresh clone and a laptop agree: the ipm check is the completed `dev/JOURNAL/<monday>-ipm-weekly.md` (not the "Pre-IPM staging" stub), the retro check is that week's retro journal entry, the CI check is the run id appearing in a task, a context file or the ledger (the persona's existing dedupe rule). The retro artifact filename pattern must be pinned in the implementation (`ccxp/SKILL.md` lines 495-497 only say a retro report in `dev/JOURNAL/`). The standup artifact is an open item (see Decision needed).
- The persona runs `daily-due.sh` at: session start (the existing `persona-check.sh` hook only injects context text for the persona within its 5 second timeout and cannot dispatch; SessionStart matches `startup` only, so a resumed session relies on the next user turn or wake instead), each user turn (cheap), each autopilot wake, and when a routine or CI event starts it. For each due line it dispatches one background job in a subagent worktree with `CCXP_CRON_MODE=1` set explicitly in the job prompt (a subagent does not inherit it; rituals only, no Phase 3), same job-prompt rules as today. This is the "on-start catch-up" that makes a missed day heal on any platform.
- Worktree-only and main-following: the persona never checks out a job branch in the session clone; every repo-changing job is dispatched with `isolation: "worktree"` (already a hard rule, `ccxp-agent.md` line 152; its existing carve-out for skill-driven jobs such as `/drive` stays unchanged, and `/ccxp` and `/ipm` ritual jobs get worktree isolation). The `main` fast-forward is a write, so the persona does not do it inline (`ccxp-agent.md` line 19 allows read-only Bash only): the ritual job's own Phase 0 sync (`ccxp/SKILL.md` Phase 0) does it, only when the clone is clean and on `main`; a dirty or non-main clone is reported, not touched (replaces `repo-in-use` and `restore-default-branch`).
- Fast CI response, event-driven: a small workflow template in the consumer repo, `on: workflow_run` with `types: [completed]`, conditioned on `conclusion == failure` and the existing filter (default branch, schedule, release), that (1) skips when the run id is already known, (2) wakes the agent through the chosen mechanism, (3) always posts the existing Slack failure notice so a human sees it even if the wake fails. The persona then runs `/rca <run>` and the existing CI-failure dispatch. Polling stays as the fallback (turn start and autopilot wake), so an event miss is healed by the next check.
- Failure visibility and logs: the ledger (`hud/scripts/ledger.sh`) is the job log; the Slack failure notice moves from the wrapper to the persona (one failed ritual job produces one alert). Credentials come from the profile or environment of the machine or routine, never a repo file; the wrapper's Keychain probe is replaced by a single "auth unreachable" alert when a job cannot start.
- What is deliberately dropped: PID lock and session rotation/reaping (one persona session per profile owns dispatch; the per-day artifact check is the lock), the hourly preflight gate and cost warning (the daily check is cheap and event-driven CI replaces the PR/CI probes; usage warning becomes a separate task if still wanted), the hold-day throttle (already disabled).
- Alternatives considered and rejected:
  - Port the bash supervisor into the plugin: keeps the machine-bound design, only moves the file.
  - Run the rituals only inside a long-lived session with `ScheduleWakeup` or `/loop`: dies when the session exits, which is the failure the owner wants removed.
  - GitHub Actions cron running the whole agent on a runner: durable and neutral, but needs model credentials in CI and a runner-side clone; kept only as a fallback option.

## Decision needed

Mechanism for triggering the persona when no user turn is happening (owner decision; nothing below is switched on by this task).

- Option 1, Claude Code routine (the `schedule` skill) for the daily rituals, plus a `workflow_run` workflow that fires the same routine for CI failures (assumed: routines accept an API or GitHub-event trigger; verify first). Neutral, no local machine; needs repo and credentials in the cloud environment. Recommended as primary.
- Option 2, session-start catch-up only (no scheduler): zero infrastructure, works everywhere the persona is loaded, but nothing happens until someone opens a session. Ship it regardless as the fallback layer.
- Option 3, `CronCreate` or `/loop` inside a long-lived persona session: simple, but only while that session lives.
- Option 4, `claude --bg` started by a per-OS scheduler: still one scheduler per machine, the thing being removed.
- Option 5, GitHub Actions cron or `workflow_run` running the agent on a runner: platform-neutral and durable; costs CI minutes and runner-side model credentials.
- Recommendation: Option 1 plus Option 2 (event-driven CI wake and daily routine, catch-up on every session start). If routines lack an event or API trigger, use Option 5 only for the CI wake and keep the daily routine.
- Reverses an earlier decision: T20260924-252293 retired the automatic Monday IPM (`ipm/SKILL.md` line 12, `ccxp/SKILL.md` lines 17-36 and 565-575: `/ccxp` no longer invokes it, no catch-up for a missed Monday). The owner now asks for ipm to run again as a daily-ccxp ritual; the hub wrapper already does (Monday floor, T20261023-920112). This design makes ipm due on Monday and catch up within the same week; the owner confirms by approving this PR, and `ipm/SKILL.md` line 14 ("no automatic mid-week catch-up") must be updated in the implementation.
- Also open: the standup idempotency artifact (a committed per-day marker versus checking the posted Slack thread), and the single timezone used for "Monday" and "Friday".

## Test plan

- [ ] Unit (BATS): `daily-due.sh` with injected date and timezone prints `standup` daily, `ipm` only Monday, `retro` only Friday; prints nothing once the artifact exists; a "Pre-IPM staging" stub does not count as done.
- [ ] Unit (BATS): second invocation after a ritual artifact appears is empty (idempotency); a missed Monday heals at the next session start of that week.
- [ ] Unit (BATS): CI line is suppressed when the run id is already in a task, context file or ledger.
- [ ] Local: persona session start on Linux and macOS runs the check and dispatches nothing when nothing is due.
- [ ] Integration (post-design, owner machine not touched): one standup, one Monday ipm and one Friday retro triggered on a non-macOS host, then a repeat trigger that does nothing.
- [ ] Integration: a forced failing nightly-style run produces a persona job within the target latency (to be set with the owner; recommended under 10 minutes).

## Done criteria

- [ ] Design merged and the trigger decision recorded (this PR; `## Decision needed` above).
- [ ] `ccxp/scripts/daily-due.sh` plus `tests/` BATS cover day gating and idempotency (Test plan unit items).
- [ ] Persona section "Daily rituals" and session-start catch-up in `agent-pairing/assets/ccxp-agent.md`, with the hook slot in `hooks/persona-check.sh` (file diff).
- [ ] Workflow template for the CI event trigger added under `actions/` or documented, with the dedupe test (Test plan CI item).
- [ ] Verified on a non-macOS host once per ritual (integration items; external, recorded in `## Closed`).
- [ ] Hub deprecation task T20261107-406028 unblocked only after the item above.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `agent-pairing/assets/ccxp-agent.md` | 9-19, 39-46, 152 | dispatcher rules, CI failure response, worktree rule |
| `ccxp/SKILL.md` | 17-36, 565-605 | cron mode and the day-of-week table |
| `ipm/SKILL.md` | 12-14 | ipm has no day-of-week check of its own |
| `hooks/hooks.json` | SessionStart, UserPromptSubmit | existing hook slots for the catch-up check |
| `hud/scripts/ledger.sh` | n/a | ledger used as dedupe and job log |
| hub `dev/daily-ccxp.sh` | 580-640, 903-1019 | `ipm-due`, `preflight-actionable`, `start-ccxp` (behavior being replaced) |
