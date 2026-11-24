---
status: In Progress
estimation: 1
source: owner request, this conversation, 2026-11-24
description: HUD queue max shows three non-overlapping rolling windows (last month / last week / this week) so the trend is visible
type: bug
claimed_by: cc1-50ac6891:026eafc622a13a79
claimed_role: interactive
scheduled: 2026-11-23
---

# T20261124-776095: HUD queue max: non-overlapping rolling windows

## TLDR

- **Type**: bug
- **Problem**: the queue cell's `max` shows nested 180d/30d/7d windows, so on a growing queue all three equal the current peak and no trend shows.
- **Solution**: three adjacent, non-overlapping rolling windows (last month = 14 to 42 days ago, last week = 7 to 14 days ago, this week = the last 7 days) shown as `max a/b/c` plus a trend arrow; computed from the existing `hist-<key>` / `samples-<key>` series.
- **Also (owner, same task)**: retire the `revisited` count from the queue cell and `/hud details` ("I don't care about the revisited stats"); `autoparked` stays (its own signal: tasks the autopilot gave up on).

## Problem

- Owner: "we have a bug in the queue max stats, it should be max last month, last week, this week ... if we increase the queue length, all of them will be the same, and I cannot see the trend."
- Evidence: `sl-hwm-windows` returns nested maxima (`hud/scripts/hud-queue-hwm.sh`, the `d180 >= d30 >= d7` fold in its awk END block) and `hud/model.ts` parseHelper re-enforces the nesting; `hud/README.md` "Queue high watermark" states it. A queue that grew to 90 in the last week prints `max 90 180d / 90 30d / 90 7d`.
- Owner follow-ups: rolling windows instead of calendar buckets ("do the rolling window"); "last month, means last 4 weeks"; drop the `revisited` stat.

## Context

- Existing data is enough: both series hold `epoch<TAB>length` points (history from one `git log -p` pass, live samples); the earlier `max-<key>` file is already ignored. Verified in `hud/scripts/hud-queue-hwm.sh`.
- The issues cell reuses `sl-hwm-windows` (`hud/scripts/hud-issues.sh:127`), so that function stays; it is out of scope.
- `revisited` is computed from the autopilot state file's `visits` map in `sl-queue-json` (`hud/scripts/hud-lib.sh`); the autopilot keeps its own counter (decision d156), so `autopilot/` and the state file are not touched.

## Solution

- Windows (elapsed seconds, so DST and calendar edges do not matter): each window is `[start, end)` over the series: this week `[now-7d, now]`, last week `[now-14d, now-7d)`, last month `[now-42d, now-14d)`; a point exactly on a boundary belongs to the newer window, and the value in force at a window start (the last point at or before it) counts for that window; a window with no data at all is `null` (shown `-`); points dated in the future are ignored.
- New `sl-hwm-rolling` returns `{"lm","lw","tw"}`; `sl-queue-hwm` uses it; helper JSON `queue.hwm` changes shape (old `d180/d30/d7` ignored by the model).
- Model: parse `tw` (required, never below the current length), `lm`/`lw` nullable, no nesting; band `· max 61/74/83 ▲`, details `max 61 last month / 74 last week / 83 this week ▲`; arrow compares this week with last week (nothing when equal or no last week); warning colour while the queue is at the highest of the three. Shrink: max, then no max, then `queue len/total`.
- Remove `revisited` from `sl-queue-json` (code and its header comment), the TS type and model, the band (`12v`), details, tests (`tests/hud_lib.bats` sl-queue-json state test rewritten, fixtures in `hud/pure.test.ts`, `tests/hud_data.bats`, `tests/hud_queue_source.bats`), `hud/README.md` (Queue cell, autopilot-state paragraph, details table) and `hud/HELP.md`.
- Narrow-terminal steps: the labelled band form (`max 61 last month / ...`) is dropped (it is now details-only); the band keeps `· max a/b/c ▲`, then no max, then `queue len/total`. This is the "same steps" minus the old 180d/30d/7d labelled step, which no longer has a meaning.
- Docs: the issues cell text in `hud/README.md` and the header of `hud/scripts/hud-issues.sh` said it shares the queue's windows; reword them (issues keep the nested 180/30/7 figures via `sl-hwm-windows`).
- A repo with under 42 days of history shows last month from the part of the window that has data (`-` when none); documented, accepted.
- Alternatives rejected:
  - Calendar buckets (previous calendar month, Monday weeks): owner chose rolling windows; they also need DST, month and year rollover handling.
  - Keeping a 180-day figure: owner asked for no lifetime or 180-day figure.
  - Storing per-window maxima: not needed, the stored points are exact.
  - Dropping `autoparked` with `revisited`: it is a separate signal, kept.

## Test plan

- [ ] `tests/hud_queue_hwm.bats` (the existing 180d/30d/7d assertions are replaced; the sample-rotation tests stay, the 180-day cap remains for the issues cell): growing, shrinking, flat, no-change window, no history, first days of history, edges at exactly 7, 14 and 42 days (and one second either side), future samples, DST and time zones (UTC vs New_York/Berlin).
- [ ] `hud/pure.test.ts` (new tests `queue max: ...`, replacing the `queue hwm: ...` ones): parse (nullable windows, old shape ignored), band and details text, arrow up/down/none, warning colour, narrow-terminal shrink steps, no `revisited`.
- [ ] `tests/hud_lib.bats`, `tests/hud_data.bats`, `tests/hud_queue_source.bats`: queue JSON without `revisited`, `hwm` shape.

## Done criteria

- [ ] Three adjacent windows, the numbers differ and rise on a growing queue: `tests/hud_queue_hwm.bats` "a growing queue".
- [ ] Window edges exact: `tests/hud_queue_hwm.bats` edge tests (7, 14, 42 days).
- [ ] No history shows this week only, older windows `-`: `tests/hud_queue_hwm.bats` "no history and no samples" (rewritten: older windows null), `hud/pure.test.ts` "queue max: the arrow compares" (`max -/-/44`).
- [ ] Arrow up/down/none and warning colour at the highest of the three: `hud/pure.test.ts` "queue max: the arrow compares", "queue max: at the highest of the three".
- [ ] Band and details text and the `queue.hwm` JSON shape (`lm`/`lw`/`tw`, nullable, `tw` clamped to the current length): `hud/pure.test.ts` "queue max: the band shows", "queue max: parseHelper"; `tests/hud_data.bats` queue key.
- [ ] The issues cell keeps its nested 180/30/7 figures: `tests/hud_issues.bats` unchanged and green; docs reworded in `hud/README.md` and `hud/scripts/hud-issues.sh`.
- [ ] Narrow terminals: the band shrinks `· max a/b/c ▲` then no max then `queue len/total`, never wider than the row: `hud/pure.test.ts` "queue max: a narrow band degrades" (new).
- [ ] `revisited` gone from cell, details, JSON: `tests/hud_lib.bats` sl-queue-json tests, `hud/pure.test.ts` queue tests.
- [ ] README "Queue high watermark" rewritten, HELP updated: `hud/README.md`, `hud/HELP.md`.

## Original request

- **Type**: bug
- Owner: "we have a bug in the queue max stats, it should be max last month, last week, this week, thoughts? otherwise, if we increase the queue length, all of them will be the same, and I cannot see the trend." Then: "file a task and drive it to finish."
- Today (`hud/README.md` "Queue high watermark") the queue cell shows three NESTED windows (180d >= 30d >= 7d >= current), enforced in `hud/model.ts` parseHelper; when the queue grows all three equal the current peak, so no trend shows.
- Design, chosen by the owner (rolling over calendar buckets: "do the rolling window"): three adjacent, never overlapping windows relative to now:
  - this week = the trailing 7 days ending now, including the current length
  - last week = the 7 days before that (7 to 14 days ago)
  - last month = the 4 weeks (28 days) before that (14 to 42 days ago); owner: "last month, means last 4 weeks"
- Display: `max <lastMonth>/<lastWeek>/<thisWeek>` (e.g. `max 61/74/83`) plus a dim trend arrow comparing this week with last week (up, down, nothing when equal); warning colour when the queue is at the highest of the three.
- Remove the nesting enforcement and the 180-day figure from the queue cell (the issues cell keeps its own 180/30/7 windows, out of scope).
- Rules: windows are elapsed seconds (DST-safe); a window with no changes carries the length in force at its start; a window with no data at all (before the first history) shows `-`; no history yet: this week shows the current length, the others `-`; samples dated in the future (clock set back) are ignored.
- Data: no new source; aggregate the existing `hist-<key>` and `samples-<key>` series in `hud/scripts/hud-queue-hwm.sh`, backward compatible.
- Narrow terminals keep today's steps: `· max a/b/c`, then no watermark, then `queue len/total`.
- Done: bats tests pin each window edge (exactly 7, 14 and 42 days), growing (three numbers differ and rise), shrinking, flat, no changes, no history, narrow terminal; `hud/README.md` section rewritten; `hud/HELP.md` updated.
- Added by the owner during the work (same task and PRs): "I don't care about the revisited stats, so we can retire that info from the HUD." The `revisited` count leaves the queue cell, `/hud details`, `sl-queue-json`, the model, tests, README and HELP; `autoparked` stays; `autopilot/` and its state file are untouched.
