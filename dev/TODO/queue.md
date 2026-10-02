# TODO Queue

Ordered priority queue. Top = highest priority. One line per task, kept in
sync with `dev/TODO/` by `/todo sweep` (adds missing, strikes closed/parked).
Reordered by `/stage` (append to the end if missing) and `/top` (move to the
front). It's a plain list — hand-editing the order is a fully valid way to
reprioritize.

- [T20260923-343482](T20260923-343482-app-auth-merge-workflow-synx-merge-bot.md): Build App-auth merge workflow using synx-merge-bot, so required-review branch protection needs no bypass list
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
- [T20261001-289904](T20261001-289904-vendor-mattpocock-tdd-replace-superpowers.md): Vendor `mattpocock/skills` `tdd` to replace the `superpowers:test-driven-development` hard gate
- [T20261001-334141](T20261001-334141-vendor-mattpocock-diagnosing-bugs-replace-superpowers.md): Vendor `mattpocock/skills` `diagnosing-bugs` to replace the `superpowers:systematic-debugging` soft gate
- [T20261001-995405](T20261001-995405-scope-native-verification-before-completion-replacement.md): Scope a native replacement for the `superpowers:verification-before-completion` hard gate (no ready mattpocock equivalent)
- [T20261002-363468](T20261002-363468-skill-conventions-script-drift-detection.md): Detect drift between a bundled `scripts/` helper and the SKILL.md prose it replaced
- [T20261002-219904](T20261002-219904-document-ipm-ceremony-as-optional.md): Document `/ccxp`'s Monday IPM ceremony as optional/ad-hoc, not a mandatory cron step
- [T20261002-245216](T20261002-245216-retro-bump-detector-dormant-note-and-stale-field-cleanup.md): Note retro's bump-3x/2x detectors as dormant-by-design; clean up two stale cross-references
- [T20261002-359869](T20261002-359869-lifecycle-md-note-ipm-board-mirror-opt-in.md): Note in `lifecycle.md` that IPM / `scheduled:` board-mirroring is opt-in
