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
  - **Who writes the initial content** (dropped from an earlier draft,
    restored per review): this task ships the *reader* (`epic-status.sh` +
    the skip-when-missing path), not the file's initial content — that's
    filed as its **own task in the hub repo** (the five current epics,
    written by the maintainer or a follow-up session with maintainer
    input). Until that lands, `fetch` hits its normal "file not found"
    branch of the fail-quiet path — same code path as `ROADMAP_TARGET_REPO`
    being unset, just a different cause.
- **Script: `ccxp/scripts/epic-status.sh`** (new file; token-free,
  sourceable per `dev/guidelines.md`'s Script Standards, idempotent):
  - **Cross-repo account scoping (fixes a real gap found in review):**
    `_gh/gh.sh main()` (`_gh/gh.sh:94-101`) always derives its target slug
    from `git remote get-url origin` of `$PWD` (`_gh/gh.sh:38-51`) — it has
    no `--repo` override. `update-roadmap.sh` only gets away with calling it
    for the hub repo because it `cd`s into a real clone first
    (`ccxp/scripts/update-roadmap.sh:132-139`, `roadmap_commit_pr`). This
    script has no clone step (single-file API reads), so a bare `_gh/gh.sh
    api repos/$ROADMAP_TARGET_REPO/...` run from the *consumer* repo's
    working directory would pick a gh account proven to access the
    *consumer* repo, not the hub — silently wrong on a multi-account box.
    Fix: **source** `_gh/gh.sh` (its own header documents this — "lets
    tests source this file and call individual functions... without
    invoking main", `_gh/gh.sh:104-105`) and call
    `_gh_pick_account "$ROADMAP_TARGET_REPO"` directly to get the
    hub-scoped token, then invoke `GH_TOKEN="$tok" gh api ...` /
    `GH_TOKEN="$tok" gh pr list --repo "$ROADMAP_TARGET_REPO" --search ...`
    explicitly — bypassing `main()`'s `$PWD`-derived slug entirely. Every
    cross-repo call (`fetch`, `resolve`'s hub-search fallback, and the PR
    lookup) uses this pattern; **every one also passes an explicit
    `--repo`/repo-qualified argument** — `gh pr list --search <Tid>` alone
    silently scopes to `$PWD`'s repo too.
  - `fetch` — pull `dev/EPICS.md` from `ROADMAP_TARGET_REPO@main` via the
    sourced-`_gh/gh.sh` pattern above against
    `repos/$ROADMAP_TARGET_REPO/contents/dev/EPICS.md` (fail-quiet → prints
    a one-line "epics unavailable" block; never blocks the standup). Reuses
    the env-resolution pattern from `ccxp/scripts/update-roadmap.sh:54-96`
    (already-exported wins, else `~/.claude/.env`) for `ROADMAP_TARGET_REPO`
    itself — a separate concern from the account-scoping fix above.
  - `resolve <Tid>` — status + `claimed_by` from `dev/TODO|PARKING|JOURNAL`
    locally, else from the hub repo via the hub-scoped `gh api` contents
    search above; PR state via `gh pr list --repo <owner/repo> --search
    <Tid> --state all --json number,state` (repo resolved from wherever
    `<Tid>` was found — hub or local). **Unresolvable ID** (typo'd/deleted,
    matches neither local dirs nor the hub search): `resolve` returns a
    distinct `unknown` status rather than silently miscounting it into any
    bucket; `render` surfaces it as `⚠ T<id> unresolved` under its epic.
  - `render` — one markdown block per epic: `E1 — <title>` / `Goal` /
    `N tasks: a Done · b Review · c Coding · d Design · e Blocked/Parked ·
    f Open` (all seven `lifecycle.md:70` statuses get a bucket — the
    previous draft's `Done/Coding/Blocked/Open`-only enumeration would have
    silently mis-bucketed this very task, which is `status: Design`) /
    `Leading: T<id> <status> (PR #n <state>)` / `Deadline: <date> (<k>
    days)` / `⚠ stale: no task under this epic changed in ≥7 days`. Plus a
    `--slack` mode emitting one line per epic.
    - **Staleness, local vs. cross-repo:** for a task file resolved
      *locally* (in this clone's `dev/TODO|PARKING|JOURNAL`), staleness is
      `git log -1 --format=%cd -- <path>` same as any local file. For a
      task resolved only via the hub-repo search (no local clone to `git
      log`), use `gh api repos/<owner>/<repo>/commits?path=<task-file>
      --jq '.[0].commit.committer.date'` instead — the contents API `fetch`
      uses for `EPICS.md` itself returns blob content only, not commit
      history, so it can't answer this on its own.
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
  - **Docs**: `README.md`'s existing "Skill scripts" convention section and
    `ccxp/SKILL.md` (near the Phase 1.3 wiring above) both get a short
    `dev/EPICS.md` format subsection — the same shape `resolve`/`render`
    parse, so `tests/epic-status.bats`'s fixtures and this doc can be
    generated from (or checked against) one source rather than drifting.
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
| `ccxp/scripts/update-roadmap.sh` | `54-96`, `132-139` | env-resolution pattern; the `cd`-into-clone precedent that motivates sourcing `_gh/gh.sh` directly instead |
| `_gh/gh.sh` | `38-51`, `72-88`, `94-101`, `104-105` | sourced (not exec'd) for `_gh_pick_account` — bypasses `main()`'s `$PWD`-derived repo slug for cross-repo calls |
| `dev/EPICS.md` (hub repo, new) | n/a | human-owned per-epic spec this script reads |
| `tests/epic-status.bats` | new | BATS coverage for the new script |
| `README.md` | "Skill scripts" section | gets the `dev/EPICS.md` format subsection (Done criteria) |

## Test plan

- [ ] `bats tests/epic-status.bats` green (fixtures under
      `tests/fixtures/epics/`) — covers `fetch`/`resolve`/`render`
- [ ] `ROADMAP_TARGET_REPO` unset → `render` prints the skip line, exit 0
- [ ] `render --slack` output matches the per-epic one-line format
- [ ] `resolve` on a task ID that exists only in a non-hub repo falls back
      to the `gh api` contents search path
- [ ] `resolve` on a genuinely unresolvable ID (typo/deleted, matches
      neither local dirs nor the hub search) returns `unknown`, and
      `render` surfaces it as `⚠ T<id> unresolved` instead of miscounting it
- [ ] `_gh_pick_account "$ROADMAP_TARGET_REPO"` (sourced, not `main()`) is
      what `fetch`/`resolve`'s cross-repo calls use — a fixture with two
      fake accounts (one hub-scoped, one not) confirms the hub-scoped one
      is picked regardless of `$PWD`'s own origin
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
- [ ] `README.md`'s "Skill scripts" section and `ccxp/SKILL.md` (Done
      criteria bullet above) both document the `dev/EPICS.md` format,
      matching what `tests/epic-status.bats`'s fixtures actually parse
- [ ] Test plan's live-run item confirms a real standup renders `## Epic
      progress`, linked from this task's `## Closed` section at Phase 7

## Notes

- Blocked in practice on the consumer box having `ROADMAP_TARGET_REPO` set
  (tracked as its own task in the consumer repo, not this one) — the script
  must degrade gracefully without it (see Test plan), but the feature only
  delivers value once it is set.
