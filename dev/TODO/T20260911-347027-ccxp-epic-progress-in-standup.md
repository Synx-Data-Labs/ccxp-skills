---
status: Design
estimation: 1d
source: maintainer conversation 2026-09-11 — standups are task-focused and never surface epic-level progress
related: T20260906-306082
description: Read a hub-repo dev/EPICS.md and add a token-free "Epic progress" block to the ccxp daily standup + Slack
claimed_by: cc1-9a4074da:94a83ff0e786a885
claimed_role: interactive
scheduled: 2026-09-14
---

# T20260911-347027: `/ccxp` standup should report epic-level progress from the hub repo's `dev/EPICS.md`

## TLDR

- **Type**: feature
- **Problem**: the hourly `/ccxp` standup (`ccxp/SKILL.md:294`) is entirely task-/PR-granular — nothing rolls up to the 3-5 standing goals the maintainer actually steers by, so epic status has to be re-derived by hand.
- **Solution**: a token-free, sourceable `ccxp/scripts/epic-status.sh` that reads a human-owned `dev/EPICS.md` in the hub repo and renders a deterministic `## Epic progress` block for the standup doc (Phase 1.3) and one Slack line per epic (Phase 1.4); read-only on the daily path, with an optional Friday-retro write path (Phase 2b) to keep `EPICS.md` current.

## Problem

- `ccxp/SKILL.md` Phase 1.3 (`ccxp/SKILL.md:294`) already produces a daily
  `dev/JOURNAL/YYYY-MM-DD-daily-summary.md` with four content sections —
  Resolved, Nightly, Attention, **Top 5 next** (`ccxp/SKILL.md:323`) — plus a
  **Weekly focus progress** section (`ccxp/SKILL.md:329`). Every one of them
  is task- or PR-granular.
- Nothing rolls tasks up to the 3-5 standing goals the maintainer actually
  steers by (e.g. "fix the build container for the pgrx bump", "pass the
  compliance audit by Q3", "keep vendor egress under budget").
- **Evidence**: observed 2026-09-11 — reconstructing "what's epic status
  today" from `queue.md` + task frontmatter across two repos took an
  interactive session ~30 minutes to assemble five lines a standup should
  have produced automatically.
- `ROADMAP.md` (hub repo, updated by `ccxp/scripts/update-roadmap.sh` at
  Phase 2a.5b) is the wrong shape for this — it's week-by-week IPM history,
  written only on Mondays, and has lapsed twice; it has no per-epic rollup
  and isn't read at standup time at all.

## Context

- **Feature** — this plugs into the existing hourly `/ccxp` cron
  (`ccxp/SKILL.md` Phase 1.3 daily-summary generation, Phase 1.4 Slack post)
  and the existing token-free hub-repo pattern already used by
  `ccxp/scripts/update-roadmap.sh:54-96` (env-var resolution: an
  already-exported `ROADMAP_TARGET_REPO` wins, else `~/.claude/.env`).
- No prior art in this repo for a *read-only, deterministic* cross-repo
  status rollup — `update-roadmap.sh` is write-only (commits a PR to the hub
  repo at IPM time), so this is new machinery, not a reuse of an existing
  script.
- Consumer-repo dependency: the feature only produces output once
  `ROADMAP_TARGET_REPO` is set on a given box — that's a separate,
  per-consumer-repo concern, tracked outside this task (see Notes).

## Plan

- **Spec file (hub repo, human-owned): `dev/EPICS.md`** in
  `ROADMAP_TARGET_REPO`. Per epic: `### E<n> — <title>`, a `Goal:` line, a
  `Done when:` line, optional `Deadline: YYYY-MM-DD`, and a bullet list of
  task IDs (`- T<id>` — any repo; a consumer repo's own tasks resolve
  locally, others via `gh api`). No status rows in the file — status is
  derived at standup time so the file never drifts.
- **Script: `ccxp/scripts/epic-status.sh`** (new file; token-free,
  sourceable per `dev/guidelines.md`'s Script Standards, idempotent):
  - `fetch` — pull `dev/EPICS.md` from `ROADMAP_TARGET_REPO@main` via
    `_gh/gh.sh api repos/.../contents/dev/EPICS.md` (fail-quiet → prints a
    one-line "epics unavailable" block; never blocks the standup). Reuses
    the env-resolution pattern from `ccxp/scripts/update-roadmap.sh:54-96`
    (already-exported wins, else `~/.claude/.env`).
  - `resolve <Tid>` — status + `claimed_by` from `dev/TODO|PARKING|JOURNAL`
    locally, else from the hub repo via `gh api` contents search; PR state
    via `gh pr list --search <Tid> --state all --json number,state`.
  - `render` — one markdown block per epic: `E1 — <title>` / `Goal` /
    `N tasks: a Done · b Coding · c Blocked · d Open` / `Leading: T<id>
    <status> (PR #n <state>)` / `Deadline: <date> (<k> days)` / `⚠ stale: no
    task under this epic changed in ≥7 days` (from `git log` on the task
    files). Plus a `--slack` mode emitting one line per epic.
- **Skill wiring (`ccxp/SKILL.md`)**:
  - Phase 1.3 (after `ccxp/SKILL.md:323`'s Top 5 next, before
    `ccxp/SKILL.md:329`'s Weekly focus progress): new `## Epic progress`
    section, pasted from `epic-status.sh render`. Skip with a one-line note
    when `ROADMAP_TARGET_REPO` is unset — same behaviour class as the
    existing 2a.5b skip.
  - Phase 1.4: append the `--slack` lines to the standup post.
  - Phase 2b (`ccxp/SKILL.md:837`, Friday retro): may propose an
    `EPICS.md` edit (new task IDs discovered under an epic, epic done) as a
    small PR to the hub repo, reusing `update-roadmap.sh`'s existing
    `clone` / `commit-pr` mechanism. This is the **only** write path — the
    daily path (Phase 1.3/1.4) stays read-only.
  - `/todo next` scoring (optional slice, only if time remains): a small
    readiness bonus for tasks listed under an epic in the top-priority
    section, so the queue reflects the maintainer's stated priorities
    without restating them every session. Cut this slice first if the 1d
    budget is tight — it's additive, not required for Done criteria below.

### Alternatives considered and rejected

- **Extend `ROADMAP.md` instead of a new `EPICS.md`**: rejected —
  `ROADMAP.md` is IPM-cadence history (written once/week by
  `update-roadmap.sh`), not a live per-epic status source; overloading it
  would mean either writing to it daily (defeats its own "written only
  Mondays" invariant) or reading stale data at standup time.
- **Have the LLM summarize epic status from `queue.md` each standup**:
  rejected — non-deterministic, burns tokens every hourly tick for a
  computation that's fully mechanical (task counts, PR state, staleness by
  git-log date), and the maintainer asked for exactly the token-free
  approach `update-roadmap.sh` already establishes as the house style.
  Deterministic rendering can be spot-checked and diffed like any script
  output.
- **Make Phase 2b the only place `EPICS.md` is ever read** (no daily
  render): rejected — the whole point is a maintainer-visible signal on the
  cadence they actually watch (hourly standup), not once a week.

## Root cause

- No bug here — this is a gap analysis: why epic-level rollup doesn't exist
  today, not why something broke.
- The standup (`ccxp/SKILL.md:294`) grew task/PR-first from the start — its
  four content sections (Resolved, Nightly, Attention, Top 5 next) all key
  off individual `T<id>` files and PRs; there was never a rollup dimension
  because no spec file expressed "these N tasks together are one epic."
- `ROADMAP.md` (written by `ccxp/scripts/update-roadmap.sh`) is the nearest
  existing analog but serves a different cadence and audience — Monday-only
  IPM history, not a live per-epic status a maintainer reads hourly — so it
  was never wired into Phase 1.3's daily render.
- Net: this is new capability, not a regression — introduced by omission,
  not by a change that broke something (deliberate scope decision at the
  time `ccxp/SKILL.md`'s daily-summary shape was set, not an oversight
  discovered later).

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `ccxp/scripts/epic-status.sh` | new | `fetch`/`resolve`/`render` — the token-free epic-rollup script this task adds |
| `ccxp/SKILL.md` | `294`, `323-329` | Phase 1.3 daily-summary generation; insertion point for `## Epic progress` |
| `ccxp/SKILL.md` | `837` | Phase 2b Friday retro; documents the weekly `EPICS.md` write path |
| `ccxp/scripts/update-roadmap.sh` | `54-96` | env-resolution pattern (`ROADMAP_TARGET_REPO`) reused by `epic-status.sh` |
| `dev/EPICS.md` (hub repo, new) | n/a | human-owned per-epic spec this script reads |
| `tests/epic-status.bats` | new | BATS coverage for the new script |

## Test plan

- [ ] `bats tests/epic-status.bats` green (fixtures under
      `tests/fixtures/epics/`) — covers `fetch`/`resolve`/`render`
- [ ] `ROADMAP_TARGET_REPO` unset → `render` prints the skip line, exit 0
- [ ] `render --slack` output matches the per-epic one-line format
- [ ] `resolve` on a task ID that exists only in a non-hub repo falls back
      to the `gh api` contents search path
- [ ] Live: run `epic-status.sh render` from a consumer-repo clone against
      the hub repo's `dev/EPICS.md`; all epics resolve, cross-repo IDs
      included
- [ ] One cron-mode `/ccxp` standup on a consumer repo shows the new
      section + Slack lines (post-merge, manual verification)

## Done criteria

- [ ] `ccxp/scripts/epic-status.sh` exists, sourceable, BATS-covered —
      `tests/epic-status.bats`
- [ ] `ccxp/SKILL.md` Phase 1.3 (near `ccxp/SKILL.md:323`) and Phase 1.4
      reference `epic-status.sh render`/`--slack`
- [ ] `ccxp/SKILL.md` Phase 2b (`ccxp/SKILL.md:837`) documents the weekly
      `EPICS.md` write path
- [ ] `tests/epic-status.bats` fixture format matches what `README.md` /
      `ccxp/SKILL.md` document for `dev/EPICS.md` — same format, one source
- [ ] Test plan's live-run item confirms a real standup renders `## Epic
      progress`, linked from this task's `## Closed` section at Phase 7

## Notes

- Blocked in practice on the consumer box having `ROADMAP_TARGET_REPO` set
  (tracked as its own task in the consumer repo, not this one) — the script
  must degrade gracefully without it (see Test plan), but the feature only
  delivers value once it is set.
