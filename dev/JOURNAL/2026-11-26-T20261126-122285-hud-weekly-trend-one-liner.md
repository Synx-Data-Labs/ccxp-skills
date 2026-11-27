---
status: Done
estimation: 3
source: owner request 2026-11-26 (conversation), design approved in-conversation 2026-11-26
type: feature
description: HUD weekly trend one-liner for queue, support and autopilot
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261126-122285: HUD weekly trend one-liner (queue, support, AP)

## TLDR

- **Type**: feature
- **Problem**: the queue cell shows three rolling-window maxima (last month / last week / this week); the owner wants the general trend of remaining tasks, with the same view for support and the autopilot.
- **Solution**: a read-only helper `hud/scripts/hud-trend.sh` printing one line per domain (Monday-aligned weekly buckets, stock plus flow, block sparkline, delta vs last week) and a cached HUD trend row fed by it.

## Problem

- Owner, 2026-11-26: "I want to change the status for the QUEUE for last month, last week, and this week. Is there a better way to indicate that? It's like a weekly histogram, thoughts? I want to see the general trend of remaining tasks in the queue.md. Similar stats for the support, and even maybe the AUTOPILOT stats. I want to have a consistent way to see trend."
- Then: "I like the hud one-liner, let's create a task and drive it to finish".
- Today's evidence: the queue band shows `max 61/74/83 ▲` (`hud/README.md` "Queue high watermark"), a three-point maximum with no stock-versus-flow and nothing comparable for support or AP.

## Context

- The HUD already has cached, detached-refresh helpers to copy: `hud/scripts/hud-nightly.sh` (gh, TTL, lock dir) and `hud/scripts/hud-queue-hwm.sh` (git-history backfill, `_hw-ref`).
- The band is built in `hud/model.ts` `bandRows`; details in `detailRows`; data in `hud/scripts/hud-data.sh`.
- Sources already exist: git history of `dev/TODO/queue.md`, `gh issue list` (the `issues.repo` config key), `dev/.autopilot-history.jsonl` and the state file's `.holds`.

## Solution

- `hud/scripts/hud-trend.sh` (sourceable, function-wrapped, CLI under a direct-execution guard):
  - Monday-aligned UTC buckets: the last 5 full weeks plus the current partial week (`*`).
  - One line per domain: `Queue 172 ▇▇▆▆▅▅*  -9 vs last wk  (in 14 / out 23)`; sparkline scaled 0..max per line.
  - Queue: one `git log -p` pass of the queue file (running count, ids added and closed per commit; a reorder nets to zero).
  - Support: `gh issue list --state all` createdAt/closedAt, closed counts as delivered.
  - AP: history jsonl for merged and cycles per week; holds is the one stored series, a weekly snapshot line appended only when absent.
  - Views: `--line` (default), `--table`, `--hist`, `--json`.
- HUD integration: `hud-trend-json` answers from a cache (10 minutes), one detached refresh, no network on a render; `hud-data.sh` adds `trend`; `model.ts` draws a bottom `trend` row and a `TREND` details section; config key `trend` (default on).
- Alternatives rejected:
  - Storing weekly snapshots for everything: history already reproduces queue, support and AP flow; only holds cannot be recomputed.
  - Putting the three lines in the one-row band: three lines of about 70 columns do not fit; the band gets the short forms in its own row and details the full lines.
  - A new `fields` entry: an old explicit `fields` list would silently hide it; a `trend` key like `version` does not.

## Test plan

- [x] BATS `tests/hud_trend.bats`: bounds, queue history (reorder, future commits, empty file, no file), support fixtures (empty, malformed), AP history, holds snapshot, the three views, missing and failing sources, cache TTL, tamper-proof cache, `hud-data.sh` key.
- [x] TS tests in `hud/pure.test.ts`: band row, narrow drop order, config switch, `parseHelper` sanitising, details section.
- [x] Real output against the synxdb-build-pipeline repo, read-only, pasted in the PR description.

## Done criteria

- [x] One line per domain with the agreed format: `tests/hud_trend.bats` "line: all three domains".
- [x] Missing sources degrade to a dash: `tests/hud_trend.bats` "line: a missing source", "nothing at all", "gh failing".
- [x] No network on a render, cached for minutes: `tests/hud_trend.bats` "hud-trend-json" tests.
- [x] `--table` and `--hist` views: `tests/hud_trend.bats` "table", "hist".
- [x] HUD band and details wiring: `hud/pure.test.ts` "trend:" tests, `tests/hud_trend.bats` "hud-data".
- [x] `hud/README.md` "Trend band" and `hud/HELP.md` topic `trend`: `tests/hud_help.bats`.
- [x] No release, version bump or tag in this PR (the owner decides).

## Closed (2026-11-26)

- Shipped in the HUD trend PR (number in the PR list for branch `t20261126-122285-hud-trend`); claim landed in #788.
- Met: all done criteria above; the BATS suite `tests/hud_trend.bats` (31 cases) and the TS cases in `hud/pure.test.ts` (run through a local shim; the claude-code runner is not available here).
- Quality regression (shellcheck_info, max_fn_lines, file_loc): a new 380-line helper with long jq programs (info-level SC1091/SC2016 only, same as sibling hud scripts); the jq filters are single expressions, so function length counts them as one body.
- Unverified: the band row in a live Claude Code session (needs the mod runtime); the real-data sample is in the PR description.
- Follow-ups: none filed; release or version bump left to the owner.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes in spirit, code-class; fixtures written alongside, failures fixed (bucket-end off-by-one found by the real-data run)
- Verification (`superpowers:verification-before-completion`): yes, local bats and CI before merge
- Systematic debugging (`superpowers:systematic-debugging`): no, bugs were direct
- Receiving code review (`superpowers:receiving-code-review`): no findings to receive
