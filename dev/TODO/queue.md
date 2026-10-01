# TODO Queue

Ordered priority queue. Top = highest priority. One line per task, kept in
sync with `dev/TODO/` by `/todo sweep` (adds missing, strikes closed/parked).
Reordered by `/stage` (append to the end if missing) and `/top` (move to the
front). It's a plain list — hand-editing the order is a fully valid way to
reprioritize.

- [T20260924-366770](T20260924-366770-statusline-last-input-slug.md): Add a last-user-input slug to the statusline
- [T20260922-155006](T20260922-155006-gcpr-changed-md-awk-rename-unsafe.md): `gcpr/SKILL.md`'s `CHANGED_TASKS`/`CHANGED_REFS` extraction is rename/delete-unsafe, same bug as the fixed `CHANGED_MD` one
- [T20260922-409644](T20260922-409644-disable-model-invocation-never-used.md): `disable-model-invocation` is never set to `true` anywhere in ccxp-skills
- [T20260922-324422](T20260922-324422-pr-owner-task-link-to-not-yet-merged-path.md): `_tc_pr_owner`/`_tc_resolve_task_location` misreads `unknown` for a same-repo close PR whose body `Task:` link points at a not-yet-merged path
- [T20260922-201976](T20260922-201976-skill-tool-stale-cached-content-vs-live-repo.md): `Skill` tool invocations can serve stale cached skill content that disagrees with the live repo checkout
- [T20260923-292618](T20260923-292618-retire-superpowers-dependency-survey.md): Survey retiring the `superpowers` plugin dependency
- [T20260923-140360](T20260923-140360-retro-external-skill-scan.md): Add an external-skillset scan to /retro
- [T20260923-433144](T20260923-433144-design-score-priority-field-conflicts-with-retired-schema.md): design-score's C1 check scores a `priority:` field that lifecycle.md says is retired
- [T20260923-343482](T20260923-343482-app-auth-merge-workflow-synx-merge-bot.md): Build App-auth merge workflow using synx-merge-bot, so required-review branch protection needs no bypass list
- [T20260924-159109](T20260924-159109-skill-to-app.md): Design /skill-to-app — compile a matured skill's deterministic steps into a program
- [T20260924-390953](T20260924-390953-rca-post-to-slack-plain-text.md): Amend /rca to post results to Slack automatically, plain text (no tables)
- [T20260923-553033](T20260923-553033-repo-wide-2a-N-reference-sweep-after-ipm-extraction.md): Sweep repo-wide stale `2a.N` references left after the `/ipm` extraction
- [T20260924-252293](T20260924-252293-evaluate-ccxp-ipm-ritual-still-needed.md): Decide whether `/ccxp`'s weekly IPM ritual should be simplified or retired
- [T20260925-407025](T20260925-407025-todo-scripts-bash4-only.md): `todo/scripts/todo-list.sh` (and friends) require bash 4+, but macOS's default `/bin/bash` is 3.2
- [T20260925-159860](T20260925-159860-sync-prune-branches-default-skills-dir.md): `sync-and-prune-branches.sh`'s default `--skills-dir` doesn't point at the shared skills repo on every clone
- [T20260925-427007](T20260925-427007-dead-legacy-gh-wrapper-path.md): Four scripts look for `gh.sh` at the dead `~/.claude/skills/_gh/` path
- [T20260925-383305](T20260925-383305-fm-set-orphans-multiline-yaml-continuation.md): `_tc_fm_set` leaves orphaned continuation lines when overwriting a multi-line YAML frontmatter value
- [T20260925-244717](T20260925-244717-reclaim-decide-status-exact-match-bug.md): `_tc_reclaim_decide` exact-matches `status` against `Coding`/`Review`, so any narrated status always reads `live`
- [T20260925-283679](T20260925-283679-remove-legacy-coding-status-alias.md): Remove the legacy `Coding` status alias once external repos migrate
- [T20260928-101526](T20260928-101526-fix-skill-review-2026-09-28-findings.md): Fix the 2026-09-28 skill-review findings (bugs → script paths → concision)
- [T20260928-115329](T20260928-115329-address-pr-free-claim-stomps-design-status.md): `address-pr`'s "free" claim procedure stomps `status: Design` back to `In Progress`
- [T20260929-120385](T20260929-120385-ipm-drain-check-bare-gh-call.md): `_ipm/ipm-iteration-drain-check.sh:224` makes a bare, unwrapped `gh` call
- [T20260929-128287](T20260929-128287-changed-md-unquoted-splitting-not-portable-to-zsh.md): `$CHANGED_MD`-style unquoted word-splitting silently lints zero files under zsh
- [T20261001-319589](T20261001-319589-replace-slack-mcp-with-bot-token-webapi.md): Retire MCP-based Slack access for ccxp automation — move to a bot-token Web API
- [T20261001-350662](T20261001-350662-reality-stamp-monday-no-dedicated-helper.md): `lifecycle.md`'s reality-stamp `scheduled:` Monday has no dedicated helper, inviting `stamp-scheduled.sh` misuse
