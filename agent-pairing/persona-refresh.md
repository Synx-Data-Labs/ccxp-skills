# Automatic persona refresh (hooks)

After a `/plugin` update the installed persona refreshes by itself: the plugin ships
`hooks/persona-check.sh` (SessionStart `startup` and UserPromptSubmit), so it installs and updates with the
plugin and nothing separate needs installing. A native plugin update fires no hook and never touches the
profile dir, so `agents/ccxp-agent.md` would otherwise lag the bundled `assets/ccxp-agent.md`.
There is no manual update command: `/ccxp-skills:update` and the `/agent-pairing update` subcommand were retired.

- Compares `<profile>/agents/ccxp-agent.md` with the bundled asset of the RUNNING plugin version. No
  network; identical files cost a single `cmp`, so the per-prompt check takes a few ms.
- Differing (and no newer ccxp-skills version cached beside the running one, so it never downgrades): runs the bundled `agent-pairing.sh update` (timestamped `ccxp-agent.md.bak-*` kept, so hand
  edits are recoverable) and shows ONE short message. The last handled bundled-content hash is stored in
  `<profile>/ccxp-persona-check.json` (mode 600), so a given content is refreshed at most once; a later
  hand edit is not overwritten until the bundled persona changes again (the first refresh after install overwrites a hand edit, recoverable from the .bak). If the refresh fails, one notice
  says it is not retried until `ccxp-persona-check.json` is deleted.
- Silent when jq is missing, the persona file is not installed (agent mode never installed), `settings.json`
  `"agent"` is not `"ccxp-agent"`, or the files are identical.
- A mid-session `/plugin` update is picked up by the next prompt (after `/reload-plugins` if the new hook
  set needs it). The refreshed persona usually shows without a restart; if the new behavior does not show,
  restart Claude Code once no background jobs run.
- Off switch for people who hand-edit: `CCXP_PERSONA_AUTO_REFRESH=0` in the environment, or
  `{"autoRefresh": false}` in `ccxp-persona-check.json`.
- Limit: hooks load at session start, so the first release that ships this hook takes effect after that
  update is loaded (`/reload-plugins` or the next session start).

## Engine and plugin auto-update

- The hook's engine is the internal `agent-pairing/scripts/agent-pairing.sh update [--dry-run|-n] [--claude-dir DIR]`:
  - Backs up `agents/ccxp-agent.md` (`.bak-<YYYYMMDD-HHMMSS>`), replaces it atomically, and never turns on/off state.
  - Re-asserts `settings.json` `"agent"` only when it is already `"ccxp-agent"` (key-level `jq`, backup kept).
  - It only reports what it cannot manage (missing helper scripts, no plugin install, `claude` not on `PATH`, stale `dispatcher`).
  - It is not a user-facing command; `--dry-run` shows the diff if you want to preview.
- Plugin updates are Claude Code's own `/plugin` job; there is no ccxp-skills wrapper. For automatic updates turn on
  the marketplace's auto-update in `/plugin` (Marketplaces), or set `extraKnownMarketplaces.ccxp-skills.autoUpdate`
  to `true` in `settings.json`.
- Migration: `/ccxp-skills:update` was removed in the next release. Its opt-in auto-update hook is gone too;
  if you had that auto-update turned on, the native `autoUpdate` key it set stays in effect and the leftover
  `ccxp-skills-auto-update.json` is harmless.
