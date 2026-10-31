---
status: In Progress
estimation: 1
source: Owner request 2026-10-31
description: Reorder the /hud details AP line to AP, next loop, 24h average, then || and the queue
---

# T20261031-134435: Reorder the HUD details AP line

## Problem

- **Type**: feature
- The `/hud details` autopilot line read `AP … │ 24h cell (average) │ queue … │ next loop …`.
- Owner wants the next loop next to AP, before the average, and the queue after a `||` separator.

## Done when

- Line reads `AP … │ next loop … │ last 24h … average N/day || queue …`.
- `||` shows only when both the AP group and the queue are present.
- Unit tests and `hud/README.md` cover the new order.
