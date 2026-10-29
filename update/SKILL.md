---
name: update
description: Use when the user explicitly asks to update the ccxp-skills plugin to the latest public release and refresh the installed ccxp-agent definition, or to check whether an update is available
argument-hint: [--check | --dry-run]
---

# Update

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Updates the installed `ccxp-skills` plugin from the public repo, then refreshes the `ccxp-agent` definition with the NEW version's `agent-pairing` (this skill's own copy belongs to the old version).

## Argument

- (none) — run the update.
- `--check` / `--dry-run` / `-n` — report installed vs latest and what would change; writes nothing.
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

## Important Notes

- Only run when the user explicitly asks.
- Fail loudly: a non-zero exit means the agent was NOT refreshed; relay the printed state verbatim, never retry silently.
- If `claude` is not on `PATH` inside the skill's Bash, the script says so; give the user the two `claude plugin` commands to run in a terminal, then `/agent-pairing update`.
- Tests: `bats tests/update.bats` (fakes for `claude`/`git`/`gh`; never touches a real profile).
