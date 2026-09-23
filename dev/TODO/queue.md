# TODO Queue

Ordered priority queue. Top = highest priority. One line per task, kept in
sync with `dev/TODO/` by `/todo sweep` (adds missing, strikes closed/parked).
Reordered by `/stage` (append to the end if missing) and `/top` (move to the
front). It's a plain list — hand-editing the order is a fully valid way to
reprioritize.

- [T20260808-192220](T20260808-192220-implement-rotate-1password-skill.md): Implement the `/rotate-1password <secret>` skill
- [T20260809-355059](T20260809-355059-rename-status-coding-generic.md): Rename the `Coding` lifecycle status to something domain-generic
- [T20260922-195629](T20260922-195629-autopilot-waiting-outcome-ambiguity.md): Clarify whether `/autopilot`'s `WAITING` outcome is ever reachable from a bare `/drive` dispatch
- [T20260922-229218](T20260922-229218-release-others-orphans-claimed-role.md): `_tc_release_others` clears `claimed_by` but leaves `claimed_role` orphaned
- [T20260922-453135](T20260922-453135-add-eta-skill.md): Add `/eta` skill — estimate time-to-completion for the current task on hand
- [T20260922-383156](T20260922-383156-lint-docs-plus-corruption-still-live.md): `markdownlint-cli2 --fix` still flips a bare leading `+` to `-` and drops comma-spacing — scoping contains it, doesn't fix it
- [T20260922-253015](T20260922-253015-lint-docs-png-mutation-unconfirmed.md): Confirm or rule out `lint-docs.sh --fix` rewriting a PNG asset
- [T20260922-155006](T20260922-155006-gcpr-changed-md-awk-rename-unsafe.md): `gcpr/SKILL.md`'s `CHANGED_TASKS`/`CHANGED_REFS` extraction is rename/delete-unsafe, same bug as the fixed `CHANGED_MD` one
- [T20260922-409644](T20260922-409644-disable-model-invocation-never-used.md): `disable-model-invocation` is never set to `true` anywhere in ccxp-skills
- [T20260922-413132](T20260922-413132-skill-maturity-tiering-scoping.md): Scope a skill-maturity tiering convention (promoted vs misc/in-progress/deprecated) for the ccxp-skills plugin bundle
- [T20260922-263110](T20260922-263110-todo-next-position-denominator-wrong.md): `todo-next.sh`'s "#N of M" denominator counts raw file lines, not task entries
- [T20260922-324422](T20260922-324422-pr-owner-task-link-to-not-yet-merged-path.md): `_tc_pr_owner`/`_tc_resolve_task_location` misreads `unknown` for a same-repo close PR whose body `Task:` link points at a not-yet-merged path
- [T20260922-201976](T20260922-201976-skill-tool-stale-cached-content-vs-live-repo.md): `Skill` tool invocations can serve stale cached skill content that disagrees with the live repo checkout
