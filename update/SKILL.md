---
name: update
description: Use when the user explicitly asks to update the ccxp-skills plugin to the latest public release and refresh the installed ccxp-agent definition, or to check whether an update is available
argument-hint: "[--check | --dry-run] [--claude-dir DIR] | auto on|off|status"
---

# Update

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Updates the installed `ccxp-skills` plugin from the public repo, then refreshes the `ccxp-agent` definition with the NEW version's `agent-pairing` (this skill's own copy belongs to the old version).

## Argument

- (none) — run the update.
- `--check` / `--dry-run` / `-n` — report installed vs latest and what would change; writes nothing.
- `auto on|off|status` — opt-in automatic updates, see **Auto** below.
- `--claude-dir DIR` — non-default profile (default: `$CLAUDE_CONFIG_DIR`, else `~/.claude`).

## Workflow

1. Tell the user what will change under the profile dir: marketplace clone, `plugins/cache/ccxp-skills/` (new version dir), `plugins/installed_plugins.json`, `agents/ccxp-agent.md` (old copy kept as `.bak-<timestamp>`). The agent on/off state is never touched.
2. Warn that a restart (needed afterwards) ends running background jobs/subagents; check `/agent-pairing status` and `ListAgents` first. If any are running, ask before continuing.
3. Run:

```bash
bash <skills-root>/update/scripts/update.sh [--check]
```

The script runs `claude plugin marketplace update ccxp-skills`, `claude plugin update ccxp-skills@ccxp-skills`, then the newest cached version's `agent-pairing/scripts/agent-pairing.sh update`. Latest = newest `ccxp-skills--v*` tag of `Synx-Data-Labs/ccxp-skills` (semver compare).

4. Relay: installed before/after, latest, the release-notes link, what was backed up (agent-pairing's summary).
5. Tell the user the two manual steps: `/reload-plugins` (a slash command, not runnable from a skill), and a restart for the refreshed persona to take effect.

## Auto (`/update auto on|off|status`)

Default OFF; nothing changes for anyone who never runs `on`. Run `bash <skills-root>/update/scripts/auto.sh on|off|status [--dry-run] [--claude-dir DIR]` and relay its output.

- `on` — writes `$CLAUDE_CONFIG_DIR/ccxp-skills-auto-update.json` (default `~/.claude`, mode 600) and sets `extraKnownMarketplaces.ccxp-skills.autoUpdate=true` in `settings.json` (key-level edit, timestamped backup, only when it would change; skipped if the marketplace entry is missing). `off` reverses both. Both are idempotent.
- `status` — read-only: state, native flag, env vars that disable native updates, last check, autopilot busy/idle in this repo.
- The `SessionStart(startup)` hook `hooks/update-check.sh` does the work: at most one check per ~6 h, silent when offline, on any error or when off. On a newer release it runs `update.sh --quiet --no-agent`, refreshes the persona with the NEW version's `agent-pairing.sh update` (backup kept), and shows ONE message per version.
- MAJOR version bumps are held (notice only; run `/update`). While autopilot is busy (`dev/.autopilot-state.json` `busy_since` under 3 h old in the session's repo) nothing is changed.
- Honest limits: a running session cannot hot-load a new version; only the user typing `/reload-plugins` does (neither a hook nor a skill can run it). The message lists the steps in order: `/reload-plugins`; restart once no jobs run (persona changed); then `/autopilot on`. It never restarts anything. The first release shipping the hook must be installed manually once (hooks load at session start).

## Important Notes

- Only run when the user explicitly asks.
- Fail loudly: a non-zero exit means the agent was NOT refreshed; relay the printed state verbatim, never retry silently.
- If `claude` is not on `PATH` inside the skill's Bash, the script says so; give the user the two `claude plugin` commands to run in a terminal, then `/agent-pairing update`.
- Tests: `bats tests/update.bats tests/update_auto.bats` (fakes for `claude`/`git`/`gh`; never touches a real profile).
