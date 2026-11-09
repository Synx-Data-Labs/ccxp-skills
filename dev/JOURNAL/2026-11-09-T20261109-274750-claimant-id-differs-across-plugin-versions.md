---
status: Done
estimation: 2
source: Job 1105 finding, reported in job 1125 (2026-11-09)
description: The claimant id of one clone differs between plugin 6.2.0 and 6.2.1+, so existing claims can read as foreign
related: T20261109-745828
---

# T20261109-274750: Claimant id changes between plugin 6.2.0 and 6.2.1

## Problem

- 6.2.1 (T20261108-315759) moved the identity state dir from `$HOME/.claude/state` to `<profile>/state`. The one-time adoption (`ccxp_adopt_legacy_state`) copies only when the destination file is missing.
- A profile that already holds its own `machine-id` / `claimant-secret` (older than the legacy copy) never adopts the legacy one, so claims stamped by 6.2.0 (legacy identity) match no clone under 6.2.1.
- Observed: legacy `machine-id` 9f320372, profile `machine-id` 50ac6891; claim `cc1-9f320372:5c00aba90423c4bb` on T20260320-000029 matched no clone.

## Done criteria

- [x] The gate also accepts the legacy-dir identity (or the identity source is stable across versions), with a BATS test.

## Closed (2026-11-09)

- Shipped in #644: `claimant_legacy_id` (read-only) accepted as mine by `_tc_decide`, `release-others` and the reclaim sweep; `acquire` re-stamps.
- Not covered: the HUD (`sl-clone-id`) still matches only the current id, so a not-yet-re-stamped claim shows no task there.
- Release note (suggest 6.3.3): claims stamped under the pre-6.2.1 identity are recognized again.
