---
name: statusline-setup
description: 'Use when the user explicitly asks to redeploy, edit, or test the Claude Code statusline script — the "ctx: N% left | TASK: ..." line in the terminal status bar (an optional "ap:[r]/[b]/[s] <elapsed>/<requested>hr [⚠stuck] loops <cycle> ✓<merged>" segment leads it while /autopilot is running or after it last stopped; an optional companion UserPromptSubmit hook records only the time of the last prompt, for the HUD "lastat" field), driven by settings.json''s statusLine.command'
argument-hint: "[edit|test]"
---

# Statusline Setup

Canonical, version-tracked home for `scripts/statusline-command.sh` — the
script `~/.claude/settings.json`'s `statusLine.command` invokes on every
prompt render. It surfaces the task claimed by *this* clone (matching
`claimed_by: cc1-<machine-id>:<path-hash>` written by `_session/task_claim.sh`),
the remaining context-window percentage, and an `ap:` segment read from
`dev/.autopilot-state.json` whenever this clone has one:

- `ap:[r] <elapsed>/<requested>hr [⚠<stuck>] loops <cycle> ✓<merged>` — `/autopilot` running normally
  (`⚠` only when stuck_count > 0; missing `merged_count` reads as 0)
- `ap:[b] ...` — running but backing off after a stuck `/drive` cycle
- `ap:[s] ...` — stopped; lingers until the next `/autopilot` invocation overwrites the file

The former `last: <text>` segment (T20260924-366770) is **retired**; nothing
stores prompt text any more. Only a timestamp remains: the optional
`scripts/last-input-hook.sh` hook (Deploy step 4) feeds the HUD `lastat` field.

**Migration** for anyone who registered the hook:

- Keep the `hooks.UserPromptSubmit` entry as-is: same script path, `lastat` keeps working.
- The HUD `last` field is gone (an old `"last"` in `ccxp-hud.json` is ignored).
- Cached text under `~/.claude/state/last-input/` is never read; delete it if you like.

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

1. `/plugin update ccxp-skills` pulls the merged change into the plugin
   cache. `statusLine.command` is the one thing the plugin can't wire for
   itself — Claude Code has no per-plugin statusline mechanism, only one
   `statusLine.command` is active per config dir — so after installing or
   updating, confirm it (step 3 below) still points at the right path.

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

   The plugin (and its cache) is installed separately per config dir, and
   `settings.json` is never shared either — a `statusLine.command` set up
   in `~/.claude/settings.json` does nothing for sessions launched against
   `~/.claude-personal`; each config dir needs its own `/plugin update` and
   its own `statusLine.command` entry.

3. For **each** config dir found (default `~/.claude` plus any alternates),
   confirm its `settings.json` has `statusLine.command` pointing at *that
   dir's own* plugin install path:

   ```json
   "command": "bash /Users/YOUR_USERNAME/.claude/plugins/cache/ccxp-skills/ccxp-skills/<version>/statusline-setup/scripts/statusline-command.sh"
   ```

   A `directory`-source install (pointing straight at a dev checkout, e.g.
   via `/plugin marketplace add <local-path>`) has a stable path instead:

   ```json
   "command": "bash /Users/YOUR_USERNAME/workspace/ccxp-skills/statusline-setup/scripts/statusline-command.sh"
   ```

   A marketplace-sourced install's cache path is version-pinned
   (`.../ccxp-skills/<version>/...`) and needs re-pointing after any
   `/plugin update` that bumps the version directory — check
   `~/.claude/plugins/cache/ccxp-skills/ccxp-skills/` if unsure which
   version is current.

4. Optional, for the HUD `lastat` field (`you HH:MM`, hidden until this is
   registered): in **each** config dir from step 2, append an entry for
   `scripts/last-input-hook.sh` to `hooks.UserPromptSubmit`. The hook is
   timestamp-only (never reads or stores prompt text). Append, never replace
   the array; other `UserPromptSubmit` hooks stay:

   ```json
   "UserPromptSubmit": [
     { "hooks": [ { "type": "command", "command": "<existing unrelated hook, if any>" } ] },
     { "hooks": [ { "type": "command", "command": "bash /Users/YOUR_USERNAME/.claude/plugins/cache/ccxp-skills/ccxp-skills/<version>/statusline-setup/scripts/last-input-hook.sh" } ] }
   ]
   ```

   Same marketplace-vs-directory-source path convention as step 3 above —
   use the matching form for this config dir's install.

### ccxp-hud mod companion

The `ccxp-hud` mod (`hud/`, see `hud/README.md`) ships in this plugin, on by
default, and reuses this script's data layer:

- `scripts/hud-data.sh --json` prints one JSON object (task id/title, branch,
  worktree, autopilot fields) from the same `sl-*` functions, so there is one
  source of truth and the claimant secret never leaves bash.
- While the mod draws its band it writes `on` to
  `${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-active/<session_id>` every poll.
  A fresh (under 2 minutes) `on` heartbeat shrinks this statusline to
  `ctx | branch`; no heartbeat, `off`, or a stale one prints the full line, so
  the mod being off (or absent) changes nothing here.

### Job ledger

The HUD `jobs` section reads a ledger written by `scripts/ledger.sh`; the dispatcher
must call it. See `scripts/ledger.md` for the exact calls.

### Edit

1. Edit `scripts/statusline-command.sh` and/or `scripts/last-input-hook.sh`
   in your own working clone (e.g. `~/workspace/ccxp-skills`) — not the
   plugin cache, which is managed by `/plugin` and overwritten on every
   update.
2. Test (see below).
3. PR + merge to `main` as normal.
4. Run this skill with no argument (deploy) to pick up the merged change.

### Test

```bash
bats tests/statusline_setup.bats tests/last_input_hook.bats tests/hud_data.bats tests/ledger.bats
claude plugin test .   # the hud mod's unit tests (needs the claude CLI)
```

Helper functions (`sl-repo-root`, `sl-clone-id`, `sl-claimed-task-label`,
`sl-join`, `sl-last-input-epoch`) are sourced and unit-tested directly; the
stdin entrypoints (`statusline-command`, `last-input-hook`) are each tested
by piping a synthetic hook-input JSON payload, same pattern as
`quality-probe/scripts/probe.sh`.

## Important Notes

- This script runs on **every** statusline render — keep it fast (cheap
  `grep`/`jq` only, no network) and never let it hang or exit non-zero; a
  broken statusline command degrades the whole terminal UI.
- `last-input-hook.sh` runs on **every prompt submission** instead (once,
  not per-render) — same "never hang, never exit non-zero" constraint, since
  a broken hook would block the user from submitting anything.
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
