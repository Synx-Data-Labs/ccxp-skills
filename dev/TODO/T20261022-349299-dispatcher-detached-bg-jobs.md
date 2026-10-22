---
status: In Progress
estimation: 1
source: this conversation, 2026-10-22 (user asked to verify `claude --bg` and teach ccxp-agent to dispatch detached jobs)
description: ccxp-agent dispatches long or risky jobs as detached `claude --bg` sessions through a launcher script
claimed_by: cc1-50ac6891:9be2f5145d25b4ed
claimed_role: interactive
scheduled: 2026-10-19
---

# T20261022-349299: ccxp-agent dispatches detached `claude --bg` jobs

## Problem

- In-process Agent-tool subagents die with the dispatcher session; long or risky jobs (builds, promotes, waits over ~10 minutes) need to survive a dispatcher restart.
- User ask: "verify your discovery, and then we need to incorporate those into our ccxp-agent, so the agent knows how to dispatch in background processes".
- Probes on `claude` 2.1.307 (see `agent-pairing/bg-jobs.md` Verified facts) confirmed `--bg` works from a Bash tool and survives the launcher, with these gotchas:
  - shell env is not inherited (only the settings `env` block)
  - a git root needs its own workspace trust
  - `--resume` with flags or on a live session starts an unsandboxed copy
  - `--add-dir` swallows a trailing prompt
- Done looks like:
  - `job-launch.sh`, `job-status.sh`, `job-resume.sh` under `agent-pairing/scripts/`, with BATS tests using a fake `claude` shim
  - persona section (about 25 lines) plus `agent-pairing/bg-jobs.md` runbook
