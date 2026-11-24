### E4 — Decisions to code

Goal: turn standing decisions that are enforced only by prose or memory into scripts, config, skills and checks, so the rule holds without anyone remembering it and the persona stays small
Done when: every member below is closed (in `dev/JOURNAL/`) and each member's "retire when shipped" note was handed to the owner

Owner's words (2026-11-24): "review how many decisions we have, and what can be converted into agent persona, or skills, or scripts, etc." and, after the proposal, "go". Decisions d155 (shrink the persona into skills, skills into scripts) and d101 (merge gates) apply.

Scope notes:

- Decisions are never retired by a member task; the owner or dispatcher retires them later.
- d140 (task per job) is already mechanical: persona rule, `ledger.sh start --task` / `--no-task`, `check` failure and `finish` warning shipped in T20261121-412600. The remaining shrink of its persona text is part of the persona trim member.
- Cross-repo members live in synxdb-build-pipeline (not epic members here): d98 and d150 (Cloudsmith cleanup guards) and d114 (lint for `-g` in release builds).
- Order: freshness gate first; the persona trim last (after the CI-failure and merge-gate moves).
- Not in scope: adding d94 or d95 to the authorization list, any release, tag or version bump.

- [T20261124-392722](../JOURNAL/2026-11-24-T20261124-392722-pre-dispatch-fresh-base-gate-d129.md) — d129: pre-dispatch fresh-base gate script
- [T20261124-395783](../TODO/T20261124-395783-ci-failure-response-skill-d148.md) — d148: CI-failure response into a skill and script
- [T20261124-290097](../TODO/T20261124-290097-shared-merge-gate-prompt-snippet-d101.md) — d101: shared job-prompt snippet for the merge gates
- [T20261124-271756](../TODO/T20261124-271756-sensitive-name-alias-list-check-d96.md) — d96: customer and partner name check driven by an alias list
- [T20261124-181781](../TODO/T20261124-181781-slack-internal-channel-whitelist-d100.md) — d100: Slack internal-channel whitelist as config
- [T20261124-141354](../TODO/T20261124-141354-rulebook-rerender-trigger-d113.md) — d113: rulebook re-render trigger on decision changes
- [T20261124-209545](../TODO/T20261124-209545-persona-trim-after-decision-moves.md) — d155: persona trim after the decision moves
