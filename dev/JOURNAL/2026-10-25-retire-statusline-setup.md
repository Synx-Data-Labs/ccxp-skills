# Retire the statusline-setup skill in favour of ccxp-hud

- **Why**: owner decision, "we don't need the statusline anymore, since we have the ccxp-hud"; the user's `settings.json` `statusLine` entry is already removed
- **Removed**: the `statusline-setup/` skill (`SKILL.md`, `statusline-command.sh`) and `tests/statusline_setup.bats`
  - The text segments (`ap:`, `ctx`, `branch`, `TASK:`, `jobs`), the heartbeat-driven shrink and the `statusLine.command` deploy workflow are gone
  - Skill count 51 to 50 (README, `dev/quality/skill-scores.json`)
- **Moved, not deleted**: the HUD still needs the bash data layer, now under `hud/scripts/`
  - `hud-data.sh` (the mod's `--json` helper), `last-input-hook.sh` (feeds `lastat`), `ledger.sh` + `ledger.md` (jobs section)
  - `statusline-command.sh` became `hud-lib.sh`, trimmed to the `sl-*` helpers the HUD uses (repo root, clone-id, claimed task, branch, autopilot fields, ledger JSON, last-input epoch); `statusline-command`, `sl-autopilot-part`, `sl-ledger-part`, `sl-join` and `sl-hud-active` dropped
  - `hud/register.tsx` and its test point at `hud/scripts/hud-data.sh`
- **Tests**: `statusline_setup.bats` helper cases carried into new `tests/hud_lib.bats` (autopilot parsing now asserted via `sl-autopilot-fields`); `hud_data`, `ledger` and `last_input_hook` bats repointed, with the statusline-only cases (heartbeat shrink, paused text line, ledger text part) dropped
- **Docs and refs**: README (skill table, install note), `hud/README.md` (new "Last-input hook" section), `claim`, `eta`, `1password-env-setup`, `_session`, `types/index.d.ts` comments, CI path filter (`statusline-setup/**` replaced by `hud/**`)
- **Migration**: anyone who registered the `UserPromptSubmit` hook must repoint it from `statusline-setup/scripts/last-input-hook.sh` to `hud/scripts/last-input-hook.sh`; until then `lastat` stays hidden and the hook errors harmlessly
- **Follow-up**: the HUD still writes a `hud-active/<session_id>` heartbeat that only the retired statusline read; remove it from `hud/register.tsx` and `hud/config.ts` with their tests
- **Version**: removing a skill is a breaking change to its invocation = MAJOR per `dev/guidelines.md`; the bump is a separate maintainer PR
