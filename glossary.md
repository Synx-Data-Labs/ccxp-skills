# Glossary — coined terms & acronyms

Canonical definitions for terms coined across this workflow suite — skills
and the IPM cadence. If a term drifts between docs, or a newcomer can't
look it up, it belongs here.

This file lives in `ccxp-skills` (peer to [`lifecycle.md`](lifecycle.md));
each consumer repo's `dev/guidelines.md` references it rather than keeping
its own copy.

**Format:** one entry per term — `**term** — definition (source).` Sorted within
each section; keep definitions to one sentence and cite the authoritative
source skill / phase / doc.

## Lifecycle & IPM

- **Candidates staging** — appending tasks to the upcoming Monday's `## Candidates` section throughout the week via `/stage`, accumulating rationale before the IPM decides (`/stage`, `/ccxp` Phase 2a).
- **ccxp** — Claude Code Extreme Programming: the orchestrator skill that runs the daily standup, Monday IPM, focused-work loops, and Friday retro (`/ccxp`).
- **claim PR** — a pure-status-change PR that flips a task `Open → Coding`/`Design` and lands the ownership marker on `main` *before* design or implementation, so "someone is working on this" is durable and board-visible (`/drive` Phase 1).
- **IPM** — Iteration Planning Meeting: the Monday commit that picks the week's work from candidates and cuts, revises estimates, and budgets focused-work hours (`/ccxp` Phase 2a).
- **IPM commit** — the moment the Monday IPM writes `dev/JOURNAL/<Mon>-ipm-weekly.md` with the Tier 1/2 picks, cuts, and order, and stamps `scheduled:` on every picked task (`/ccxp` Phase 2a.5).
- **kind-scaled** — documentation whose required depth and sections scale to the change kind: docs-class tasks omit the code-only sections, code-class tasks include them (`/drive` Phase 3.0).
- **peer mode** — the default mode (disable with `CCXP_PEER_MODE=0`) where parallel sessions (cron + interactive) coordinate via a durable `claimed_by:` lock on `main`, replacing the older one-session-per-clone assumption (`/drive` Phase 1).
- **scheduled** — a task-frontmatter date (always a Monday) recording when the task was last scheduled; set softly by `/stage` (next Monday) and firmly at IPM commit (this Monday); update-forward-only, never removed (`lifecycle.md`).
- **Tier 1 / Tier 2 / Tier 3** — IPM work bands: Tier 1 is in-flight carry-over (Coding/Review) finished first, Tier 2 is the newly-committed picks, Tier 3 is mid-week additions appended after the IPM commit (`/todo`, `/ccxp`).

## Quality & process

- **cc-owned** — *(retired)* the old per-session PR label + marker comment for anti-steal; replaced by **PR ownership derived from the task claim** — a stranded marker under a dead session was the recurring pain, and a PR is now owned by whoever holds its task (`task_claim.sh pr-owner`, `/address-pr` §1.6).
- **PR ownership (derived)** — a PR is owned by whoever owns the **task it implements** (that task's `claimed_by: <host>:<path>` on `main`); there is no separate PR-resident ownership state. Resolved by `task_claim.sh pr-owner <pr>` → `mine`/`free`/`untracked`/`owned:<by>`/`unknown`; a dead owner's claim self-clears via release-on-pickup or the reclaim sweep.
- **code-class / docs-class** — the change classification that routes `/drive`: code-class invokes TDD before implementing; docs-class skips TDD and uses lighter verification (`/drive` Phase 3.0).
- **decide-don't-wait** — the maintainer policy to make and record a defensible call rather than escalate-and-wait, reserving blocking escalation for genuinely un-decidable forks, irreversible actions, or missing access (`/drive`).
- **design-score** — a deterministic 0–100 scorer for a design doc's structural quality, gating `/drive` Phase 2 → 3 before any code is written.
- **hard gate** — the pre-merge check that must pass before merge: CI green, review comments resolved, test-plan boxes ticked, pipeline verified (`/address-pr` §2.a).
- **P0 escape hatch** — the Slack escalation that preempts the normal queue for production-down / customer-blocked / security incidents, bypassing Tier discipline (`/todo`).
- **quality-probe** — a record-and-warn skill that measures per-task code metrics (shellcheck, coverage, complexity, duplication, code-scanning alerts) on touched files into an append-only scoreboard.
- **ratchet** — a discipline where a metric may only hold or improve, never regress; considered as the quality-probe's name but rejected because its posture is record+warn, not a hard gate.
- **record + warn** — a non-blocking posture: record the metric and emit a loud warning on regression, but let the merge proceed (contrast with a hard gate).
- **Slack escalation protocol** — the configured-channel-based gate where `/drive` posts design questions, blockers, and scope checks, tracking replies in `.claude/state/drive-threads.json` (`/drive`, `DRIVE_ESCALATION_CHANNEL_ID`).
