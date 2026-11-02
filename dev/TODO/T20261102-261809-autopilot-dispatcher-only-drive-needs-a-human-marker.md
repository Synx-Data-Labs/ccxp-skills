---
status: Design
estimation: 1
source: conversation 2026-11-02 (owner approved the redesign proposal, "n83 yes")
related: [T20261102-902081, T20261028-151063, T20260922-195629, T20261006-391349, T20260930-132964]
description: autopilot only calls /drive each cycle; owner-gated tasks carry a "needs a human" marker in their own file instead of a per-clone skip list
claimed_by: cc1-ecc09c93:9285c59f3189ba8b
claimed_role: interactive
scheduled: 2026-11-02
---

# T20261102-261809: autopilot: dispatcher only calls /drive; owner-gated tasks carry a "needs a human" marker in the task file (no skip list)

## Problem

- **Type**: feature
- **Owner's words (2026-11-02)**: autopilot should not scan every task each time; each cycle it should just call `/drive`. The state exists to explain why autopilot could not finish a task, not to skip tasks before choosing.
- **Facts observed 2026-11-02 in the owner's pointer repo**:
  - Autopilot keeps `skip_ids` / `needs_attention` in `dev/.autopilot-state.json`: per clone, gitignored, invisible to other sessions.
  - `ap-cap` wipes `skip_ids` at each day rollover (`autopilot/scripts/autopilot-state.sh`, the `.day != $d` branch, about line 195). The next day the dispatcher would re-dispatch a `/drive` agent for each of about 51 owner-gated tasks: about 50k tokens each, hours of cycles, the same answer every time.
  - The owner's loop sat dead for 2 days 16 hours while the HUD said `next loop due` (the HUD part is already fixed: T20261102-902081, shipped in #541; a dead loop now shows as stalled).
  - The dispatcher in the main session walks `/todo next`'s ranking and filters the whole queue itself each cycle (`autopilot/SKILL.md`, Phase 3 "Resolve the pick").

## Design (proposed; settle the open points in `/incept` or the design PR)

- **Durable marker in the task file**: a task a driver cannot proceed on for owner-only reasons carries the marker on main, in its own file.
  - The frontmatter `status:` keeps its leading token and gains the suffix `— needs a human [<kind>]: <short reason>` (after a space), with kind one of `blocked|decision|external`. The grammar is fixed so it can be scanned.
  - `autopilot-state.sh eligible` already refuses the substring "needs a human".
- **Driver writes it, not the dispatcher**: the `/drive` sub-agent that ends with `NEEDS-ATTENTION` lands the marker as a tiny docs-only status-change PR through the normal gates (like the claim PR, auto-merge tier).
- **Owner un-gates by editing**: removing the suffix (or answering the decision) returns the task to the pool, with no manual `unskip`.
- **Dispatcher simplification**: it stops using `skip_ids` as a gate and stops pre-walking the queue. Each cycle it runs `/drive --auto-selected` once.
  - OPEN POINT: `todo-next.sh` today skips only Done/Revisit/Parked and peer-claimed tasks, so a bare `/drive` would pick the same gated task #1 forever. Recommend a `--skip-needs-human` behaviour used when `--auto-selected`.
  - Check `todo-next.sh`, `/drive` Phase 1 and `autopilot-state.sh eligible` and keep a single shared definition of "needs a human".
- **State file shrinks**: it keeps only run counters, last outcome and wake time. `needs_attention` and the HUD queue breakdown (blocked / decision / external counts) are derived by scanning task-file statuses (cheap, no agents).
- **Cheap pre-check stays in the dispatcher**: if nothing is pickable it records `idle` without dispatching an agent.

## Migration

- The owner's pointer repo has 51 queued tasks that are currently owner-gated. A separate one-time job marks them with the new suffix in pointer; it is not part of this task's code.

## Slices and tests (bats)

- Marker grammar and parser.
- `eligible` and `todo-next` behaviour with the marker.
- Driver-side marking step in the autopilot prompt and the `/drive` escalation path.
- Dispatcher simplification (one `/drive --auto-selected` per cycle).
- HUD counts derived from task files.
- State-file schema and doc updates.
- README / SKILL.md updates for autopilot, drive and todo.

## Done when

- A day rollover causes zero extra agent dispatches for gated tasks.
- A gated task is never picked by autopilot until its marker is removed.
- The owner can see why from the task file itself.
- The HUD counts come from task files.
- Tests green.

## Related

- T20261102-902081: HUD `next loop due` fix (shipped in #541; a dead loop shows as stalled).
- T20261028-151063: /autopilot on/off redesign (journal).
- T20260922-195629: autopilot waiting-outcome ambiguity (journal).
- T20261006-391349: autopilot pause/resume/stop (journal).
- T20260930-132964: autopilot dispatches from its own clone (journal).
