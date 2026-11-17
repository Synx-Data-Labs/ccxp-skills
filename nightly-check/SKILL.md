---
name: nightly-check
description: Use when the user explicitly asks to check the nightly runs, or a routine step calls it — list failed nightly runs of the last day and run /rca (or /labrun-rca when the run has an alert thread) for each
argument-hint: "[--repo owner/repo] [--window-hours 26] [--max 3]"
---

# /nightly-check

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

One step of the `nightly-check` routine (`agent-pairing/routines.examples.yml`) and the single path for failed nightly runs (the persona's inline "CI failure response" keeps every other failed run). The detection is a script; the investigation is `/rca` or `/labrun-rca`.

## Argument

- `--repo owner/repo`: default the working repo (`gh repo view --json nameWithOwner`).
- `--window-hours N`: default 26 (a daily routine with slack). `--max N`: default 3 investigations per call; the rest are reported as `next`.

## Workflow

1. **List failed runs** (read-only, one call): `gh run list --repo <repo> --status failure --limit 30 --json databaseId,workflowName,event,headBranch,conclusion,createdAt,url > $RUNS`.
2. **Alerts** (only when `$SLACK_AUTOMATION_ALERTS_CHANNEL_ID` is set): `slack_read_channel` on that channel only, newest 20 messages; write one line per message `<message_ts><TAB><text and flattened blocks, newlines removed>` to `$ALERTS`. A failed read is not fatal: skip `--alerts` and say so.
3. **Handled set**: `$HANDLED` = the concatenated text of `dev/TODO/*.md` and `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ccxp-context/*` (a run id in any of them means it already has a task or job; skip it).
4. **Plan**: `bash <skills-root>/nightly-check/scripts/nightly-check.sh plan --window-hours N --max M --alerts "$ALERTS" --handled "$HANDLED" < $RUNS` prints `run|next<TAB>rca|labrun-rca<TAB>id<TAB>workflow<TAB>url<TAB>alert ts`.
   - Nothing printed: report `all nightly runs green or handled` (outcome `nothing-to-do` under `/routine`) and stop.
5. **Per `run` line, in order**:
   - `rca`: `/rca <id> --repo <repo>`.
   - `labrun-rca`: `/labrun-rca <channel> <alert ts>` (it posts the report in the alert's thread, so no bare `/rca` for that run).
   - A report that names a root cause not yet tracked: follow `/rca`'s own task filing; never open a duplicate task for a run id already in `$HANDLED`.
6. **Report**: one line per run (`<id> <workflow>: <classification>, <task id or none>`), then the `next` lines under "left for the next check". Outcome `ok` when every run was investigated, `needs-human` if a skill stopped for credentials, `failed` on an error.

## Safety

Read-only apart from what `/rca` and `/labrun-rca` do. Never re-runs a workflow, publishes, promotes, tags or releases.

## Important Notes

- Tests: `bats tests/nightly_check.bats` (filter, window, dedupe, cap, alert routing, green).
- Task: T20261116-179192 (routines part 3b); the persona side: `agent-pairing/assets/ccxp-agent.md` "CI failure response".
