# TODO Queue

Ordered priority queue. Top = highest priority. One line per task, kept in
sync with `dev/TODO/` by `/todo sweep` (adds missing, strikes closed/parked).
Reordered by `/stage` (append to the end if missing) and `/top` (move to the
front). It's a plain list — hand-editing the order is a fully valid way to
reprioritize.

- [T20261010-129025](T20261010-129025-mode-sh-fast-path-trusts-doc-text-over-live-state.md): `mode.sh`'s no-op fast path trusts doc text over live GitHub state
- [T20260923-343482](T20260923-343482-gh-app-token-script.md): Add `_gh/gh-app-token.sh` — mint GitHub App installation tokens
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
- [T20261002-303999](T20261002-303999-honor-claude-config-dir.md): Resolve Claude config paths via $CLAUDE_CONFIG_DIR, not hardcoded ~/.claude
- [T20261005-554581](T20261005-554581-drain-gate-reads-retired-project-board.md): `ipm-iteration-drain-check.sh` hard-requires a Project board, so a board-less consumer's IPM gate is permanently red
- [T20261005-639913](T20261005-639913-remove-roadmap-target-repo-per-repo-roadmap.md): Remove `ROADMAP_TARGET_REPO` — each repo owns its own `dev/ROADMAP.md` / `dev/EPICS.md`
- [T20261006-105476](T20261006-105476-address-pr-review-agent-dispatch-prompt-should-forbid-writes.md): `/address-pr` §2.d review-agent dispatch prompt doesn't forbid write actions, so a `general-purpose` reviewer can push to the PR branch unasked
- [T20261006-227360](T20261006-227360-autopilot-explicit-task-and-pr-targeting.md): /autopilot must dispatch /drive at an explicit task, and /drive's own PR must always be addressed by explicit PR number
- [T20261007-104557](T20261007-104557-refresh-skill-for-stale-task-pr-issue.md): /refresh skill — diff-since-last-look + skill-suggestion report for a task/PR/issue
- [T20261008-636871](T20261008-636871-auto-bump-plugin-version.md): Auto-bump plugin.json version on release
- [T20261009-154870](T20261009-154870-merge-spinup-into-repo-conventions.md): Merge /spinup into /repo-conventions, resolve the mode/setup naming collision
- [T20261009-283022](T20261009-283022-rename-incept-to-iterate.md): Rename /incept to /iterate
