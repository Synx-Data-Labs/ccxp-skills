# ccxp-hud

A Claude Code **mod** that ships inside the `ccxp-skills` plugin, **on by default**.

- **Prompt rows**: your own prompts get a colored left bar (`quote` border) and yellow text (`USER_TEXT_COLOR` in `config.ts`; the renderer honours `NO_COLOR`); the agent's replies, task notifications and peer messages are left alone.
- **Status band** above the prompt: always exactly ONE row, in one of two modes (autopilot on / off). The HUD replaces the retired `statusline-setup` skill and its `statusLine.command`; the band is the only status line.
- **`/hud`**: `on | off | status | pane | setup`. `pane` is a toggle (run it again to close the pane); `setup` asks for the CI source and writes it (see below).

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
| `fields` | `repo,branch,task,ap,ctx,ci,lastat` | switches cells on or off; the mode decides which can appear (see below). `lastat` shows `you HH:MM` (date added when not today) from the last prompt this session submitted; it needs the timestamp-only UserPromptSubmit hook `hud/scripts/last-input-hook.sh` registered (see "Last-input hook" below), otherwise it stays hidden. Also `rate`, `cost` (opt-in extras, dropped first). The retired `jobs` and `last` are ignored. An old explicit `fields` list without `repo`/`ci` hides those cells until you add them |
| `ci` | unset (no CI cell) | `{ "workflow": "<file or id>", "branch": "<ref>", "repo": "<owner/name>" }`; only `workflow` is required. `branch` defaults to the repo's default branch, `repo` to the current repo. A bare string is a workflow. Invalid values (spaces, shell characters, bad `owner/name`) mean no CI cell. A project file's `"ci": null` switches a user-level `ci` off for that project. `/hud setup` writes it for you |
| `pollSeconds` | `15` | minimum 5 |
| `ctxWarn` / `ctxCrit` | `40` / `15` | context colour thresholds |

Example, in a repo whose nightly orchestrator workflow is `nightly-orchestrator.yml` (`<project>/.claude/ccxp-hud.json`):

```json
{ "ci": { "workflow": "nightly-orchestrator.yml" } }
```

## Modes and layout

The mode is picked automatically: **AP on** while autopilot is running (backing off counts; paused counts and is marked), **AP off** otherwise (stopped or none). The band is ONE row at every width; cells with nothing to say are dropped, never padded.

| Mode | Row |
|---|---|
| AP off | `repo \| branch \| T<id> <task slug> \| CI ✗ failing 10-26 \| you 09:05` (no AP cell, no ctx) |
| AP on | `AP 2/6h loops 3 ✓2 merged \| ctx 64% ▓▓▓▓▓▓░░░░ \| CI ✗ failing 10-26 \| you 09:05` (no repo, branch or task); paused reads `AP ⏸ paused 2/6h ...` |

| Width | Tier | CI | AP | ctx |
|---|---|---|---|---|
| < 70 | tiny | `CI ✗` | `AP 2/6h L3 ✓2` | `ctx 64%` |
| 70-99 | compact | `CI ✗ 10-26` | `AP 2/6h loops 3 ✓2` | `ctx 64%` |
| >= 100 | wide | `CI ✗ failing 10-26` | `AP 2/6h loops 3 ✓2 merged` | `ctx 64% ▓▓▓▓▓▓░░░░` |

- Tiers only set how detailed the AP, ctx and CI cells start. When the row is still wider than the terminal, cells shrink or go in this order: last input (`you`), CI detail (word, then date), task slug (the task ID stays), branch, task ID, then the repo name is cut. AP on: last input, CI detail, ctx meter, AP words, then ctx. Repo (or AP) and CI stay longest.
- The AP elapsed/requested pair keeps its `h` so `2/6h` cannot read as loops.
- `stale` (the helper failed) is a dim tail cell that goes first.

## CI cell

- Source: the LAST run of the configured workflow (`ci` above), via `gh run list --workflow <w> --branch <b> --limit 1` in `hud/scripts/hud-ci.sh`. Nothing is hard coded; no `ci` means no cell and no `gh` call.
- States: `✓ passing` (green), `✗ failing` (red; also timed out), `◐ running` (yellow; queued or in progress), `? unknown` (grey; cancelled, skipped, other). The date is the run's creation day (`MM-DD`).
- Never blocks the band: the helper answers from an on-disk cache (`${CLAUDE_CONFIG_DIR:-~/.claude}/state/hud-ci/`) and starts one detached refresh when the cache is older than 120 s (or `pollSeconds`, whichever is larger), 5 s timeout per call. The first result can take a couple of minutes.
- No such workflow, `gh` missing, signed out or offline: the cell is silently dropped (an older cached answer is kept). Tokens and `gh` output are never shown; the JSON is untrusted and only an enumerated state plus a timestamp survive.

## `/hud setup` and `/hud pane`

- `/hud setup` asks (through the engine's question dialog; type values under "Other"): workflow file or `none`, branch (default = repo default branch), repo (default = current), scope (user file or this project's `.claude/ccxp-hud.json`). It validates every answer, shows the resulting `"ci"` block and the file, and writes only after you pick `write`. Only the `ci` key is merged in; other keys are kept. Cancelling or dismissing any question writes nothing.
- `/hud pane` toggles the detail pane: the engine's own pane list (`$.ui.panes`) says whether it is open, so there is no mod-side flag to go stale.

## Notes

- Needs Claude Code 2.1.287 or newer (mods on by default); the mod API is early access and may change.
- Data comes from `hud/scripts/hud-data.sh --json` (bash; keeps the claimant secret out of the mod). The only network use is the cached, detached CI lookup above (and only when `ci` is set); no model or MCP calls.
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

The job ledger writer is `hud/scripts/ledger.sh` (calls in `hud/scripts/ledger.md`). Tests for the bash layer: `bats tests/hud_lib.bats tests/hud_data.bats tests/hud_ci.bats tests/last_input_hook.bats tests/ledger.bats`.
