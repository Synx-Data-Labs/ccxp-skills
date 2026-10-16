---
status: Open
scheduled: 2026-10-26
estimation: 3
source: split from T20261012-280694 (2026-10-16) — that task narrowed to a
  single bug fix (broken-awk account parsing) so it could ship on its own;
  this carries the rest of its original scope forward
related: T20261012-280694, T20260925-219021
---

# T20261016-278922: lint forbid bare network gh/git in skills + remaining `_gh` wrapper hardening

## Problem

- **Type**: feature
- Split out of T20261012-280694's original design (that task shipped only
  the `_gh_list_accounts()` broken-awk fix; see its JOURNAL entry
  `dev/JOURNAL/2026-10-16-T20261012-280694-harden-gh-list-accounts-broken-awk.md`
  for the mechanism that fix addresses — NOT this task's scope).
- The wrappers do the hard part (**verified**, reading `_gh/gh.sh`,
  `_gh/git.sh`): account-picking with a process-scoped `GH_TOKEN`, no global
  `gh auth switch` mutation.
- The gap is discipline, not mechanism: skills still call bare `gh`/`git`
  (**heuristic count from the 2026-10-12 investigation, includes
  docs/examples** — re-count before implementing, since the repo has moved
  on since):
  - About 104 non-journal md/sh hits of bare `gh|git <subcmd>`; 33
    non-journal files reference the wrappers.
  - Top offenders (as of 2026-10-12): `drive/SKILL.md` (12), `gotchas.md`
    (10), `address-pr/SKILL.md` (9), `README.md` (8),
    `ccxp/scripts/sync-and-prune-branches.sh` (5), `gcpr/SKILL.md` (4); 24
    bare `gh pr|api|run|issue` in SKILL.md files.
  - A bare call skips account picking and goes over ssh, so it fails
    whenever `~/.ssh/config` is unusable.
- Ambient `GITHUB_TOKEN` set in the shell (**verified it changes `gh auth
  status`'s own output/exit code** — adds a "Failed to log in...
  (GITHUB_TOKEN)" block and exit 1 — but **does not** break account
  *parsing*, since the real keyring-account lines are still present and
  still extracted correctly post-T20261012-280694's fix) is still worth
  neutralizing defensively: explicit `GH_TOKEN=...` already wins over
  `GITHUB_TOKEN` for every actual `gh`-auth'd call the wrapper makes, but
  `_gh_list_accounts`/`_gh_token_for`'s own `gh auth status`/`gh auth token`
  probes don't set it, so a non-empty ambient `GITHUB_TOKEN` is untested
  territory beyond what T20261012-280694 checked.

## Context

- Renaming the wrappers to `xpgh`/`xpgit` would not fix any of this by
  itself (**inferred**): the per-command token already exists and the
  failure is bare calls, not the name.
- Existing related check: `tests/gh-wrapper-usage.bats` forbids caller-side
  `GH_TOKEN=`/`GITHUB_TOKEN=` assignments (T20260925-219021). The new lint
  here is the complementary "bare call" check.
- `_gh/git.sh` sources `_gh/gh.sh`, so any further `_gh_list_accounts`/
  `_gh_pick_account` hardening lands once, covering both.

## Solution

- Keep script names; optionally add thin PATH shims `xpgh`/`xpgit` that exec
  `bash _gh/gh.sh|git.sh` (alias, not rename) — open question, not required.
- Add a lint (repo-conventions or skill-conventions lint, next to the
  skill-quality ratchet) that fails on bare network `gh`/`git` in SKILL.md
  and scripts:
  - Forbidden: `git push|fetch|pull|clone|ls-remote`, `gh pr|api|run|issue|repo`.
  - Allow-list: local-only git (`status|diff|log|add|commit|branch|checkout|rebase|worktree`),
    fenced doc examples explicitly marked, tests and fixtures.
- Harden `_gh/git.sh` (and `gh.sh`) further:
  - Explicitly neutralize ambient `GITHUB_TOKEN` for the `gh auth status`/
    `gh auth token` probe calls too (e.g. `env -u GITHUB_TOKEN gh auth
    status`), for determinism even though it isn't currently known to break
    parsing.
  - Cover `clone|fetch|ls-remote` outside a repo by picking the account from
    the URL owner (there's no `origin` remote yet to read the slug from).
  - Optionally fall back safely when `~/.ssh/config` is unusable.
- Migrate the existing bare calls (or allow-list them with a documented
  reason) so the lint lands green.
- **Alternatives considered and rejected** (carried from the original
  design): hardcoding `/usr/bin/awk` anywhere in these scripts — rejected,
  not portable; see T20261012-280694's `## Solution` for the fuller
  rejection rationale on the awk-specific piece (now out of this task's
  scope, already shipped).

## Test plan

- [ ] Lint unit tests (python) for the new bare-call check: a fixture with a
      forbidden bare call fails, an allow-listed form passes.
- [ ] `tests/gh.bats` / new bats: `_gh/git.sh`/`gh.sh` give the same account
      result with and without a non-empty ambient `GITHUB_TOKEN`.
- [ ] `git.sh clone|fetch|ls-remote` works from a non-repo dir for both
      accounts (bats, fake gh).
- [ ] Full `bats tests/*.bats` regression sweep green.

## Done criteria

- [ ] Lint fails on a bare network `gh`/`git` fixture and passes on the
      allow-listed forms; wired into the existing lint entry point and CI.
- [ ] Zero un-allow-listed bare network calls remain in non-journal
      SKILL.md/scripts (re-run the heuristic count from this task's Problem
      section and confirm it's zero, or documented exceptions only).
- [ ] `_gh/git.sh`/`gh.sh` give the same account result with and without a
      non-empty ambient `GITHUB_TOKEN` (bats).
- [ ] `git.sh clone|fetch|ls-remote` works from a non-repo dir for both
      accounts (bats, fake gh).
- [ ] Lint unit tests (python) and bats tests pass.
- [ ] Open question resolved: rename to `xpgh`/`xpgit` vs shims only
      (recommendation carried from the original design: shims, keep paths
      stable).
