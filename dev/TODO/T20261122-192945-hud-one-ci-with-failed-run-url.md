---
status: In Progress
estimation: 2
source: owner message 2026-11-22 (job 1356)
description: HUD shows one CI (the configured workflow), red or green, with the failed run URL when red; the multi-workflow red-CI cell is retired
type: feature
---

# T20261122-192945: HUD shows one CI, with the failed run URL when red

## Problem

- **Type**: feature
- Owner (Shine, 2026-11-22), first ask: "well, for the coloring of the ccxp-hud, let's separate the lines, for CI, one color, red or green. For other workflow on main, we can have different color?"
- Owner, then replaced it: "if the config CI, which is our nightly orchastractor is red, then it is red, even it's red at the sync or tests stage. I don't mean we need to show all the break down of the CI. We only need one CI, and if we need to know more, we will drill down manually. So, remove the details of the CI pipeline showing in the hud. However, to make it more accessible, we can add a url to the failed action if the CI is red."
- Decisions: d136 (watch only HUD-registered repos) stays; d143 (one CI only, red when the configured CI run fails, URL to the failed run) supersedes d137 ("red is red for every workflow"); d137 was the rule behind the red-CI cell of T20261120-230152 and T20261121-261197.
- Done: the band has one CI cell for the configured `ci` workflow; red carries the failed run's address; no other-workflow cell.

## Design

- Retire the red-CI cell: drop `redci` from `hud/config.ts`, `hud/register.tsx`, `hud/model.ts`, `types/index.d.ts`, `hud-data.sh` (no `gh` calls from it any more) and its pure tests; `hud-redci.sh list` stays as a manual drill-down tool.
- `hud-ci.sh`: the same single `gh run list` also asks for `url`; a failing state carries `url`, only an exact github.com run address survives.
- `hud/model.ts`: a red CI row ends with the address (scheme dropped, so terminals link it); first part to drop when narrow.
- The TypeScript renderer gap named in the job: the retired cell's `id`/`ev`/`br`/`url` fields were dropped by the parser and never drawn; the cell is gone, the live path (`ci.url`) is parsed and drawn, tests added.
- Docs: `hud/README.md` ("Retired: the red-CI cell", "CI cell"); job r1357 reads it for `/hud help`.

## Test plan

- `bats tests/hud_ci.bats tests/hud_redci.bats` (url for failing only, malformed urls dropped, `hud-data.sh` has no `redci`).
- `hud/pure.test.ts`: url parsing, row text and shrink, no other-workflow text (needs the engine's test runner; not runnable in this sandbox).
