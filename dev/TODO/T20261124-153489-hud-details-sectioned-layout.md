---
status: Review
estimation: 1
source: owner request, this conversation, 2026-11-24
description: /hud details becomes one labeled row per section (SESSION, BUILD, SUPPORT, WORK, QUEUE, RELEASE)
type: feature
---

# T20261124-153489: HUD details: one labeled row per section

## Problem

- **Type**: feature
- Owner, verbatim: "let me also reorder the HUD a little: context / --- / CI / nightly / --- / issues / --- / AP / WORKING / queue / --- / version ... any better way to display different sections of the information?" Then, on the proposal: "I like option A, please make sure all the info shown today also reflect in the new design."
- Option A: `SESSION` (context, limits), `BUILD` (CI, nightly), `SUPPORT` (issues), `WORK` (AP, WORKING), `QUEUE`, `RELEASE` (version); details stay on the row; a long row wraps onto an indented second line, never truncated silently.
- Details-on view only (there is no compact view); the one-row band is unchanged.
- Requirement: every cell shown today in details-on still appears; the old cells are inventoried in the PR and a test asserts each is present.
- In-flight HUD additions (behind-remote, subscription time-left, AP max_dop, queue max rolling windows, unreleased commits) slot into their section row.
- Done: layout shipped, tests green, `hud/README.md` and `hud/HELP.md` describe the sections; no release.
