# Automatic persona refresh (hooks)

After a `/plugin` update the installed persona refreshes by itself: the plugin ships
`hooks/persona-check.sh` (SessionStart `startup` and UserPromptSubmit), so it installs and updates with the
plugin and nothing separate needs installing. A native plugin update fires no hook and never touches the
profile dir, so `agents/ccxp-agent.md` would otherwise lag the bundled `assets/ccxp-agent.md`.
`/ccxp-skills:update` and `/agent-pairing update` are now only manual fallbacks.

- Compares `<profile>/agents/ccxp-agent.md` with the bundled asset of the RUNNING plugin version. No
  network; identical files cost a single `cmp`, so the per-prompt check takes a few ms.
- Differing (and no newer ccxp-skills version cached beside the running one, so it never downgrades): runs the bundled `agent-pairing.sh update` (timestamped `ccxp-agent.md.bak-*` kept, so hand
  edits are recoverable) and shows ONE short message. The last handled bundled-content hash is stored in
  `<profile>/ccxp-persona-check.json` (mode 600), so a given content is refreshed at most once; a later
  hand edit is not overwritten until the bundled persona changes again (the first refresh after install overwrites a hand edit, recoverable from the .bak). If the refresh fails, one notice
  says to run `/agent-pairing update`.
- Silent when jq is missing, the persona file is not installed (agent mode never installed), `settings.json`
  `"agent"` is not `"ccxp-agent"`, or the files are identical.
- A mid-session `/plugin` update is picked up by the next prompt (after `/reload-plugins` if the new hook
  set needs it). The refreshed persona usually shows without a restart; if the new behavior does not show,
  restart Claude Code once no background jobs run.
- Off switch for people who hand-edit: `CCXP_PERSONA_AUTO_REFRESH=0` in the environment, or
  `{"autoRefresh": false}` in `ccxp-persona-check.json`.
- Limit: hooks load at session start, so the first release that ships this hook takes effect after that
  update is loaded (`/reload-plugins` or the next session start).
