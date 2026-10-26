# agent-pairing: add `update` to refresh the agent definition

- **Why**: `on` never overwrites an existing `agents/ccxp-agent.md`, so a profile installed before the **Detached jobs** section landed stayed stale and had to be refreshed by hand
- **What**: `agent-pairing.sh update [--dry-run|-n] [--claude-dir DIR]`
  - Default (no confirmation step, owner's decision): if installed and bundled `assets/ccxp-agent.md` differ, copy the old file to `ccxp-agent.md.bak-<YYYYMMDD-HHMMSS>` (numeric suffix on a same-second collision), replace it atomically, print a `+N -M lines` diffstat and "takes effect at the next session start"; identical: "up to date", nothing written; missing: reported, `on` installs it
  - `--dry-run` / `-n`: print the unified diff, write nothing
  - `--yes`: accepted as a no-op for backward compatibility, not documented beyond one line
  - `on` is unchanged: it still never overwrites a hand-edited file
- **Settings**: the only agent-pairing-owned key is `agent`
  - `update` re-asserts it (jq, `settings.json.bak-*` backup first, only if changed) when it is already `ccxp-agent`; on/off state is never changed
  - Hooks, permissions and `env` are not owned: the plugin's `hooks/hooks.json` ships with the plugin, and `job-launch.sh` writes per-job settings under `$TMPDIR` at launch
  - Unmanaged dependencies are reported only: missing helper scripts, no plugin install under the profile, no `claude` on `PATH`, leftover `dispatcher.md`, stale `agent: dispatcher`
- **`status`** now also prints `agent definition: up to date | OUTDATED -- run update | not installed`
- **Docs**: `agent-pairing/SKILL.md` gets the argument, a `### update` workflow section (just run it; `--dry-run` to preview) and overwrite notes; the Cross-references no longer say to copy the section by hand
- **Tests**: new cases in `tests/agent_pairing.bats` (temp `--claude-dir` only)
- **Version**: new backward-compatible argument = MINOR; the bump is a separate maintainer PR per `dev/guidelines.md`
