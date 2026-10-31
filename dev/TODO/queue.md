# TODO Queue

Ordered priority queue. Top = highest priority. One line per task, kept in
sync with `dev/TODO/` by `/todo sweep` (adds missing, strikes closed/parked).
Reordered by `/stage` (append to the end if missing) and `/top` (move to the
front). It's a plain list — hand-editing the order is a fully valid way to
reprioritize.

- [T20261022-349299](T20261022-349299-dispatcher-detached-bg-jobs.md): ccxp-agent dispatches detached `claude --bg` jobs
- [T20261022-287778](T20261022-287778-ccxp-hud-live-ui-smoke.md): ccxp-hud live-UI smoke test (manual)
- [T20261021-291375](T20261021-291375-schedule-delivered-autoclose-sweep-synxdb-support.md): Schedule the customer-support delivered-autoclose sweep (cron) for synxdb-support
- [T20261020-231370](T20261020-231370-go-rewrite-gh-git-wrappers-deprioritized.md): Rewrite `_gh/gh.sh` / `_gh/git.sh` as a compiled Go binary (deprioritized)
- [T20261016-278922](T20261016-278922-lint-forbid-bare-gh-git-remaining-wrapper-hardening.md): lint forbid bare network gh/git in skills + remaining `_gh` wrapper hardening
- [T20261010-762961](T20261010-762961-cloudflare-family-router-and-dedupe.md): Cloudflare family: router description, 'not for' lines, drop duplicated references
- [T20260928-101526](T20260928-101526-fix-skill-review-2026-09-28-findings.md): Fix the 2026-09-28 skill-review findings (bugs → script paths → concision)
- [T20260929-128287](T20260929-128287-changed-md-unquoted-splitting-not-portable-to-zsh.md): `$CHANGED_MD`-style unquoted word-splitting silently lints zero files under zsh
- [T20261001-319589](T20261001-319589-replace-slack-mcp-with-bot-token-webapi.md): Retire MCP-based Slack access for ccxp automation — move to a bot-token Web API
- [T20261001-350662](T20261001-350662-reality-stamp-monday-no-dedicated-helper.md): `lifecycle.md`'s reality-stamp `scheduled:` Monday has no dedicated helper, inviting `stamp-scheduled.sh` misuse
- [T20261001-289904](T20261001-289904-vendor-mattpocock-tdd-replace-superpowers.md): Vendor `mattpocock/skills` `tdd` to replace the `superpowers:test-driven-development` hard gate
- [T20261001-334141](T20261001-334141-vendor-mattpocock-diagnosing-bugs-replace-superpowers.md): Vendor `mattpocock/skills` `diagnosing-bugs` to replace the `superpowers:systematic-debugging` soft gate
- [T20261001-995405](T20261001-995405-scope-native-verification-before-completion-replacement.md): Scope a native replacement for the `superpowers:verification-before-completion` hard gate (no ready mattpocock equivalent)
- [T20261002-363468](T20261002-363468-skill-conventions-script-drift-detection.md): Detect drift between a bundled `scripts/` helper and the SKILL.md prose it replaced
- [T20261002-303999](T20261002-303999-honor-claude-config-dir.md): Resolve Claude config paths via $CLAUDE_CONFIG_DIR, not hardcoded ~/.claude
- [T20261006-105476](T20261006-105476-address-pr-review-agent-dispatch-prompt-should-forbid-writes.md): `/address-pr` §2.d review-agent dispatch prompt doesn't forbid write actions, so a `general-purpose` reviewer can push to the PR branch unasked
- [T20261007-104557](T20261007-104557-refresh-skill-for-stale-task-pr-issue.md): /refresh skill — diff-since-last-look + skill-suggestion report for a task/PR/issue
- [T20261008-636871](T20261008-636871-auto-bump-plugin-version.md): Auto-bump plugin.json version on release
- [T20261009-283022](T20261009-283022-rename-incept-to-iterate.md): Rename /incept to /iterate
- [T20261010-274793](T20261010-274793-cross-repo-rule-in-guidelines.md): Add the cross-repo rule to the conventions layer and guidelines
- [T20261010-363414](T20261010-363414-genericize-merge-bot-reference.md): Replace the `synx-merge-bot` reference with a generic merge-bot explanation
- [T20261012-949870](T20261012-949870-support-skill-p2-reporter-dry-run.md): support skill P2: status reporter engine in dry-run (cadence, renderer, marker, tick)
- [T20261012-383399](T20261012-383399-support-skill-p3-live-reporting.md): support skill P3: live reporting (manual-approved one-shot, then scheduled tick on one real task)
- [T20261012-278418](T20261012-278418-support-skill-p4-ci-enforcement-and-tuning.md): support skill P4: CI enforcement of the regression-commit rule and cadence tuning
- [T20261012-342180](T20261012-342180-claimant-id-reverse-lookup-cache.md): Local reverse-lookup cache for claimant ids (who owns what on this box)
- [T20261012-151045](T20261012-151045-follow-ups-pr-308-drop-gh-board-dependency.md): follow-ups from PR #308 (drop gh board dependency)
- [T20260827-238870](T20260827-238870-remove-solo-repo-mode.md): Remove solo-repo (no-CI) mode; always follow the team-repo (peer/CI) process
- [T20260829-362863](T20260829-362863-solo-to-team-mode-conversion-checklist.md): Write the solo-mode → team-mode conversion checklist for any ccxp repo
- [T20261014-144630](T20261014-144630-epic-skill-status-refresh-drive.md): /epic skill (status | refresh | drive)
- [T20261016-393753](T20261016-393753-parallelize-bats-test-suite-with-jobs.md): parallelize bats test suite with --jobs to cut CI wall-clock
- [T20261016-360850](T20261016-360850-fix-chore-review-list-due-test-failure.md): Fix pre-existing failure in chore_review.bats "list-due" test
- [T20261019-174788](T20261019-174788-multi-repo-worktree-dispatcher.md): Make the ccxp skillset multi-repo aware: a dispatcher/agent that works each task/PR in its own git worktree while all repos stay on main
- [T20261020-260751](T20261020-260751-self-isolate-drive-address-pr-autopilot.md): Self-isolate ccxp-skills write-operations (worktree) inside /drive, /address-pr, /autopilot — not just at dispatcher level
- [T20261020-242723](T20261020-242723-harden-gh-wrapper-against-nested-shebang.md): Harden `_gh/gh.sh` and `_gh/git.sh` against nested-shebang invocation (investigation-scoped, not a Go rewrite)
- [T20261020-131330](T20261020-131330-customer-support-skill-automate-full-support-issue-lifecycle.md): customer-support skill: automate the full lifecycle of a support issue (triage -> deliver)
- [T20261021-337802](T20261021-337802-agent-memory-management.md): Agent memory management: durable dispatcher ledger/job registry, lesson capture, shared standing rules, and memory hygiene automation
- [T20261021-164802](T20261021-164802-review-and-redesign-gh-git-wrappers.md): Review and redesign the gh/git wrappers (bash review + separate-repo Go redesign for per-repo account switching)
- [T20261026-542905](T20261026-542905-lint-nudge-frontmatter-field-length.md): lint_tasks.py nudge for over-long frontmatter field values
- [T20260813-406012](T20260813-406012-ccxp-phase0-sync-abandons-unmerged-self-authored-pr.md): `ccxp` Phase 0 sync silently switches away from a self-authored branch with an open, unmerged PR
- [T20261026-665838](T20261026-665838-finish-migrate-task-live-push.md): Finish /migrate-task live push half
- [T20261027-237157](T20261027-237157-ccxp-hud-one-row-modes-ci.md): ccxp-hud one-row band, AP on/off modes, configurable CI cell
- [T20261028-392844](T20261028-392844-triage-task-comment-leaks-internal-details-to-customer-issue.md): triage --task posts internal task ID/hub path/title into a customer-visible issue comment
- [T20261030-716636](T20261030-716636-hud-queue-cell-counts-stale-checkout-as-ready.md): HUD queue cell counts a stale local checkout as ready
- [T20261031-134435](T20261031-134435-hud-details-ap-line-order.md): Reorder the HUD details AP line (AP, next loop, average || queue)
- [T20261031-139856](T20261031-139856-repo-skill-scan-list-switch-multi-repo-awareness.md): /repo skill: scan, list and switch (multi-repo awareness, phases 3-4)
