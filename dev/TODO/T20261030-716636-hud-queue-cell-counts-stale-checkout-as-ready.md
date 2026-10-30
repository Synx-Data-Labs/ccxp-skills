---
status: Open
estimation: 1
source: Owner chat 2026-10-30
description: HUD queue cell counts a stale local checkout and uncategorised needs_attention entries as ready while autopilot is idle
---

# T20261030-716636: HUD queue cell counts a stale local checkout as ready

## Problem

- **Type**: bug
- `hud/scripts/hud-lib.sh` `sl-queue-json` reads `<repo>/dev/TODO/queue.md` and the task frontmatter from the CURRENT working checkout.
  - When that clone is behind origin/main, tasks already finished or parked upstream still count as "ready".
  - Autopilot works from its own fresh dispatch clone, so it correctly finds none and reports idle.
- Observed 2026-10-30 in the pointer repo (local clone 57 commits behind origin/main):
  - HUD showed ready=2: T20261029-386636 was already in `dev/JOURNAL` on origin, T20260910-266683 was already in `dev/PARKING` on origin.
  - Autopilot was idle with 0 eligible.
- Second cause, same symptom: autopilot `needs_attention` entries recorded without `--kind` fall through to "ready" unless the id is also in `skip_ids`.
  - 50 of 55 entries were uncategorised; ready read 44 while autopilot had nothing to take.

## Proposed fix (options, pick in design)

- (a) While autopilot status is on|paused, read the queue and frontmatter from the autopilot dispatch clone (`dispatch_clone_path`, which it keeps current), or from `git show origin/main:` after a cheap fetch.
- (b) Otherwise, show a "behind N" marker next to the queue cell when the checkout is behind its upstream.
- (c) needs_attention fallback: when status is on|paused, treat every id in `needs_attention` / `skip_ids` as not ready, regardless of `skip_ids`; kind none maps to "decision".

## Done when

- The HUD ready count equals what autopilot can actually take (0 in the observed case).
- The existing hud bats suite (`tests/hud_*.bats`) covers:
  - a checkout that is behind origin;
  - an uncategorised `needs_attention` entry.
