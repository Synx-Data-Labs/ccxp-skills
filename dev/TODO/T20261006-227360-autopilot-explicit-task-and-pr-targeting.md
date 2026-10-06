---
status: Open
estimation: 1
source: conversation with Shine Zhang, 2026-10-06
related: T20260919-266165
---

# T20261006-227360: /autopilot must dispatch /drive at an explicit task, and /drive's own PR must always be addressed by explicit PR number

## Problem

- **Type**: feature
- `autopilot/SKILL.md` Phase 3 currently dispatches `/drive` bare (auto-pick)
  every cycle: "Dispatch `/drive` (bare auto-pick) via the `Agent` tool." Task
  selection is opaque to `/autopilot` — it happens inside the dispatched
  sub-agent's own `/todo next` call, cycle to cycle, with no visibility from
  the orchestrator.
  - Change `/autopilot` Phase 3 to resolve the next task itself (`/todo
    sweep` + `/todo next`, the same logic `/drive` Phase 1's auto-pick
    already runs) and dispatch `/drive T<id>` with the explicit id each
    cycle — so task selection is visible/loggable at the orchestrator level
    and stays pinned to the current queue/priority ordering `/autopilot`
    itself can see.
  - `/autopilot`'s existing `resume` path (Phase 0.1) already does this for
    one resumed cycle via `last_task` — this generalizes that to every
    cycle, not just resume.
  - Needs design: `drive/SKILL.md`'s own `## Argument` section documents
    Phase 0 ("drain open PRs first", bare `/address-pr` call) as running
    independently of auto-pick vs. explicit-task mode — confirm passing a
    task id to `/drive` preserves that, and only replaces Phase 1's
    task-selection step.
- `drive/SKILL.md` Phase 5 (~line 430: "Use `/address-pr <PR number>` ...
  Do not duplicate its logic here") already documents calling `/address-pr`
  with an explicit PR number for the PR `/drive` itself just created, but
  this isn't hard-gated — audit every path through `drive/SKILL.md` that
  reaches Phase 5 and confirm none of them can fall through to a bare
  `/address-pr` call for `/drive`'s own just-created PR. A bare call
  re-triggers oldest-first auto-pick over the *whole* backlog, which could
  address a different PR than the one this `/drive` cycle is actually
  responsible for.
  - This matters more now that a GitHub App bot gates PR approval
    (`pr-approve.yml`) — `/address-pr` needs to be working the exact PR the
    current `/drive` cycle owns, not whichever is oldest.
- Context: surfaced during `/autopilot`'s first 24h run in
  synxdb-build-pipeline on 2026-10-06. That cycle's bare `/address-pr` call
  turned out to be `/drive` Phase 0's documented backlog-drain (correctly
  handling PR #2499 and its claim-PR #3690) — not a live bug — but the user
  wants both of the above hardened/made explicit given the new bot-gated
  approval flow.
- **Done** when: `/autopilot` passes an explicit `T<id>` to every dispatched
  `/drive` cycle (not just on resume), and `drive/SKILL.md` Phase 5 cannot be
  reached with an unresolved/bare `/address-pr` call for `/drive`'s own PR.
