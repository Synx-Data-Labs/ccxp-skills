# TODO Queue

Ordered priority queue. Top = highest priority. One line per task, kept in
sync with `dev/TODO/` by `/todo sweep` (adds missing, strikes closed/parked).
Reordered by `/stage` (append to the end if missing) and `/top` (move to the
front). It's a plain list — hand-editing the order is a fully valid way to
reprioritize.

- [T20260910-872316](T20260910-872316-retro-slack-summary-no-webhook-fallback.md): Retro's Slack summary has no webhook fallback, unlike standup/IPM
- [T20260911-140914](T20260911-140914-gh-account-picker-prefers-read-only.md): `_gh/gh.sh` account-picker can cache a read-only account
- [T20260911-347027](T20260911-347027-ccxp-epic-progress-in-standup.md): `/ccxp` standup should report epic-level progress from the hub repo's `dev/EPICS.md`
- [T20260912-279229](T20260912-279229-grill-me-pre-ipm-design-pass.md): `/ccxp` Phase 2a.3 delegates the pre-IPM design pass to a new `/grill-me` skill
- [T20260910-919422](T20260910-919422-lint-docs-fix-corrupts-content.md): `lint-docs.sh --fix` corrupts prose and always lints repo-wide
- [T20260914-234656](T20260914-234656-finish-public-release-prep.md): Finish the pre-public cleanup (branches + commit signatures)
- [T20260914-384424](T20260914-384424-stale-skills-path-examples.md): Update stale `~/.claude/skills/...` example paths across skill docs
- [T20260914-412750](T20260914-412750-learn-from-mattpocock-skills.md): Learn from `mattpocock/skills` and apply improvements to ccxp-skills
- [T20260914-359646](T20260914-359646-todo-next-as-local-script.md): Convert `/todo next`'s queue-walk logic into a token-free local script
- [T20260914-135681](T20260914-135681-drop-todo-sweep-consolidate.md): Simplify `/todo sweep` by dropping the "Consolidate" recommendation
