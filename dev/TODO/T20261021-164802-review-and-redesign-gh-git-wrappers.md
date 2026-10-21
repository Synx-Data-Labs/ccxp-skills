---
status: Open
estimation: 1
source: this conversation, 2026-10-21 (maintainer triage items k2 + k4, folded into one task)
related: T20261020-231370, T20261020-242723, T20261012-280694, T20261016-278922
---

# T20261021-164802: Review and redesign the gh/git wrappers (bash review + separate-repo Go redesign for per-repo account switching)

## Problem

- **Type**: research
- Two linked pieces of one effort; kept as one task so the review's findings feed the redesign.
- **Part A - bash review of the current implementation**:
  - Scope: `_gh/gh.sh`, `_gh/git.sh`, and the PATH shims in `~/workspace/.bin` (`gh`, `git`) that route into them.
  - Known weakness (**verified by reading `_gh/gh.sh`, `main()`**): `main()` takes the repo slug only from `$PWD`'s `origin` (`_gh_repo_slug`, then `_gh_pick_account "$slug"`). It never looks at `--repo` / `-R`. So `gh -R other/repo ...` run from a clone of a different repo picks the account for the clone's `origin`, which can be the wrong GitHub account for the target repo. Run outside a git repo it dies with "no github 'origin' remote". `grep -n -- '--repo\| -R' _gh/gh.sh _gh/git.sh` returns nothing.
  - Other known fragilities to fold into the review (all already recorded elsewhere): text-parsing of `gh auth status` (T20261012-280694), `awk` still used for cache lookup/rewrite, shim/fake-git recursion hangs in tests (noted in T20261020-231370's stage 2 section).
- **Part B - Go gh/git wrapper redesign**:
  - Stage 1 (opt-in `CCXP_GH_GO=1` binary `ccxp-gh`, additive, bash stays default) is **merged** via PRs #384-#387 under T20261020-231370.
  - The maintainer **REJECTED the stage-2 design** (replace/shim: install under `~/.local/bin`/`~/workspace/.bin`, `argv[0]` mode, bash forwarders, shim removal). That design stays in T20261020-231370 as the record of what was rejected.
  - Wanted instead: redo it as a **separate repo** whose goal is **automatic switching between multiple GitHub accounts, per repo**.
  - Nothing from stage 2 has been installed on the machine; no shims have been removed or replaced.
- Predecessor: T20261020-231370 is the stage-1 predecessor (left as-is, `In Progress`, not edited by this filing; its stage-2 section is superseded by this task). Close or supersede it when this task is designed.

## Open questions (not a design)

- Part A: does the review stop at documenting findings, or also fix the `--repo`/`-R` account-pick bug in bash before the redesign supersedes it?
- Repo: name, owner org (Synx-Data-Labs or personal), public or private, license?
- Switching trigger: per-repo config file, git `origin` owner/host, `--repo`/`-R`/`GH_REPO`, a directory-to-account map, or the current "probe each account's push permission" approach?
- How does the wrapper relate to the existing `~/workspace/.bin` shims and the ~375 references to `_gh/gh.sh`/`_gh/git.sh` in ccxp-skills (keep forwarders, migrate callers, or leave to the new repo)?
- Distribution: build locally, release artifacts, or something else? (The stage-1 options A-D in T20261020-231370 were never chosen; the rejected stage-2 chose local build.)
- Failure behavior when the binary is missing or no account matches: fall through to real `gh`/`git` or fail loudly?
- Should the wired `git` credential helper and `url.insteadOf` rewriting stay, and how is the token kept out of argv?
- What happens to the stage-1 Go code in `_gh/go/` (move to the new repo, keep, or delete) and to `tests/gh-go.bats`?

## Done criteria

- [ ] Part A findings written up (file:line evidence), including the `--repo`/`-R` account-pick case.
- [ ] Open questions above answered by the maintainer; design doc produced via `/drive` Phase 2.
- [ ] Decision recorded on T20261020-231370 (closed or superseded) with a pointer here.
- [ ] New repo created and implemented per the design (separate follow-up tasks once designed).
