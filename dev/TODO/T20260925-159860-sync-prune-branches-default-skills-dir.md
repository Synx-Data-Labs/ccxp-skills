---
status: Open
estimation: 30m
source: /ccxp interactive run, 2026-09-25 — Phase 0 sync on synxdb-build-pipeline
---

# T20260925-159860: `sync-and-prune-branches.sh`'s default `--skills-dir` (`~/.claude/skills`) doesn't point at the shared skills repo on every clone

## Problem

- `ccxp/scripts/sync-and-prune-branches.sh` defaults `skills_dir="${HOME}/.claude/skills"`. On this interactive macOS clone, `~/.claude/skills` is not a checkout of `ccxp-skills` at all — it's a subdirectory *inside* the unrelated `~/.claude` git repo (toplevel `/Users/xlj/.claude`, branch `master`, no `origin` remote), containing only a `synced/` folder of opaque session-state dirs.
- Running the script with its default silently tried to `git checkout main` inside that wrong repo, which has no `main` branch — `set -euo pipefail` caught the error and aborted cleanly (no damage done), but the failure mode is confusing: `error: pathspec 'main' did not match any file(s) known to git` gives no hint that `--skills-dir` resolved to the wrong repo entirely.
- The actual shared skills checkout on this box lives at `/Users/xlj/workspace/synx-data-labs/ccxp-skills`. Workaround used this session: `--skills-dir /Users/xlj/workspace/synx-data-labs/ccxp-skills` passed explicitly.
- This is presumably fine on the cron box (`dev/daily-ccxp.sh`'s wrapper env), where `~/.claude/skills` may genuinely be set up as the real checkout — but it's a footgun for any interactive session on a differently-provisioned clone, and the failure mode (wrong-repo `git checkout` error) doesn't self-diagnose.

## Done when

- Either: make the default resolution smarter (e.g. check `$CLAUDE_SKILLS_DIR` env var first, or detect via the "Base directory for this skill" mechanism the same way `/ccxp`'s own `<skills-root>` substitution works, per `ccxp/SKILL.md`'s Workflow preamble) — OR at minimum, before running `git -C "$skills_dir" checkout main`, verify `$skills_dir` is actually a git repo with a `ccxp-skills`-shaped remote (`git -C "$skills_dir" remote get-url origin` matching `*/ccxp-skills.git` or `*/ccxp-skills`), and fail loudly with a clear "this doesn't look like the ccxp-skills checkout — pass --skills-dir explicitly" message instead of attempting the checkout and producing a confusing raw git error.
