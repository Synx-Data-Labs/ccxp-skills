---
status: Review
estimation: 30m
source: this conversation, 2026-09-14
scheduled: 2026-09-14
---

# T20260914-871616: Fix stale `~/.claude/skills/...` paths left by the plugin-install switch

## Problem

- **Type**: bug
- `~/.claude/settings.json`'s `SessionStart` hook still runs
  `bash /home/rocky/.claude/skills/_gh/auto-switch.sh` — a path that only
  exists under the old symlink-install layout (`scripts/install.sh`
  linking each skill into `~/.claude/skills/`). Every session start prints
  `bash: /home/rocky/.claude/skills/_gh/auto-switch.sh: No such file or
  directory`.
- `~/.claude/settings.json`'s `statusLine.command` has the same problem —
  `bash /home/rocky/.claude/skills/statusline-setup/scripts/statusline-command.sh`
  doesn't exist either, so the statusline silently goes blank.
- Root cause: this repo switched to Claude Code **plugin** distribution
  (`.claude-plugin/plugin.json`, `"skills": "."`) per T20260914-234656's
  public-release prep. The plugin loader never creates
  `~/.claude/skills/<name>` symlinks, so both hardcoded paths — wired back
  when this machine used the symlink install — went stale and nothing
  caught it.
- README.md's "As a plugin (recommended)" section says "there is nothing
  to symlink and no `install.sh` to run" but doesn't mention that the
  `_gh/auto-switch.sh` hook and `statusLine.command` still need wiring
  under a plugin install.

## Done criteria

- [ ] `_gh/auto-switch.sh`'s `SessionStart` hook is wired automatically by
      the plugin itself (`hooks/hooks.json` + `${CLAUDE_PLUGIN_ROOT}`), not
      by a hand-edited `settings.json` entry — works for every future
      plugin install with zero manual steps.
- [ ] README/`statusline-setup/SKILL.md` document that `statusLine.command`
      still requires a manual, machine-local `settings.json` entry under a
      plugin install (Claude Code has no per-plugin statusLine mechanism),
      including the caveat that a marketplace-sourced (non-`directory`)
      install's cache path is version-pinned and needs re-pointing after
      `/plugin update` bumps the version directory.
- [ ] This machine's `~/.claude/settings.json` is fixed: dangling
      `SessionStart` hook entry removed (superseded by `hooks/hooks.json`),
      `statusLine.command` repointed at the live path.
- [ ] `bats tests/install_wire_hooks.bats` and `bats tests/auto-switch.bats`
      still pass.

## Closed (2026-09-14)

- Shipped in PR (this branch) `t20260914-871616-fix-stale-plugin-paths`.
- `hooks/hooks.json` added — `SessionStart` now runs
  `${CLAUDE_PLUGIN_ROOT}/_gh/auto-switch.sh` automatically for every
  plugin install (superpowers's own `hooks/hooks.json` was used as the
  reference pattern — no `plugin.json` field needed, auto-discovered by
  convention).
- README.md "As a plugin" section gained a note that the hook is now
  automatic, and a new note that `statusLine.command` is still a manual,
  per-machine `settings.json` step with the version-pin caveat.
  `statusline-setup/SKILL.md`'s Deploy section gained the plugin-install
  variant of step 3 alongside the existing symlink-install steps.
  `plugin.json` bumped `1.0.0` → `1.0.1`.
- This machine's `~/.claude/settings.json`: removed the dangling
  `SessionStart` hook entry (superseded by `hooks/hooks.json` once the
  plugin cache picks up the merged change) and repointed
  `statusLine.command` at `/home/rocky/ccxp-skills/statusline-setup/scripts/statusline-command.sh`
  (this machine's marketplace is a `directory` source pointing straight at
  the live repo, so this path is stable here).

## Skills invoked

- Systematic debugging (`superpowers:systematic-debugging`): yes — traced
  both broken paths to the same root cause (symlink-install assumption
  surviving the plugin-distribution switch) before touching anything.
- TDD (`superpowers:test-driven-development`): no — config/docs change,
  covered by existing `install_wire_hooks.bats`/`auto-switch.bats`, no new
  bash logic needing its own test.
- Verification (`superpowers:verification-before-completion`): yes — ran
  the existing bats suites and validated `hooks/hooks.json` JSON before
  claiming done.
