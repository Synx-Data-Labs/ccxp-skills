---
name: eta
description: Use when the user explicitly asks for an ETA / projected finish time on the current task (or an explicit T<id>) — elapsed vs. remaining estimation, in the local timezone or an override
disable-model-invocation: false
argument-hint: "[T<id>] [--tz <IANA-zone>]"
---

Report a projected finish time for a task: reads its `estimation:` points
value, derives a start time from the git commit that set its `claimed_by:`
line, and prints elapsed / remaining / projected-finish. No argument uses
whichever task this clone holds (same `claimed_by:` match as the
statusline); an explicit `T<id>` reports on that task regardless of who
claimed it.

## Argument

```
scripts/eta.sh [T<id>] [--tz <IANA-zone>] [--repo-root DIR]
```

- `T<id>` (optional) — report on this task instead of the current clone's
  claimed task.
- `--tz <IANA-zone>` (optional) — render the projected finish time in this
  zone instead of the local system timezone (e.g. `--tz America/New_York`).
  Validated against the system's IANA tzdata (`/usr/share/zoneinfo`) — an
  unrecognized zone exits 2 with a clear error rather than silently
  rendering in UTC (GNU `date` itself would accept a bad `TZ` string with
  exit 0, so `date`'s own exit code can't be trusted for this).
- `--repo-root DIR` (optional, mainly for tests) — repo root to resolve
  `dev/TODO/` and git history from; defaults to the current working
  directory.

## Workflow

```bash
bash ../eta/scripts/eta.sh
```

1. **Resolve the task.**
   - Explicit `T<id>` given → look it up directly under `dev/TODO/`.
   - No argument → resolve via `claimant_id` (`_session/claimant-id.sh`) and
     grep `dev/TODO/*.md` frontmatter for a `claimed_by:` line matching this
     clone's id — the same lookup
     `statusline-setup/scripts/statusline-command.sh` uses for the `TASK:`
     segment of the statusline, so the two always agree on "what's current."
   - Neither resolves → exit 1 with `no current task` (never a silent empty
     output).
2. **Read `estimation:`** — a bare Fibonacci-style point, one of
   `{1, 2, 3, 5, 8}` (a leftover duration-bucket string is rejected, not
   silently accepted). Convert it to a **literal wall-clock duration**:
   `projected_hours = points * hours_per_point`.
   - `hours_per_point` is read from `dev/velocity.json` (written every
     `/retro` run from real completed-task history).
   - A missing file, or a missing/non-numeric field, both fall back to the
     same flat bootstrap default `/retro` itself uses on a zero-sample
     window: `hours_per_point: 1` — never an error.

   **Assumption, stated plainly**: this is calendar time, not working-hours
   time, so the simplest well-defined reading was chosen. A `3`-point
   estimate at the bootstrap ratio projects a finish 3 real hours out, not
   "3 points' worth of an 8-hour workday." Revisit with a dedicated task
   rather than silently drifting if that's the wrong default in practice.
3. **Derive a start time**: `git log -S"claimed_by: <value>"
   --format=%aI -- <task-file>`, oldest match — the commit that first landed
   the current `claimed_by:` line. Every claim path in this repo
   (`_session/task_claim.sh acquire`, `/drive` Phase 1's claim PR, `/claim`)
   lands that line in its own dedicated commit, so its author date is a
   reliable "work started" proxy — `task_claim.sh` never writes a separate
   timestamp field (confirmed: `_tc_acquire`, `_session/task_claim.sh:525-546`).
4. **Fallback — start time unknown.** If `git log -S` finds no match (most
   commonly: the repo runs `drive/SKILL.md`'s `CCXP_PEER_MODE=0` opt-out,
   which flips only `status:` on claim and never touches `claimed_by:` at
   all — so there's no such commit to find), print the estimation points
   value (and its converted duration) with **no**
   elapsed/remaining/projected-finish math, rather than guessing or failing
   silently.
5. **Report**: elapsed (start → now), remaining (duration − elapsed;
   `overdue by <Δ>` instead of a negative when past due), and the projected
   finish timestamp, rendered in the local system timezone by default or
   `--tz`'s zone when given.

## Example

```
$ /eta
T20260922-453135
  estimation: 2
  elapsed:    0h6m
  remaining:  1h53m
  projected finish: 2026-09-23 01:04 PDT
```
