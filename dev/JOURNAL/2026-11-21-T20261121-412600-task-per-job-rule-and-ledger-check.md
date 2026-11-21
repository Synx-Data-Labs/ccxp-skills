---
status: Done
estimation: 3
source: Owner 2026-11-21 via home session; brief ccxp-skills-task-per-job-brief.md (job 1351)
type: feature
scheduled: 2026-11-16
claimed_by:
claimed_role:
---

# T20261121-412600: Task-per-job rule and ledger check

## TLDR

- **Type**: feature
- **Problem**: a ccxp-agent job that changes a repo usually starts without filing a task, so the owner's goal and chat decisions never reach git.
- **Solution**: three layers: a persona rule (task first, then `/drive`), a mechanical `ledger.sh` check for repo-changing jobs, and chat decisions written into the task's design section.

## Problem

- Owner's words (Shine, 2026-11-21): "when I create a new job, I want that job to create a new task in the corresponding repo, and then follow the regular /drive process to finish up the task. however, today, the ccxp-skills, just start a job, and most time didn't create a task, and that caused us missing key decisions in the git history, how to fix it?"
- Brief: `ccxp-skills-task-per-job-brief.md` in the owner's home-profile context dir (outside the repo) (a proposal from the home session, approved for this repo by the owner's message "let's take a look at [the brief] and create a task and improve the ccxp-skills job").
- Evidence: the persona's "Writing a job prompt" never requires a task; only skill-driven jobs (`/drive`, `/land`, `/address-pr`) touch the lifecycle. Home job 520 renamed a profile with no task: its decisions live only in the job report and the ledger.

## Context

- The persona is at its size guard (`tests/agent_pairing.bats`, under 48500 bytes), so detail lives in `agent-pairing/task-per-job.md` and existing prose was condensed.
- The ledger already has `--flags` and per-row fields (`hud/scripts/ledger.sh`); `check` already fails on MISSING / EXTRA / NO-CONTEXT.

## Solution

- Layer 1 (PR 1): persona bullet plus `agent-pairing/task-per-job.md` (when, what, exceptions, decisions into git).
- Layer 2 (PR 2): `ledger.sh start --task T<id>` / `--no-task "<reason>"`, a new flag `repo-changing`; `check` fails with `NO-TASK r<n>` for a repo-changing row with neither; `reply` shows `(no task)` on the Running row; `finish` warns on stderr; persona job-start line and `hud/scripts/ledger.md` updated.
- Layer 3 (PR 1): the persona and the doc tell each job to record the owner's chat decisions in the task's design section, d-refs quoted.

## Design decisions

- How the persona knows a repo has `dev/TODO`: a read-only `ls <path>/dev/TODO` of the resolved repo path.
- What counts as repo-changing for the check: the explicit flag `--flags repo-changing`, set by the dispatcher on its `start` call (the same condition as the persona's `isolation: "worktree"` rule: the job writes, stages, commits or checks out in a repo). Rows without the flag are never checked, so every existing call keeps working.
- Declared exceptions: `--no-task "<reason>"` satisfies the check and shows `(no task: <reason>)`; `finish` warns only when neither a task nor a reason was given.
- Overhead for tiny jobs: `/new-task` files at `estimation: 1` in one short exchange; exceptions are explicit and short.
- Order: persona and doc first (no ledger flag in the persona yet, so an old `ledger.sh` never sees an unknown flag), the ledger check second, then the persona's start line passes the flag.

## Test plan

- [x] `bats tests/agent_pairing.bats` passes, including the size guard (persona under 48500 bytes).
- [x] `bats tests/ledger.bats` covers `--task`, `--no-task`, `check` failure, the Running-row text, the `finish` warning and backward compatibility (old calls and old ledger files).
- [x] Repo lint (`lint_tasks.py`, markdown lint) passes on the changed files.

## Done criteria

- Both PRs merged through `/address-pr` (plain `--rebase`); this task moved to `dev/JOURNAL/`.

## Closed

- PR 687 (persona rule, doc, task, queue; merged) and the ledger check PR (this one). Persona size after: 48482 bytes (guard: under 48500).
- Choices: `--flags repo-changing` marks a repo-changing row; `--no-task "<reason>"` is a declared exception (no `finish` warning); `check` prints `NO-TASK r<n>`; the Running row shows `(no task)` or `(no task: <reason>)`.
