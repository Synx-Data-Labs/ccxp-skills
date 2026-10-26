# agent-pairing: add `update` to refresh the agent definition

- **Why**: `on` never overwrites an existing `agents/ccxp-agent.md`, so a profile installed before the **Detached jobs** section landed stayed stale and had to be refreshed by hand
- **What**: `agent-pairing.sh update [--yes] [--claude-dir DIR]`
  - Dry run by default: prints a unified diff of installed vs bundled `assets/ccxp-agent.md` and the exact `--yes` re-run command
  - `--yes`: copies the old file to `ccxp-agent.md.bak-<YYYYMMDD-HHMMSS>`, then replaces it atomically
  - `on` is unchanged: it still never overwrites a hand-edited file
- **Settings**: the only agent-pairing-owned key is `agent`
  - `update` re-asserts it (jq, `settings.json.bak-*` backup, only if changed) when it is already `ccxp-agent`; on/off state is never changed
  - Hooks, permissions and `env` are not owned: the plugin's `hooks/hooks.json` ships with the plugin, and `job-launch.sh` writes per-job settings under `$TMPDIR` at launch
  - Unmanaged dependencies are reported only: missing helper scripts, no plugin install under the profile, no `claude` on `PATH`, leftover `dispatcher.md`, stale `agent: dispatcher`
- **`status`** now also prints `agent definition: up to date | OUTDATED -- run update | not installed`
- **Docs**: `agent-pairing/SKILL.md` gets the argument, a `### update` workflow section and overwrite notes; the Cross-references no longer say to copy the section by hand
- **Tests**: 18 new cases in `tests/agent_pairing.bats` (temp `--claude-dir` only)
- **Version**: new backward-compatible argument = MINOR; the bump is a separate maintainer PR per `dev/guidelines.md`
