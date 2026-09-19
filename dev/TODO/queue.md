# TODO Queue

Ordered priority queue. Top = highest priority. One line per task, kept in
sync with `dev/TODO/` by `/todo sweep` (adds missing, strikes closed/parked).
Reordered by `/stage` (append to the end if missing) and `/top` (move to the
front). It's a plain list — hand-editing the order is a fully valid way to
reprioritize.

- [T20260910-872316](T20260910-872316-retro-slack-summary-no-webhook-fallback.md): Retro's Slack summary has no webhook fallback, unlike standup/IPM
- [T20260911-140914](T20260911-140914-gh-account-picker-prefers-read-only.md): `_gh/gh.sh` account-picker can cache a read-only account
- [T20260911-347027](T20260911-347027-ccxp-epic-progress-in-standup.md): `/ccxp` standup should report epic-level progress from the hub repo's `dev/EPICS.md`
- [T20260910-919422](T20260910-919422-lint-docs-fix-corrupts-content.md): `lint-docs.sh --fix` corrupts prose and always lints repo-wide
- [T20260914-384424](T20260914-384424-stale-skills-path-examples.md): Update stale `~/.claude/skills/...` example paths across skill docs
- [T20260914-412750](T20260914-412750-learn-from-mattpocock-skills.md): Learn from `mattpocock/skills` and apply improvements to ccxp-skills
- [T20260914-359646](T20260914-359646-todo-next-as-local-script.md): Convert `/todo next`'s queue-walk logic into a token-free local script
- [T20260914-871616](T20260914-871616-fix-stale-plugin-paths.md): Fix stale `~/.claude/skills/...` paths left by the plugin-install switch
- [T20260914-422854](T20260914-422854-drive-always-journal-immediately.md): `/drive` always journal-moves on close; `/retro` reads both `dev/TODO` and `dev/JOURNAL` for the week's finished tasks
- [T20260808-192220](T20260808-192220-implement-rotate-1password-skill.md): Implement the `/rotate-1password <secret>` skill
- [T20260809-355059](T20260809-355059-rename-status-coding-generic.md): Rename the `Coding` lifecycle status to something domain-generic
- [T20260810-632933](T20260810-632933-stamp-scheduled-stale-ipm-tier1.md): `_ipm/stamp-scheduled.sh` Tier 1 silently uses a stale IPM file
- [T20260915-315552](T20260915-315552-repo-conventions-mode-solo-team-switch.md): Add `/repo-conventions mode {solo|team}` to switch a repo between solo and team branch policy
- [T20260917-151758](T20260917-151758-add-spinup-skill.md): Add `/spinup` skill for repo+skill conventions setup
- [T20260918-414727](T20260918-414727-ccxp-script-paths-assume-wrong-cwd-on-some-boxes.md): `ccxp/SKILL.md`'s relative script paths don't resolve from a `/ccxp` session's actual cwd on at least one box
- [T20260918-214522](T20260918-214522-op-inject-exit-code-not-checked.md): `1password-env-setup.sh` reports "materialized" even when `op inject` fails
- [T20260918-404944](T20260918-404944-pr-owner-unknown-for-stage-prs-new-task-file.md): `task_claim.sh pr-owner` always returns `unknown` for `/stage` PRs that introduce a brand-new task file
- [T20260918-174144](T20260918-174144-skill-logic-to-scripts-convention.md): Document convention: move deterministic skill logic into bundled scripts
- [T20260919-266165](T20260919-266165-address-pr-autopick-stalls-behind-permanently-blocked-oldest-pr.md): `/address-pr`'s bare auto-pick silently stalls forever behind a permanently-blocked oldest PR
- [T20260919-231319](T20260919-231319-lint-internal-identifiers-pre-merge.md): Catch internal identifiers before they reach the public repo
- [T20260922-195629](T20260922-195629-autopilot-waiting-outcome-ambiguity.md): Clarify whether `/autopilot`'s `WAITING` outcome is ever reachable from a bare `/drive` dispatch
- [T20260922-404082](T20260922-404082-tests-workflow-missing-dev-todo-path-filter.md): `tests.yml`'s path filters omit `dev/TODO/**` and `dev/JOURNAL/**`, so `lint-tasks`/`sync-tasks` never run on a pure task-file change
