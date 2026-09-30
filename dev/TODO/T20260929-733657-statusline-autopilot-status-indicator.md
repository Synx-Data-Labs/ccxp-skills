---
status: In Progress
estimation: 30m
source: this conversation, 2026-09-30
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-28
---

# T20260929-733657: Add a one-letter autopilot status indicator to the statusline's `ap:` segment

Design approved in-conversation 2026-09-30 — see Problem below for the
agreed `[r]`/`[b]`/`[s]` design; skipping the separate design PR.

## Problem

- **Type**: feature
- Today the statusline's optional `ap: <elapsed>/<requested>hr <stuck>/<cycle>`
  segment (per `statusline-setup`'s description) gives no at-a-glance signal
  for *which* state the run is in — running normally vs. backing off after a
  stuck `/drive` cycle vs. already stopped.
- Design agreed in conversation:
  - `ap:[r] ...` — running normally (`dev/.autopilot-state.json`'s
    `status == "running"` and `last_outcome != "stuck"`).
  - `ap:[b] ...` — backing off/stuck while still running (`status ==
    "running"` and `last_outcome == "stuck"`).
  - `ap:[s] ...` — stopped (`status == "stopped"`). This one **lingers**: the
    segment does not disappear on stop and has no explicit dismiss/expiry —
    it only goes away when the next `/autopilot` invocation overwrites the
    state file (Phase 1 first-invocation, per `autopilot/SKILL.md`).
- Statusline must key off the state file's `status`/`last_outcome` fields,
  not file presence — the file is gitignored and persists after a run stops
  by design (`autopilot/SKILL.md` Phase 5 leaves it in place, `stop_reason`
  filled in, precisely so `/autopilot status` can still report on it).

## Done criteria

- [ ] Statusline script reads `status`/`last_outcome` from
  `dev/.autopilot-state.json` and prefixes the `ap:` segment with `[r]`,
  `[b]`, or `[s]` per the rules above.
- [ ] No `ap:` segment at all when the state file doesn't exist (autopilot
  never run in this repo) — unchanged from today.
