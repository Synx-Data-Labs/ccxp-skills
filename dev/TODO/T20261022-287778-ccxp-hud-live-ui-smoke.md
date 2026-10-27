---
status: Open
scheduled: 2026-11-02
estimation: 1
source: Follow-up of T20261022-345549 (the ccxp-hud mod could not be exercised in a live Claude Code UI by the implementing session)
related: T20261022-345549, T20261027-237157
description: Live-UI smoke test of the ccxp-hud mod by a human, plus decide the open styling questions it raises
---

# T20261022-287778: ccxp-hud live-UI smoke test (manual)

## Problem

- **Type**: manual verification
- **What is untested**: the mod's rendering in a real terminal. The implementing session had no live UI, so unit tests cover the logic and the no-op paths only.
- **Done looks like**: every item below is ticked by a person, or a defect task is filed for the ones that fail.

## Test plan

- [ ] Update the plugin (or run `claude --plugin-dir <ccxp-skills clone>`), start a session: the prompt rows have a colored left bar and the band shows above the prompt.
- [ ] Selecting and copying a prompt row, hover, and ctrl+o (expanded view) still work on the wrapped row. If not, switch `UserMessage` to the label-only fallback described in the parent task.
- [ ] AP off (no `/autopilot`): one row `repo | branch | T<id> slug | CI | you HH:MM`, no AP and no ctx cell.
- [ ] Under `/autopilot`: one row `AP elapsed/duration loops n ✓merged | ctx % | CI | you HH:MM` (ctx colour thresholds); `/autopilot` pause shows `AP ⏸ paused`; stop returns to the AP-off row.
- [ ] Resize the terminal through wide, compact and tiny: the band stays ONE row, never wraps, and drops last input, CI detail, task slug, branch in that order.
- [ ] CI cell: with `"ci": {"workflow": "<real workflow file>"}` in `ccxp-hud.json` it shows pass/fail/running with a date within a few minutes (first fetch is cached 2 minutes); unset, or a workflow the repo lacks, or `gh` signed out: no cell and no error.
- [ ] `/hud setup`: the dialogs appear in order (workflow, branch, repo, scope, confirm), the confirm shows the `ci` block and file, `write` saves it with other keys intact, cancel and Esc write nothing, an invalid workflow name is refused.
- [ ] `/hud pane` toggles: first run opens the pane, second closes it, third opens it again.
- [ ] The settings statusline shrinks to `ctx | branch` while the band is live and returns to the full line after `/hud off`.
- [ ] `/hud off` and `/hud on` take effect immediately; editing `~/.claude/ccxp-hud.json` takes effect within 15 seconds.
- [ ] A task-notification or peer row is not framed.

## Done criteria

- [ ] All test-plan boxes ticked, or each failure filed as its own task.
