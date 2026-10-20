---
status: In Progress
estimation: 1
source: this conversation, 2026-10-12 (ssh/gh/git wrapper investigation)
related: T20260925-219021
claimed_by: cc1-50ac6891:fb65be2baf012af2
claimed_role: interactive
scheduled: 2026-10-19
---

# T20261012-280694: lint: forbid bare network gh/git in skills + harden _gh wrappers

## Problem

- **Type**: feature
- The wrappers already do the hard part (**verified**, reading `_gh/gh.sh`, `_gh/git.sh`):
  - `_gh/gh.sh` picks the account that can see the repo and sets a process-scoped `GH_TOKEN` per command.
  - `_gh/git.sh` sources it, rewrites `git@github.com:` to HTTPS (`insteadOf`), wires `credential.helper`, then `GH_TOKEN=... exec git`.
  - No global `gh auth switch`, so parallel sessions on different accounts are safe.
- This repo is used with two GitHub accounts (**verified**): xinzweb (company, default key) and 75033us (personal, ssh Host alias `github-75033us`).
- The gap is discipline, not mechanism: skills still call bare `gh`/`git` (**heuristic count, includes docs/examples**):
  - About 104 non-journal md/sh hits of bare `gh|git <subcmd>`; 33 non-journal files reference the wrappers.
  - Top offenders: `drive/SKILL.md` (12), `gotchas.md` (10), `address-pr/SKILL.md` (9), `README.md` (8), `ccxp/scripts/sync-and-prune-branches.sh` (5), `gcpr/SKILL.md` (4); 24 bare `gh pr|api|run|issue` in SKILL.md files.
  - A bare call skips account picking and goes over ssh, so it fails whenever `~/.ssh/config` is unusable.
- Ambient `GITHUB_TOKEN` (**verified set in the investigating shell**) overrides gh's own account choice; the wrappers do not neutralize it, so selection is not deterministic.
- Renaming the wrappers to `xpgh`/`xpgit` would not fix any of this by itself (**inferred**): the per-command token already exists and the failure is bare calls, not the name.
- Context, not a requirement: the earlier ssh breakage (unreadable `Include` on an external drive, macOS privacy grant) is FIXED on this machine, so `ssh -F /dev/null` is not required. Optional fallback only.
- Existing related check: `tests/gh-wrapper-usage.bats` forbids caller-side `GH_TOKEN=`/`GITHUB_TOKEN=` assignments (T20260925-219021). The new lint is the complementary "bare call" check.

### Recommended design (from the findings)

- Keep script names; optionally add thin PATH shims `xpgh`/`xpgit` that exec `bash _gh/gh.sh|git.sh` (alias, not rename).
- Add a lint (in the repo-conventions or skill-conventions lint, next to the skill-quality ratchet) that fails on bare network `gh`/`git` in SKILL.md and scripts:
  - Forbidden: `git push|fetch|pull|clone|ls-remote`, `gh pr|api|run|issue|repo`.
  - Allow-list: local-only git (`status|diff|log|add|commit|branch|checkout|rebase|worktree`), fenced doc examples explicitly marked, tests and fixtures.
- Harden `_gh/git.sh` (and `gh.sh`): ignore the ambient `GITHUB_TOKEN`; cover `clone|fetch|ls-remote` outside a repo by picking the account from the URL owner; optionally fall back safely when `~/.ssh/config` is unusable.
- Migrate the existing bare calls (or allow-list them with a reason) so the lint lands green.

### Done criteria

- Lint fails on a bare network `gh`/`git` fixture and passes on the allow-listed forms; wired into the existing lint entry point and CI.
- Zero un-allow-listed bare network calls remain in non-journal SKILL.md/scripts.
- `_gh/git.sh`/`gh.sh` give the same account result with and without an ambient `GITHUB_TOKEN` (bats).
- `git.sh clone|fetch|ls-remote` works from a non-repo dir for both accounts (bats, fake gh).
- Lint unit tests (python) and bats tests pass.
- Open question: rename to `xpgh`/`xpgit` vs shims only (recommendation: shims, keep paths stable).
