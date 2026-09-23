---
name: eta
description: Use when the user explicitly asks for an ETA / projected finish time on the current task (or an explicit T<id>) — elapsed vs. remaining estimation, in the local timezone or an override
disable-model-invocation: false
argument-hint: "[T<id>] [--tz <IANA-zone>]"
---

Report a projected finish time for a task: reads its `estimation:` bucket,
derives a start time from the git commit that set its `claimed_by:` line, and
prints elapsed / remaining / projected-finish. No argument reports on
whichever task this clone currently holds (same `claimed_by:` match the
statusline uses); an explicit `T<id>` reports on that task regardless of who
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
2. **Read `estimation:`** from the task's frontmatter and map the bucket to a
   **literal wall-clock duration**: `15m/30m/1h/2h/4h` map to themselves,
   `1d`→24h, `2d`→48h, `1w`→7d.

   **Assumption, stated plainly**: this is calendar time, not working-hours
   time — no repo convention currently defines the buckets as
   workday-relative (verified: no existing script converts `estimation:` to
   a duration), so the simplest well-defined reading was chosen for v1. A
   `1d` estimate projects a finish 24 real hours out, not "one 8-hour
   workday from now." If that turns out to be the wrong default in practice,
   revisit with a dedicated task rather than silently drifting.
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
   all — so there's no such commit to find), print the estimation bucket
   with **no** elapsed/remaining/projected-finish math, rather than
   guessing or failing silently.
5. **Report**: elapsed (start → now), remaining (duration − elapsed;
   `overdue by <Δ>` instead of a negative when past due), and the projected
   finish timestamp, rendered in the local system timezone by default or
   `--tz`'s zone when given.

## Example

```
$ /eta
T20260922-453135
  estimation: 2h
  elapsed:    0h6m
  remaining:  1h53m
  projected finish: 2026-09-23 01:04 PDT
```
