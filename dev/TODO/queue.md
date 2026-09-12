# TODO Queue

Ordered priority queue. Top = highest priority. One line per task, kept in
sync with `dev/TODO/` by `/todo sweep` (adds missing, strikes closed/parked).
Reordered by `/stage` (append to the end if missing) and `/top` (move to the
front). It's a plain list — hand-editing the order is a fully valid way to
reprioritize.

- [T20260910-872316](T20260910-872316-retro-slack-summary-no-webhook-fallback.md): Retro's Slack summary has no webhook fallback, unlike standup/IPM
- [T20260911-140914](T20260911-140914-gh-account-picker-prefers-read-only.md): `_gh/gh.sh` account-picker can cache a read-only account
- [T20260911-698434](T20260911-698434-claimant-id-unstable-hostname.md): `_tc_claimant_id()` uses bare `hostname`, which can drift
- [T20260912-279229](T20260912-279229-grill-me-pre-ipm-design-pass.md): `/ccxp` Phase 2a.3 delegates the pre-IPM design pass to a new `/grill-me` skill
