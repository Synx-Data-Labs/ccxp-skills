---
status: In Progress
estimation: 3
scheduled: 2026-11-16
source: owner message 2026-11-22 (job 1357)
description: /hud help explains every HUD cell; /hud config shows the effective configuration
type: feature
---

# T20261122-212315: `/hud help [topic]` and a read-only `/hud config`

## Problem

- **Type**: feature
- Owner (2026-11-22): "also, what do you mean 'unhandled CI'? and also 'alerts never checked'? I also need a '/hud help' command to help me explain the meaning of each detailed information. '/hud config' should also show the current configuration of the hud."
- The HUD band is dense and the meaning of a cell (colours, markers, data source) lives only in the long `hud/README.md`.
- `/hud config` today opens a dialog straight away; there is no way to see which config files were read, what each setting is, and what is on or off.

## Design

- `/hud` is a mod command (`hud/register.tsx`), not a skill, so help and config are subcommands of it (a `hud` SKILL.md would collide with the command).
- One source for the help text: `hud/HELP.md`, one `## <topic> | <alias>, ...` section per cell. `/hud help` prints the overview and the topic index, `/hud help <topic>` one section. `hud/README.md` points at it instead of repeating it.
- Guard: `tests/hud_help.bats` fails when a field in `hud/config.ts` `ALL_FIELDS`, a `case` of `itemFor` in `hud/model.ts` or a cell name in the guard list has no `##` section in `HELP.md`.
- `/hud config` (bare) prints the effective configuration, read-only: files read (found, missing, invalid), each setting with value, default and where it came from, on/off cells, watched repos, refresh intervals, cache and state dirs, ignored keys. No secrets: only names and paths. The old dialog moves to `/hud config edit` (and `/hud config <url>` keeps working).
- Logic in two pure modules (`hud/help.ts`, `hud/show.ts`), so tests can drive them with fakes.
- Plain definitions: "unhandled CI" = a failed run on the default branch or a schedule, any workflow, whose run id is in no open task, no job context file and no ledger entry; "alerts never checked" = no record that the ccxp-agent persona has checked the Slack alert channel (the `last-check` epoch file written by `agent-pairing/scripts/alerts-due.sh` is missing or garbage).

## Test plan

- [ ] `tests/hud_help.bats`: every cell has a HELP.md section; both definitions are present; the README links HELP.md.
- [ ] `hud/pure.test.ts` cases for `parseHelp`/`helpText` and `configReport` (cannot run outside the Claude Code test runner; reviewed by hand and exercised with node type stripping).
- [ ] `hud/hooks.test.tsx`: `/hud help`, `/hud help alerts`, `/hud config` show without writing or asking.
