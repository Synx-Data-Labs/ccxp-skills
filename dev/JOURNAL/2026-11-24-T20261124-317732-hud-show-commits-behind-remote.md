---
status: Done
estimation: 1
source: owner request, this conversation, 2026-11-24
description: HUD shows how many commits the local branch is behind (and ahead of) its remote
type: feature
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261124-317732: HUD: show commits behind the remote

## Problem

- **Type**: feature
- Owner, verbatim: "in the hud, i also want to show how many commits behind of the local branch from the remote."
- Show `main ↓134` (and `↑2 ↓134` when ahead) next to the branch for the session repo; the behind count is against the upstream (`@{u}`), falling back to origin/<default branch>.
- Computed from the remote-tracking ref on disk; kept fresh by a detached, rate-limited (about 5 min per repo, 15 s timeout) `git fetch --quiet --no-tags --no-prune origin`, cached like hud-version.sh; a failed fetch keeps the last answer.
- Silent at 0/0, outside a repo, with no upstream and no origin default branch, and on a detached HEAD; neutral color when small, warning past about 20.
- Logic in `hud/scripts/hud-behind.sh` with bats tests (behind, ahead, both, no-upstream fallback, detached, not a repo, cache and rate limit); update `hud/README.md` and `hud/HELP.md`; add to `/hud details` if the one-row band is too narrow.
- Done: behind indicator renders, tests green, docs updated; no version bump or release.

## Closed (2026-11-24)

- Shipped in PR #732 (implementation); claim in PR #731, staged in PR #719. Design approved in-conversation 2026-11-24 (owner brief; no design PR).
- Done criteria met:
  - Behind and ahead counts in the repo cell, `hud/model.ts` `repoVariants`, from `hud/scripts/hud-behind.sh` (`tests/hud_behind.bats`, 19+ cases: behind, ahead, both, no-upstream fallback, dangling origin/HEAD, detached, not a repo, cache, rate limit, lock, failed fetch).
  - Detached rate-limited fetch (5 min, 15 s, remote-tracking refs only, no FETCH_HEAD), `HUD_BEHIND_FETCH=0` opt-out.
  - Docs: `hud/README.md`, `hud/HELP.md`, `/hud config` report.
- Unverified: the TypeScript unit tests in `hud/pure.test.ts` need the plugin runtime and are not run by CI or by this session; the bats suite (CI green) covers the helper and the `/hud config` env names.
- Quality regression (shellcheck_info,max_fn_lines,file_loc): a new 130-line helper script, a new bats file and README growth; the shellcheck info items are SC1091 source-follow notes shared with every hud script.
- Release: none; the owner parked releases (no version bump, tag or publish).

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, tests written alongside the code; bats green before each push.
- Verification (`superpowers:verification-before-completion`): yes, local bats runs and CI before each merge.
- Systematic debugging (`superpowers:systematic-debugging`): no, nothing stuck.
- Receiving code review (`superpowers:receiving-code-review`): yes, /address-pr loop, four review rounds on #732 with fixes and a pushback note.
