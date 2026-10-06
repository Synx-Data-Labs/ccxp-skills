---
status: Done
estimation: 1
source: /ccxp interactive run, 2026-09-25 — Phase 0 sync on build-pipeline-repo
related: T20260925-427007
claimed_by:
claimed_role:
scheduled: 2026-10-05
---

Status note: Design PR skipped 2026-10-06 — self-evident bug fix, both candidate
remediations already enumerated in the original filing; design filled in-place
below instead of a separate design PR; claimed via `t20260925-159860-claim`.

# T20260925-159860: `sync-and-prune-branches.sh`'s default `--skills-dir` doesn't point at the shared skills repo on every clone

## TLDR

- **Type**: bug
- **Problem**: the script's default `--skills-dir` (`~/.claude/skills`) silently resolves to the wrong repo on an interactive macOS clone, and fails with a confusing raw `git checkout` error instead of a clear diagnostic.
- **Solution**: default-resolve `skills_dir` relative to the script's own location (`$BASH_SOURCE`) — this script physically lives *inside* the ccxp-skills checkout, so that's always correct — and, belt-and-suspenders, verify the resolved dir has a `ccxp-skills`-shaped `origin` remote before running `git checkout` in it, failing loudly if not.

## Problem

- `ccxp/scripts/sync-and-prune-branches.sh:22` defaults `skills_dir="${HOME}/.claude/skills"`. On this interactive macOS clone, `~/.claude/skills` is not a checkout of `ccxp-skills` at all — it's a subdirectory *inside* the unrelated `~/.claude` git repo (toplevel `/Users/<user>/.claude`, branch `master`, no `origin` remote), containing only a `synced/` folder of opaque session-state dirs.
- Running the script with its default silently tried to `git checkout main` inside that wrong repo, which has no `main` branch — `set -euo pipefail` caught the error and aborted cleanly (no damage done), but the failure mode is confusing: `error: pathspec 'main' did not match any file(s) known to git` gives no hint that `--skills-dir` resolved to the wrong repo entirely.
- The actual shared skills checkout on this box lives at `/Users/<user>/workspace/synx-data-labs/ccxp-skills`. Workaround used this session: `--skills-dir /Users/<user>/workspace/synx-data-labs/ccxp-skills` passed explicitly.
- Impact: any interactive session on a differently-provisioned clone hits this footgun, and the failure doesn't self-diagnose — a user has to already know to pass `--skills-dir` explicitly.

## Context

- **Chore/bug hybrid** (friction location): `ccxp/scripts/sync-and-prune-branches.sh` is invoked by `/ccxp` Phase 0 (per `ccxp/SKILL.md`) to fast-forward both the working repo and the shared `ccxp-skills` checkout before picking up work.
- Verified (research agent, 2026-10-06): no script in this repo currently reads a `CLAUDE_SKILLS_DIR`/`SKILLS_DIR`-style env var — the idea in the original filing was aspirational, not an existing convention.
- Verified: `ccxp/SKILL.md`'s `<skills-root>` substitution (lines ~68-85) is a harness-level convention — the *agent* running `/ccxp` substitutes "Base directory for this skill" at prompt-authoring time. It is not a shell variable a standalone bash script can read, so it cannot be the resolution mechanism here.
- Verified: the sibling bug class in T20260925-427007 (four other scripts defaulting to the dead `~/.claude/skills/_gh/gh.sh` path) is fixed there by resolving the sibling wrapper **relative to the calling script's own location** (`$(dirname "${BASH_SOURCE[0]}")/../_gh/gh.sh`), with an existing DI-seam env var winning first. This task reuses that same established pattern rather than inventing a new env var.
- Key difference from T20260925-427007: `sync-and-prune-branches.sh` is run from the *working/consumer* repo's root (its cwd is a different repo), but the script file itself still lives inside the `ccxp-skills` checkout at `ccxp/scripts/sync-and-prune-branches.sh` — so `$BASH_SOURCE`-relative resolution correctly points at the real shared checkout regardless of cwd or `$HOME` layout.

## Solution

- Change the default so `skills_dir` resolves relative to the script's own path when `--skills-dir` isn't passed: `skills_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"` — the script lives at `<ccxp-skills>/ccxp/scripts/sync-and-prune-branches.sh`, so it takes **two** levels up (`ccxp/scripts/` → `ccxp/` → `<ccxp-skills>/`) to reach the repo root, not one. (Caught by independent PR review on the first draft of this design, which had a single `..` — confirmed by direct `dirname`/path-resolution check that one `..` lands at `<ccxp-skills>/ccxp`, short of the root.)
- Keep the explicit `--skills-dir DIR` CLI flag as the override — unchanged precedence, still wins over the default.
- Before running `git -C "$skills_dir" checkout main` (whichever way `skills_dir` was resolved — default or explicit flag), verify `$skills_dir` is a git repo with a `ccxp-skills`-shaped `origin` remote (`git -C "$skills_dir" remote get-url origin` matching `*/ccxp-skills(.git)?$`); if not, fail loudly with a clear message instead of attempting the checkout and surfacing a confusing raw git error. This covers the explicit-flag case too (a user could still pass a wrong `--skills-dir`), not just the default path.
- **Alternatives rejected**:
  - *A `CLAUDE_SKILLS_DIR` env var as the primary mechanism* — rejected: no such convention exists anywhere else in the repo (confirmed by research agent survey); introducing one here would be a one-off, and self-relative resolution needs no new env var at all for the common case.
  - *The `<skills-root>` harness substitution* — rejected: not readable from a plain bash script; it's resolved by the calling agent/prompt, not at runtime inside `sync-and-prune-branches.sh`.
  - *Only the remote-shape verification, no smarter default* — rejected as insufficient on its own: it would still fail (just with a clearer message) in the common interactive-clone case that triggered this task, rather than actually working. Doing the self-relative default *and* the verification (belt-and-suspenders) satisfies both halves of the original "Done when" and is only a few extra lines.

## Test plan

- [x] BATS: default `skills_dir` resolves to the repo containing the script itself (no `--skills-dir` passed), verified against a throwaway copy of the script tree. (`tests/sync_and_prune_branches.bats`, tests 1-2)
- [x] BATS: explicit `--skills-dir DIR` still overrides the default. (test 3)
- [x] BATS: a `skills_dir` whose `origin` remote doesn't match `*/ccxp-skills(.git)?$` fails loudly with a clear message, before attempting `git checkout`. (tests 4-5)
- [x] BATS: a `skills_dir` with a matching `ccxp-skills` remote proceeds as before (no regression to the existing fetch/checkout/pull/prune behavior). (test 6)
- [ ] Manual/local: run the modified script end-to-end against this very clone with no `--skills-dir` flag. **Not run live** — doing so would `git checkout main`/`git pull --ff-only` in this very working tree mid-task (the script's own Phase 1, on `cwd`), switching away from the feature branch. Test plan item 1 above exercises the identical mechanism hermetically (a throwaway copy of the script inside a real, disposable git repo, invoked with no `--skills-dir`) and is the safe equivalent; honest substitution, not a silent skip.

## Done criteria

- [x] Default `--skills-dir` resolution no longer depends on `~/.claude/skills` existing or being the right repo — satisfied by `ccxp/scripts/sync-and-prune-branches.sh`'s new `$BASH_SOURCE`-relative default (test plan item 1; `bats tests/sync_and_prune_branches.bats` — 6/6 pass).
- [x] A wrong/unrelated `skills_dir` (explicit or default) fails with a clear, actionable message instead of a raw git error — satisfied by the remote-shape guard (test plan item 3).
- [x] No regression to the script's existing behavior when `skills_dir` is already correct — satisfied by test plan item 4, plus the full project suite (`bats tests/*.bats _docs/*.bats _slack/*.bats` — 878/878 pass).

## Root cause

- Introduced at the script's initial authoring, commit `5051a9e` ("Initial public release", 2026-09-28) — `ccxp/scripts/sync-and-prune-branches.sh:22` has always hardcoded `skills_dir="${HOME}/.claude/skills"`.
- Oversight, not a deliberate choice: the comment at line 19 documents the default as "the shared skills repo clone" but never accounts for the fact that `~/.claude/skills` is also a plausible/real path for Claude Code's own unrelated session-state directory (confirmed present on this clone's host, a different, remote-less `master`-branch repo) — the author assumed one specific provisioning layout (the cron box's) was universal.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `ccxp/scripts/sync-and-prune-branches.sh` | 19-38 | the script being fixed — default `skills_dir`, CLI parsing, and the `git -C "$skills_dir"` checkout/pull calls |
| `tests/git.bats` | 1-203 | style reference for a bash-wrapper BATS test in this repo (hermetic fixture pattern, `run bash <script>`) |
| `dev/TODO/T20260925-427007-dead-legacy-gh-wrapper-path.md` | 40-44 | sibling bug class — the `$BASH_SOURCE`-relative resolution pattern this task reuses |

## Closed (2026-10-06)

- Shipped in **PR #254** (claim/design landed separately in PR #253).
- Met: all four `## Done criteria` items — `$BASH_SOURCE`-relative default, explicit-flag override preserved, remote-shape fail-loud guard, no regression (6/6 new BATS + 878/878 full suite).
- External/unverified: the one "manual/local" test-plan item was not run live against this working clone (would have checked out `main` mid-task); substituted with the hermetic BATS equivalent (test 1) — see that item's note.
- No follow-up tasks filed — scope was fully covered by this fix.
- **Incident note (self-caught, fully remediated):** while debugging the test fixtures' bare-repo setup, a throwaway script with a pre-fix bug (and run without first `cd`-ing into the intended working tree) briefly produced a bogus local-only `init` commit in two places: the maintainer's primary `ccxp-skills` clone (`/Users/<user>/workspace/synx-data-labs/ccxp-skills`) and this very task's feature branch in the dedicated autopilot clone. Neither ever reached `origin` (GitHub rejected the one push attempt as non-fast-forward). Both were caught immediately and fully reverted: `git reset --hard` to the pre-incident commit in the primary clone (confirmed `README.md` back to 316 lines, working tree clean, matching `origin/main`), and `git reset --mixed` + restoring `README.md` in this clone (preserving the real in-progress work, which was all still-uncommitted at the time). No data loss, no corrupted remote state.

## Skills invoked

- TDD (`superpowers:test-driven-development`): yes — Phase 3.0 (code-class). RED confirmed (6/6 failing, then narrowed to the real default/guard logic after two fixture bugs of my own were found and fixed — a stale `local a=$1 b=...$a` word-expansion gotcha and a missing bare-repo HEAD symref — neither in the script under test), then GREEN (6/6 passing) after the implementation.
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6, fresh full-suite run (878/878) plus shellcheck (clean) captured in this same session before the PR.
- Systematic debugging (`superpowers:systematic-debugging`): not formally invoked, but applied in spirit — RED-phase failures were hypothesis-driven traced (minimal reproduction scripts, isolating `local` word-expansion semantics and bare-repo `HEAD` default-branch behavior) rather than trial-and-error.
- Receiving code review (`superpowers:receiving-code-review`): yes — on the companion claim/design PR #253, one real finding (an off-by-one in the self-relative path arithmetic) was accepted and fixed, not argued away.
