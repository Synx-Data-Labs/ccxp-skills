---
status: Open
estimation: 1d
source: maintainer conversation 2026-09-11 — standups are task-focused and never surface epic-level progress
related: T20260906-306082
description: Read a hub-repo dev/EPICS.md and add a token-free "Epic progress" block to the ccxp daily standup + Slack
---

# T20260911-347027: `/ccxp` standup should report epic-level progress from the hub repo's `dev/EPICS.md`

## Problem

- The hourly `/ccxp` cron already produces a daily standup (Phase 1.3 `daily-summary.md`
  and 1.4 Slack), but every section is task- or PR-granular (Resolved, Nightly, PRs needing
  attention, Top 5, Weekly focus). Nothing rolls tasks up to the 3-5 standing goals the
  maintainer actually steers by (e.g. "fix the build container for the pgrx bump",
  "SOC 2 Type 1 by 2026-09-30", "Cloudsmith egress ≤ $1K/mo").
- Result: the maintainer has to re-derive epic status by hand from `queue.md` + task
  frontmatter across two repos (observed 2026-09-11 — took an interactive session ~30
  min to assemble what the standup should have said in five lines).
- `ROADMAP.md` (hub repo) is the wrong shape for this — it is week-by-week IPM history,
  updated only Mondays via Phase 2a.5b, and has lapsed twice.
- Done looks like: every standup carries a short `## Epic progress` section (one block
  per epic: goal, task counts by status, most-advanced in-flight item, deadline
  countdown, stale flag) and Slack gets one line per epic. Generated deterministically,
  no LLM judgment, read-only against the hub repo.

## Plan

- **Spec file (hub repo, human-owned)**: `dev/EPICS.md` in `ROADMAP_TARGET_REPO`.
  Per epic: `### E<n> — <title>`, a `Goal:` line, a `Done when:` line, optional
  `Deadline: YYYY-MM-DD`, and a bullet list of task IDs (`- T<id>` — any repo; the
  consumer repo's own tasks resolve locally, others via `gh api`). No status rows in
  the file — status is derived at standup time so the file never drifts.
  Filed on the hub side as synxdb-team T20260911-279584 (initial content for the
  five current epics).
- **Script**: `ccxp/scripts/epic-status.sh` (token-free, sourceable, idempotent):
  - `fetch` — pull `dev/EPICS.md` from `ROADMAP_TARGET_REPO@main` via
    `_gh/gh.sh api repos/.../contents/dev/EPICS.md` (fail-quiet → prints a one-line
    "epics unavailable" block; never blocks the standup). Reuse the env-resolution
    pattern from `update-roadmap.sh` (already-exported wins, else `~/.claude/.env`).
  - `resolve <Tid>` — status + `claimed_by` from `dev/TODO|PARKING|JOURNAL` locally,
    else from the hub repo via `gh api` contents search; PR state via
    `gh pr list --search <Tid> --state all --json number,state`.
  - `render` — one markdown block per epic:
    `E1 — <title>` / `Goal` / `N tasks: a Done · b Coding · c Blocked · d Open` /
    `Leading: T<id> <status> (PR #n <state>)` / `Deadline: <date> (<k> days)` /
    `⚠ stale: no task under this epic changed in ≥7 days` (from git log on the
    task files). Plus `--slack` mode emitting one line per epic.
- **Skill wiring** (`ccxp/SKILL.md`):
  - Phase 1.3: new `## Epic progress` section between `Top 5 next` and
    `Weekly focus progress`, pasted from `epic-status.sh render`. Skip with a
    one-line note when `ROADMAP_TARGET_REPO` is unset (same behaviour class as 2a.5b).
  - Phase 1.4: append the `--slack` lines to the standup post.
  - Phase 2b (Friday retro): may propose an `EPICS.md` edit (new task IDs discovered
    under an epic, epic done) as a small PR to the hub repo using the existing
    `update-roadmap.sh clone` / `commit-pr` mechanism. This is the ONLY write path;
    the daily path is read-only.
- **`/todo next` scoring (optional slice)**: small readiness bonus for tasks listed
  under an epic in the top-priority section, so the queue reflects the maintainer's
  stated priorities instead of them being restated every session.
- Tests: BATS for `epic-status.sh` (parse fixture EPICS.md, resolve local + missing
  IDs, render with/without deadline, stale flag, fail-quiet on missing env).

## Test plan

- [ ] `bats tests/epic-status.bats` green (fixtures under `tests/fixtures/epics/`)
- [ ] `ROADMAP_TARGET_REPO` unset → `render` prints the skip line, exit 0
- [ ] Live: run `epic-status.sh render` from a synxdb-build-pipeline clone against
      synxdb-team `dev/EPICS.md`; all five epics resolve, cross-repo IDs included
- [ ] One cron-mode `/ccxp` standup on a consumer repo shows the new section + Slack lines

## Done criteria

- [ ] `ccxp/scripts/epic-status.sh` exists, sourceable, BATS-covered
- [ ] `ccxp/SKILL.md` Phase 1.3/1.4 reference it; Phase 2b documents the weekly
      write path
- [ ] `README.md` / `ccxp/SKILL.md` document the `dev/EPICS.md` format for hub repos
- [ ] First real standup with an `## Epic progress` section linked from `## Closed`

## Notes

- Blocked in practice on the consumer box having `ROADMAP_TARGET_REPO` set
  (synxdb-build-pipeline T20260906-306082) — the script must degrade gracefully
  without it, but the feature only delivers value once it is set.
