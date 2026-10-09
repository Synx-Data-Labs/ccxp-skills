---
status: Design
scheduled: 2026-10-12
estimation: 1
source: this conversation, 2026-10-09
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
---

# T20261009-154870: Merge /spinup into /repo-conventions, resolve the mode/setup naming collision

## Problem

- **Type**: feature
- `/spinup` (`spinup/SKILL.md`) is mostly a thin orchestrator around
  `/repo-conventions check` + `sync`, plus one dispatch branch
  (`.env.tpl` present → `/1password-env-setup`) — thin enough that a
  separate standalone skill for it is questionable value over folding it
  into `/repo-conventions` as a new verb (e.g. `bootstrap` or `setup`).
- Separately, `/repo-conventions mode {solo|team}` is a candidate rename
  target to `setup` (so it reads as "set this repo up for solo/team
  convention") — but `setup` as a name would collide with the merged
  orchestration verb above if both land. Needs one coherent verb scheme,
  not two different things both called "setup."
- Default-mode question: should `team` become the implicit default, with
  `solo` scoped explicitly as the escape hatch for legacy repos (vs.
  today's `mode.sh <solo|team>` requiring an explicit choice either way)?
  `mode.sh`'s existing CI-presence check (refuses to enable branch
  protection with no `.github/workflows/*.yml` present) needs to degrade
  gracefully here rather than hard-block a fresh repo if team becomes the
  default path.
- Gap: neither `/spinup` nor `/repo-conventions` ever initializes or syncs
  `dev/TODO/queue.md` on a fresh repo — only `/todo sweep` does
  (`todo/SKILL.md`'s "adds missing, strikes closed/parked"). A repo spun
  up with existing `dev/TODO/*.md` files but no `queue.md` is left
  uninitialized. Closing this means deciding whether the merged
  verb dispatches `/todo sweep` as a step.
- Open design question carried into `/incept`: does `/spinup` disappear
  entirely, or survive as a one-line alias for discoverability (people
  reaching for "spin up a repo" as a verb)?
- Done = a design (via `/incept`/`/drive`) that lands one coherent verb
  scheme in `/repo-conventions` covering: convention check/sync, the
  solo/team branch-policy switch (replacing today's `mode`), the former
  `/spinup` orchestration (CLAUDE.md/guidelines.md bring-online +
  `.env.tpl` dispatch), and the `/todo sweep` queue.md gap — with
  `/spinup` either removed or reduced to a pointer.
