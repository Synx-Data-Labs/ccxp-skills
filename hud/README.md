# ccxp-hud

A Claude Code **mod** that ships inside the `ccxp-skills` plugin, **on by default**.

- **Prompt rows**: your own prompts get a colored left bar (`quote` border) and yellow text (`USER_TEXT_COLOR` in `config.ts`; the renderer honours `NO_COLOR`); the agent's replies, task notifications and peer messages are left alone.
- **Status band** above the prompt: which repo you are in (with branch, dirty state and gh account), autopilot state, context left, claimed task, job ledger. The HUD replaces the retired `statusline-setup` skill and its `statusLine.command`; the band is the only status line.
- **`/hud`**: `on`, `off`, `status`, `pane`.

## Turn it off (without uninstalling ccxp-skills)

- `/hud off` (writes `"enabled": false` to the file below), or edit it yourself.
- Takes effect within `pollSeconds` (default 15) with no reload; `/hud off` is immediate.
- Whole mods off: `disableAllHooks`, `--safe-mode`, or an org's `allowManagedModsOnly`.

## Config

User file `~/.claude/ccxp-hud.json` (honours `CLAUDE_CONFIG_DIR`), optional per-project `<project>/.claude/ccxp-hud.json` on top. Missing or malformed means defaults (on).

| Key | Default | Notes |
|---|---|---|
| `enabled` | `true` | master switch; `false` makes every hook a pass-through |
| `userMessage` | `true` | prompt-row styling |
| `band` | `true` | status band |
| `userBorder` | `quote` | `single`, `double`, `round`, `bold`, `singleDouble`, `doubleSingle`, `classic`, `quote`; else no border |
| `userColor` | `suggestion` | a theme key or a hex colour |
| `fields` | `repo,ap,ctx,branch,task,jobs,lastat` | `repo` is the repo segment (see "Repo segment"); when it is listed the `branch` field steps aside because `repo` already shows the branch. `lastat` shows `you HH:MM` (date added when not today) from the last prompt this session submitted. It needs the timestamp-only UserPromptSubmit hook `hud/scripts/last-input-hook.sh` registered (see "Last-input hook" below), otherwise it stays hidden; also `rate`, `cost`. The old `last` (prompt text) field is retired and ignored |
| `pollSeconds` | `15` | minimum 5 |
| `ctxWarn` / `ctxCrit` | `40` / `15` | context colour thresholds |

## Layout by width

The band adapts to the terminal width (`bodyColumns`); sections with nothing to say are dropped, never padded.

| Width | Tier | AP | ctx | Jobs |
|---|---|---|---|---|
| < 70 | tiny, one row | `AP ○ 13/24h ✓2` | `ctx 89%` | `run 5 · park 3` |
| 70-99 | compact, up to two rows | `AP ○ stop 13/24h c6 ✓2` | `ctx 89%` | `run 5 · park 3 · tot 242 (r230 r231 +3)` |
| >= 100 | wide, up to three rows | `AP ○ stopped 13/24h · cycle 6 ✓2 merged` | `ctx 89% ▓▓▓▓▓▓▓▓▓░` | `jobs run 5 · park 3 · tot 242 (r230 Retention keep-set first PR, … +1)` |

- Narrow tiers drop the least important fields first (`lastat`, `cost`, `rate`, `branch`, `task`, then `jobs`) when a row budget is short; tiny also hides branch, task and `lastat`.
- Wide puts running jobs with titles on their own row; titles are cut at word boundaries and extra jobs collapse to `+N`.
- No claimed task, no branch, no ledger: the cell is omitted (no `no claimed task`, no `jobs —`).

## Repo segment

- Shows the repo of the **session's current directory**, re-read on every refresh, so it follows `/cd` and a shell `cd`.
- Wide: `repo: owner/name @ main* (wt name) (account)`. Compact: `name @ main* (account)`. Tiny: `name*`.
- Parts:
  - `owner/name` from `origin` (the folder name when there is no remote; a linked worktree keeps the main repo's name and adds `(wt <folder>)` when wide).
  - `*` (yellow) when tracked files have changes; untracked files are not scanned, so a new untracked file alone does not set it.
  - `@ detached <sha>` on a detached HEAD.
  - `(account)` the gh account for that directory: `GH_CONFIG_DIR` as direnv resolves it (else parsed from the nearest `.envrc`, following `source_up`), read as `user:` from its `hosts.yml`; the default gh config when none is set. Never the token, no network.
- Not in a git repo: only the folder name (`dir: notes` when wide).
- `→` leads the segment for two refreshes (about 30 s) after the working repo changed.
- `(root: X)` (yellow, not shown when tiny) appears when the cwd is outside the session root, which means a shell `cd` moved the cwd but not the project root: CLAUDE.md, settings and skills still belong to the launch repo. After `/cd` both move, so no marker.
- Cost and safety:
  - `git status` runs with a 2 s limit and optional locks off (no index writes); on timeout the `*` is simply absent.
  - The gh account is cached per repo root for 60 s under `~/.claude/state/hud-cache/` (`CCXP_HUD_CACHE_DIR`, `CCXP_HUD_CACHE_TTL`; `0` disables), the one thing the helper writes.

### Following `/cd` (unverified assumptions)

- The mod calls `session.cwd()` on every refresh and runs the helper in that directory. Refresh runs every `pollSeconds` (15 s) and after each turn.
- Also, every 5 s tick compares cwd and root with the last refresh and refreshes at once when they changed, and a `command.run` hook for `cd` refreshes right after `/cd`.
- UNVERIFIED (not yet seen in a real session):
  - that `session.cwd()` moves on `/cd` (the API doc only says `session.root()` does; if `cwd()` stays put, the HUD would need to read `root()` instead);
  - that the `command.run` hook fires for the built-in `/cd`. The 5 s tick and the 15 s poll are the backstop, so the worst case is a delay, not a wrong repo.
- Manual check, in a real session:
  - Run `/cd <path to another repo>`. Within about 15 s the band should switch to that repo with a leading `→` and the right branch and account. If it still shows the old repo after 30 s, report it (and try `/hud status`).
  - A shell `cd` (`! cd <other repo>`) should switch the repo too, plus `(root: <launch repo>)`.

## Jobs and autopilot segments

- Jobs, from the job ledger (`hud/scripts/ledger.sh`, default `~/.claude/ccxp-ledger.json`, override `CCXP_LEDGER_FILE`): `run <R>` (green, shown when above 0), `park <P>` (yellow, shown when above 0), `tot <L>` (lifetime jobs, dim while run or park is shown). Running jobs follow as `r<id>` (titles when wide). No ledger hides the cell.
- AP, from `dev/.autopilot-state.json`: `AP <glyph> <state> <elapsed>/<requested>h [⚠stuck] [cycle N] ✓<merged>`. The `h` marks `13/24` as hours elapsed over requested, `cycle`/`c` is the loop count, `✓` the merged PR count. Running green, paused yellow, stopped grey (red for a failure-type stop reason), `⚠` red only when stuck, `✓` green. A missing `merged_count` counts as 0.

## Notes

- Needs Claude Code 2.1.287 or newer (mods on by default); the mod API is early access and may change.
- Data comes from `hud/scripts/hud-data.sh --json` (bash; keeps the claimant secret out of the mod). No network, model or MCP calls (the helper writes only the 60 s gh-account cache above).
- Any error inside a hook falls back to Claude Code's own drawing.
- Tests: `claude plugin test .` (units and hook behaviour) and the bats files under "Last-input hook" (bash layer).

## Last-input hook (optional, for `lastat`)

Plugins cannot register a `UserPromptSubmit` hook for you here, so add it once per Claude config dir in `settings.json`. Append to `hooks.UserPromptSubmit`, never replace the array. The hook is timestamp-only (it never reads or stores prompt text) and must never fail a prompt:

```json
"UserPromptSubmit": [
  { "hooks": [ { "type": "command", "command": "bash <plugin>/hud/scripts/last-input-hook.sh" } ] }
]
```

`<plugin>` is the plugin install path (`~/.claude/plugins/cache/ccxp-skills/ccxp-skills/<version>` for a marketplace install, which needs re-pointing after a version bump, or your dev checkout for a `directory` source). This path was `statusline-setup/scripts/last-input-hook.sh` before that skill was retired.

The job ledger writer is `hud/scripts/ledger.sh` (calls in `hud/scripts/ledger.md`). Tests for the bash layer: `bats tests/hud_lib.bats tests/hud_data.bats tests/last_input_hook.bats tests/ledger.bats`.
