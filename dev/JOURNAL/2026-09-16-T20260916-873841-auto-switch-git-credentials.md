---
status: Done
estimation: 1h
source: consumer-repo session (pointer, 75033us/pointer), 2026-09-16 — /stage's own `git push -u origin` failed with "Repository not found" because the loaded SSH key belonged to a different gh-authenticated account than the one `gh auth switch` had already selected
scheduled: 2026-09-14
description: auto-switch.sh also wires local git credential.helper + url.insteadOf, so bare git push/pull/fetch stop depending on the SSH agent
---

# T20260916-873841: `_gh/auto-switch.sh` also wires local git credentials, so bare `git push`/`pull`/`fetch` stop depending on the SSH agent

## Problem

- **Type**: feature
- On a multi-`gh`-account machine, `gh auth switch` (done automatically by
  `_gh/auto-switch.sh`'s `SessionStart` hook) and the SSH agent's active
  identity are two **independent** auth paths. Fixing the former says
  nothing about the latter.
- Observed failure: `gh auth status` showed the correct account
  (`75033us`) active in a consumer repo, yet `git push -u origin
  <branch>` failed with `ERROR: Repository not found` — `ssh -T
  git@github.com` proved the loaded SSH key actually belonged to a
  different account (`xinzweb`) with no access to that repo.
- Every skill that does a bare `git push`/`pull`/`fetch` (`stage`,
  `gcpr`, `top`, `bottom`, `claim`, `retro`, …) was silently exposed to
  this — none of them route through `_gh/gh.sh` (which only fixes calls
  already wrapped through it), and there was no SSH-key-per-account setup
  on the affected machine.
- Done looks like: a bare `git push` in any repo whose `origin` is
  GitHub authenticates via whichever account `gh auth switch` just
  selected, with zero changes needed to any skill's `git push`/`pull`/
  `fetch` call sites.

## Design

- Extended `_auto_switch_run()` (`_gh/auto-switch.sh`) to call a new
  `_auto_switch_wire_git_credentials()` once an account is confirmed
  (already-active, or reached by switching) — both success branches, not
  just the switch branch, since the SSH-key gap exists regardless of
  whether a switch was needed this session.
- `_auto_switch_wire_git_credentials()` sets, **repo-local only**
  (`git config --local`, i.e. this repo's `.git/config` — never
  `~/.gitconfig`, never the SSH agent/`~/.ssh/config`):
  - `credential.helper` — reset (empty-string entry, per
    `gitcredentials(1)`) then `!gh auth git-credential`, which
    authenticates as whichever account is currently active.
  - `url."https://github.com/".insteadOf` for both `git@github.com:` and
    `ssh://git@github.com/` — forces GitHub-origin traffic onto HTTPS at
    the transport level, since a credential helper is never consulted for
    SSH transport.
  - `--unset-all` before `--add` on both keys, so re-running every
    session start (the normal case) never accumulates duplicate entries.
- Considered wrapping the picker logic into `_gh/gh.sh` instead (a `git`
  subcommand + credential-helper mode) — rejected because `gh.sh` only
  covers calls already routed through it; fixing the actual failure would
  have required rewriting ~6 skills' `git push`/`pull`/`fetch` call sites.
  Extending the existing `SessionStart` hook fixes every bare call
  automatically, matching its own stated purpose ("the only lever
  available to fix a *bare*, unwrapped call").
- Verified end-to-end against a real repo (`75033us/pointer`): rewired
  local git config + `gh auth switch --user 75033us`, then `git ls-remote`
  (via `GIT_TRACE=1`) confirmed HTTPS transport + `gh auth
  git-credential`, and a real `git push` succeeded with no SSH key
  involved.
- **Known limitation, hit live while dogfooding this on `ccxp-skills`
  itself**: `_auto_switch_run()`'s own account check
  (`gh api "repos/$org_repo" --silent`) is read-liveness only, same as
  `_gh_pick_account()` in `_gh/gh.sh` — see T20260911-140914. On this
  machine, `75033us` passed that check (org-member read access to
  `Synx-Data-Labs/ccxp-skills`) but `git push` still 403'd; `xinzweb` (the
  actual write-access account) had to be selected manually. This task's
  git-credential wiring inherits whichever account `_auto_switch_run`
  picks — it does not fix the underlying picker; that's T20260911-140914's
  scope, filed separately.

### Test Plan

- [x] `tests/auto-switch.bats` — 4 new cases: already-correct-account
      still wires credentials, switched-account wires credentials,
      no-account-found leaves git config untouched, repeated runs stay
      idempotent (no duplicate `credential.helper`/`url.insteadOf`
      entries)
- [x] Full `bats tests/*.bats _docs/*.bats` suite — 641 passing, no
      regressions
- [x] Manual end-to-end verification against a real GitHub repo (see
      Design)

## Done criteria

- [x] `_auto_switch_wire_git_credentials()` added, called from both
      success branches of `_auto_switch_run()`
- [x] README.md "Shared helpers" section updated alongside the script
      (doc-impact check)
- [x] No changes needed to any consumer skill's `git push`/`pull`/`fetch`
      call sites

## Closed

- Shipped alongside the fix in `75033us/pointer`'s own `/stage` PR
  (#122), which is what surfaced this gap.
