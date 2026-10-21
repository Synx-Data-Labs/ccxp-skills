---
status: Open
estimation: 1
source: ccxp-agent dispatcher session, 2026-10-20/21
related: T20261012-373882
description: durable dispatcher ledger, lesson capture, shared standing rules, memory hygiene automation
---

# T20261021-337802: Agent memory management: durable dispatcher ledger/job registry, lesson capture, shared standing rules, and memory hygiene automation

## Problem

- **Type**: feature
- Evidence below was observed 2026-10-20/21 in the ccxp-agent dispatcher session. This task is design plus estimate only; do not implement here.
- **1. The ledger lives only in the conversation.**
  - Numbered ledger, job ids, agent ids and ownership are not persisted.
  - Three session restarts/reboots stopped running jobs (#48 release job, #50, #52, ...); recovery meant reading transcripts and GitHub state.
  - Need a small durable registry written when a job starts/ends: job number, agent id, description, start time, status, links/PRs, reference ids (i/a/s/r/k), owner clone id. It must survive restarts and come with resume instructions.
- **2. Lessons are not captured as they happen.** None of these were saved anywhere:
  - Stale 1.0.1 plugin cache produced the wrong `Coding` status vs the repo lint (`In Progress`/`Design`).
  - `op` 1Password sessions are not visible to agent shells (only the user's iTerm); fix is restarting Claude from a direnv-loaded shell so env vars exist.
  - The gh wrapper picks the wrong account with `--repo` alone; it picks correctly only from inside the clone.
  - /tmp and the scratchpad are wiped by reboot.
  - `/address-pr` ownership gate blocks takeovers across clone hashes.
  - GitHub rebase-only repo setting broke a merge-back PR after update-branch added a merge commit.
  - Reading comments with tokened URLs safely (mask in pipes).
  - URLs inside fenced code blocks are not clickable.
  - A public repo cannot use org secrets with `private` visibility.
  - `/memory-to-skill` exists but only runs on request.
- **3. Subagents start blank**, so the dispatcher re-pastes the same standing rules into every brief: secrets handling, skip Slack/webhook, no `--admin`, no heavy local work on the 16 GB Mac, never accept/close support issues, worktree/fresh-clone rules. Propose a shared "standing rules" file that briefs reference.
- **4. Memory hygiene gaps.**
  - The only project memory note (`feedback_fork_tool_inheritance.md`) was written once on 2026-10-10 and never revisited.
  - No verify-by/staleness metadata.
  - Memory is per clone (19 of 51 project dirs have one) with no sharing across machines (claims use `cc1-<machine-id>`).
  - The size caps in CLAUDE.md (project CLAUDE.md 50 lines/3 KB; memory files total 100 lines/5 KB) are a rule, not an automated check.
- **5. The persona does not describe the ledger structure.**
  - `agent-pairing/assets/ccxp-agent.md` (live copy `~/.claude/agents/ccxp-agent.md`) omits the Running / Parked sections, status bullets, and the order Needs input -> Needs your action -> Running -> Parked.
  - [PR #381](https://github.com/Synx-Data-Labs/ccxp-skills/pull/381) added the ledger order, #389 the job number in Agent descriptions, #397 the reference IDs (`i<n>` input, `a<n>` action, `s<n>` status bullet, `r<n>` running = job number, `k<n>` parked).
  - Fold that structure into the persona text and make it restart-safe.
  - Parked = work deliberately set aside, kept visible and resumable. Done is intentionally omitted from the ledger at the user's request.

## Design scope (to be answered by the design phase)

- **Registry location**: per-user file under `~/.claude` vs a repo `dev/` ledger vs both.
- **Format**: JSONL vs JSON.
- **Writer**: persona rule vs a hook.
- **Lesson capture**: trigger, and the promote step into `/memory-to-skill`.
- **Standing rules**: file location, and how briefs reference it.
- **Memory lint**: caps, dates, verify-by.
- **Cross-machine sharing**: options.
- **Secrets rule**: never store secrets in memory or the ledger.

## Estimate (design-time guess; filed at 1, `/incept` revises)

- Registry + persona rewrite: 3
- Lesson capture + promote step: 2
- Standing-rules file + brief references: 1
- Memory lint + cross-machine option: 2
- Whole task: about 5-8 points, likely split into child tasks at `/incept`.

## Context

- `/memory-to-skill`, `/retro` Phase 1b, and T20261012-373882 are context only.
