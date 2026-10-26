# ccxp-hud

A Claude Code **mod** that ships inside the `ccxp-skills` plugin, **on by default**.

- **Prompt rows**: your own prompts get a colored left bar (`quote` border) and yellow text (`USER_TEXT_COLOR` in `config.ts`; the renderer honours `NO_COLOR`); the agent's replies, task notifications and peer messages are left alone.
- **Status band** above the prompt: autopilot state, context left, branch, claimed task, job ledger. The existing `statusLine.command` keeps working and shrinks to `ctx | branch` while the band is live.
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
| `fields` | `ap,ctx,branch,task,jobs,lastat` | `lastat` shows `you HH:MM` (date added when not today) from the last prompt this session submitted. It needs the timestamp-only UserPromptSubmit hook `statusline-setup/scripts/last-input-hook.sh` registered (see statusline-setup/SKILL.md), otherwise it stays hidden; also `rate`, `cost`. The old `last` (prompt text) field is retired and ignored |
| `pollSeconds` | `15` | minimum 5 |
| `ctxWarn` / `ctxCrit` | `40` / `15` | context colour thresholds |

## Jobs and autopilot segments

- `jobs run <R> · total <L> · parked <P>` from the job ledger (`statusline-setup/scripts/ledger.sh`, default `~/.claude/ccxp-ledger.json`, override `CCXP_LEDGER_FILE`). Run is green when above 0, parked yellow when above 0; running titles show on wide layouts; no ledger shows a dim `jobs —`.
- `AP <status> <elapsed>/<requested>h [⚠stuck] loops <cycles> ✓<merged>` from `dev/.autopilot-state.json`: running green, paused yellow, stopped grey (red for a failure-type stop reason), `⚠` red only when stuck, `✓` green. A missing `merged_count` counts as 0.

## Notes

- Needs Claude Code 2.1.287 or newer (mods on by default); the mod API is early access and may change.
- Data comes from `statusline-setup/scripts/hud-data.sh --json` (bash; keeps the claimant secret out of the mod). No network, model or MCP calls.
- The classic statusline shrinks to `ctx | branch` while the band is live, so keep the default `fields` (or `/hud off`) if you want autopilot, task or last-input time to stay visible there.
- Any error inside a hook falls back to Claude Code's own drawing.
- Tests: `claude plugin test .` (units and hook behaviour) and `bats tests/hud_data.bats` (data helper).
