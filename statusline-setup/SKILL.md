---
name: statusline-setup
description: Use when the user explicitly asks to redeploy, edit, or test the Claude Code statusline script — the "ctx: N% left | TASK: ..." line in the terminal status bar, driven by settings.json's statusLine.command
disable-model-invocation: false
argument-hint: "[edit|test]"
---

# Statusline Setup

Canonical, version-tracked home for `scripts/statusline-command.sh` — the
script `~/.claude/settings.json`'s `statusLine.command` invokes on every
prompt render. It surfaces the task claimed by *this* clone (matching
`claimed_by: <machine>:<clone-path>` written by `_session/task_claim.sh`) and
the remaining context-window percentage.

The script previously lived loose at `~/.claude/statusline-command.sh`,
untracked by any repo. It now lives here so changes go through a normal
PR/review/merge cycle like any other skill. (Formerly named `set-statusline`
— renamed since day-to-day use is almost always "pull the latest merged
change," not editing.)

## Argument

`$ARGUMENTS` is optional:

- `/statusline-setup` (no argument) — **deploy**: pull a merged change into
  the live skills clone and confirm settings.json points at it. This is the
  default because it's the common case — day-to-day use is "a change to
  statusline-command.sh merged, now make Claude Code actually pick it up."
- `/statusline-setup edit` — edit `scripts/statusline-command.sh` directly in
  the working clone, then run the tests (`test` below) before committing.
- `/statusline-setup test` — run the unit tests for this script.

## Workflow

### Deploy (default, no argument)

1. Pull the merge into the live clone Claude Code actually reads:

   ```bash
   git -C ~/.claude/skills pull
   ```

2. Find every Claude config dir in play, not just the default `~/.claude`.
   Claude Code honors `$CLAUDE_CONFIG_DIR`, and it's common to have a second
   one wired up via a shell alias or function (e.g. `ccp` running with
   `CLAUDE_CONFIG_DIR=~/.claude-personal`). Check both — `alias` only lists
   aliases, not function wrappers (a common pattern since a function can
   forward `"$@"` cleanly where an alias can't):

   ```bash
   alias | grep -i CLAUDE_CONFIG_DIR
   declare -f | grep -i -B2 CLAUDE_CONFIG_DIR   # catches function wrappers too (bash and zsh) — -B2 to include the function's name line, not -A1
   ```

   `skills/` under an alternate config dir is often a **symlink** back to
   `~/.claude/skills` (one script, shared) — but `settings.json` is never
   shared, it's a real per-config-dir file. A `statusLine.command` set up in
   `~/.claude/settings.json` does nothing for sessions launched against
   `~/.claude-personal`; each config dir needs its own entry.

3. For **each** config dir found (default `~/.claude` plus any alternates),
   confirm its `settings.json` has `statusLine.command` pointing at *that
   dir's own* path (one-time setup, already done for `~/.claude` when this
   skill was created — but redo this check whenever a new config dir shows
   up, e.g. a new alias or a new machine):

   ```json
   "command": "bash /Users/YOUR_USERNAME/.claude/skills/statusline-setup/scripts/statusline-command.sh"
   ```

   and for an alternate dir, e.g.:

   ```json
   "command": "bash /Users/YOUR_USERNAME/.claude-personal/skills/statusline-setup/scripts/statusline-command.sh"
   ```

### Edit

1. Edit `scripts/statusline-command.sh` in the working clone at
   `~/workspace/your-org/ccxp-skills` — not the live mirror at
   `~/.claude/skills`, which is read-only and only updated via `git pull`.
2. Test (see below).
3. PR + merge to `main` as normal.
4. Run this skill with no argument (deploy) to pick up the merged change.

### Test

```bash
bats tests/statusline_setup.bats
```

Helper functions (`sl-repo-root`, `sl-clone-id`, `sl-claimed-task-label`,
`sl-join`) are sourced and unit-tested directly; the stdin entrypoint
(`statusline-command`) is tested by piping a synthetic hook-input JSON
payload, same pattern as `quality-probe/scripts/probe.sh`.

## Important Notes

- This script runs on **every** statusline render — keep it fast (cheap
  `grep`/`jq` only, no network) and never let it hang or exit non-zero; a
  broken statusline command degrades the whole terminal UI.
- It is invoked directly by `settings.json`, not as a slash command — the
  `argument-hint`/dual-invocation frontmatter above is for *maintaining* the
  script through this skill, not for how Claude Code *runs* it.
- Naming note: Claude Code also ships a built-in agent type literally named
  `statusline-setup` (for ad hoc, one-off statusline tweaks via Read/Edit).
  This skill and that agent type are different registries (skill vs. agent,
  invoked differently) so there's no functional collision, but don't confuse
  the two when talking about "statusline setup" — this skill is the
  version-tracked, PR-reviewed home for the script; the agent is a generic
  one-off helper with no memory of this repo.
