---
status: In Progress
estimation: 1
source: /ccxp interactive run, 2026-09-25 — Phase 0 sync on build-pipeline-repo
related: T20260925-427007
claimed_by: cc1-50ac6891:ed6da7ef699fc33b
claimed_role: interactive
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

- [ ] BATS: default `skills_dir` resolves to the repo containing the script itself (no `--skills-dir` passed), verified against a throwaway copy of the script tree.
- [ ] BATS: explicit `--skills-dir DIR` still overrides the default.
- [ ] BATS: a `skills_dir` whose `origin` remote doesn't match `*/ccxp-skills(.git)?$` fails loudly with a clear message, before attempting `git checkout`.
- [ ] BATS: a `skills_dir` with a matching `ccxp-skills` remote proceeds as before (no regression to the existing fetch/checkout/pull/prune behavior).
- [ ] Manual/local: run the modified script end-to-end against this very clone with no `--skills-dir` flag — confirms the self-relative default actually resolves to this checkout.

## Done criteria

- [ ] Default `--skills-dir` resolution no longer depends on `~/.claude/skills` existing or being the right repo — satisfied by `ccxp/scripts/sync-and-prune-branches.sh`'s new `$BASH_SOURCE`-relative default (test plan item 1).
- [ ] A wrong/unrelated `skills_dir` (explicit or default) fails with a clear, actionable message instead of a raw git error — satisfied by the remote-shape guard (test plan item 3).
- [ ] No regression to the script's existing behavior when `skills_dir` is already correct — satisfied by test plan item 4.

## Root cause

- Introduced at the script's initial authoring, commit `5051a9e` ("Initial public release", 2026-09-28) — `ccxp/scripts/sync-and-prune-branches.sh:22` has always hardcoded `skills_dir="${HOME}/.claude/skills"`.
- Oversight, not a deliberate choice: the comment at line 19 documents the default as "the shared skills repo clone" but never accounts for the fact that `~/.claude/skills` is also a plausible/real path for Claude Code's own unrelated session-state directory (confirmed present on this clone's host, a different, remote-less `master`-branch repo) — the author assumed one specific provisioning layout (the cron box's) was universal.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `ccxp/scripts/sync-and-prune-branches.sh` | 19-38 | the script being fixed — default `skills_dir`, CLI parsing, and the `git -C "$skills_dir"` checkout/pull calls |
| `tests/git.bats` | 1-203 | style reference for a bash-wrapper BATS test in this repo (hermetic fixture pattern, `run bash <script>`) |
| `dev/TODO/T20260925-427007-dead-legacy-gh-wrapper-path.md` | 40-44 | sibling bug class — the `$BASH_SOURCE`-relative resolution pattern this task reuses |
