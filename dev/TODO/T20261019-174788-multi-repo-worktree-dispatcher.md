---
status: Open
estimation: 1
source: this conversation, 2026-10-19
description: design how the ccxp skillset works across repos, each task/PR in its own worktree, repos staying on main
related: [migrate-task]
---

# T20261019-174788: Make the ccxp skillset multi-repo aware: a dispatcher/agent that works each task/PR in its own git worktree while all repos stay on main

## Problem

- **Type**: research
- **Goal**: manage the repos like teams that collaborate, not isolated silos.
  - Keep every repo checkout on its default branch (e.g. `main`), never switched.
  - A dispatcher, or a new `ccxp-agent`, creates a worktree and works one task/PR there.
  - Open question the user asked: can this be achieved at all? Answer it, then design it.
- **Current state**:
  - Tasks are organized per repo (`dev/TODO` queue each), in one shared parent workspace directory: ccxp-skills, synx-skills, synxdb-team, synxdb-build-pipeline, synxdb-cloud-omnistrate, synxdb-devenv-launcher, synxdata.com.
  - `/migrate-task` moves tasks between repos (triage between teams).
  - `/drive` and `/address-pr` create their own branch/clone and work in it, so the checkout is switched.
  - Sibling worktrees already exist (`ccxp-skills-wt-*`, `.claude/worktrees/*`) with no shared convention.
- **Open questions to design**:
  - Worktree location, naming, and cleanup (who removes it, when, after merge or abandon).
  - How `/drive` and `/address-pr` resolve the target repo from a task ID or PR.
  - Cross-repo task lookup and an aggregated queue view across all repos.
  - Claim semantics across worktrees (claim currently per clone).
  - Dispatcher vs a new `ccxp-agent` role: who owns worktree lifecycle.
  - Interaction with existing sibling worktrees (`ccxp-skills-wt-*`).
- **Done looks like**: a short design doc answering feasibility and the questions above, with follow-up implementation tasks filed. Nothing implemented here.
