# `_ipm/` — current-iteration helpers

Shared helpers for locating the active weekly IPM and stamping a task's iteration.
Token-free and deterministic (date injected via `IPM_TODAY` for tests).

## Scripts

| Script | Purpose | Notes |
|--------|---------|-------|
| `current.sh [journal-dir]` | Print the path of the newest **committed** `*-ipm-weekly.md`, staging-aware (skips the pre-IPM staging stub `/stage` writes; date-guards future files). Prints empty if none. | Sourceable: `_ipm_current`. See T20260604-194697. |
| `stamp-scheduled.sh <task-file> [current\|next] [journal-dir]` | Stamp a task file's `scheduled:` YAML frontmatter with the Monday of the current (default) or next iteration. Prints the effective date. | See below. T20260626-190842. |

## `stamp-scheduled.sh`

Resolves the iteration Monday via a **token-free-first 3-tier hybrid**, then writes
it into the task file's frontmatter:

1. **IPM file** — `current.sh` (no token). Monday = the committed IPM filename date.
2. **Project API** — `$STAMP_ITER_HELPER` (default `_session/iteration.sh`), the board's
   Iteration field. Token-gated; empty without a PAT.
3. **next-Monday** — computed from today (`IPM_TODAY` or system): next week's Monday.

`next` mode adds 7 days to whatever tier resolved (iterations are weekly Mondays, so
current + 7 == next). The write is **update-forward-only** — an existing later
`scheduled:` is never moved backward; an absent one is inserted after `status:`.

**Best-effort:** a non-YAML/legacy task file is left untouched (exit 0, no output);
a missing task-file argument is a usage error (exit 64). It never hard-fails a caller.

**Callers:** `/rca` (Step 6, `current`), `/retro` (Phase 4a action items, `current`),
`/address-pr` (follow-up doc-conformance task, `next`), `/drive` (blockers `current`,
follow-ups `next`). This is the single primitive those creators use so a task placed in
an iteration always carries a matching `scheduled:` (the desync T20260626-190842 fixed).

### Test injection

- `IPM_TODAY=YYYY-MM-DD` — "today" for `current.sh` and the next-Monday tier.
- `STAMP_ITER_HELPER=<cmd>` — overrides the Project-API tier (e.g. a fixture stub
  printing a date, or `true` for "no iteration").

Tests: `tests/ipm_current.bats`, `tests/stamp_scheduled.bats`.
