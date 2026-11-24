---
status: Done
estimation: 1
source: Owner request in session, 2026-11-24 (job 1500)
related: T20261124-182499
description: HUD AP band shows the autopilot's effective max_dop and how it is used
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261124-239428: HUD shows the autopilot's effective max_dop

## Problem

- **Type**: feature
- Owner: "oh, for the hud, we should display the AP's maxdop there. so that at least we know what's the current config."
- Today the AP band shows elapsed time, loops, merged and 24h stats, but not the configured parallelism (`max_dop` in `dev/.autopilot-config.json`, read by `autopilot-state.sh config-show --json`).
- Done looks like:
  - Compact form in the AP band: running cycles out of max_dop (`AP on 8/16`).
  - Full form in `/hud details`: `max_dop 16 (14 routine + 2 reserved)` once `reserved_slots` exists (T20261124-182499); until then `max_dop` alone.
  - Warning color when running cycles are at the routine limit; one narrow-width shrink step drops it.
  - Silent when the autopilot is off and no config exists.
  - Tests, `hud/README.md` and the HUD help text updated.

## TLDR

- **Type**: feature
- Band: `dop 8/16` (running cycles out of the effective `max_dop`) right after the AP cell; warning colour at the routine limit; dropped whole on a narrow row.
- Details: `max_dop 16 (14 routine + 2 reserved) · 8 running` on the AP line; dim `max_dop N` with the autopilot off but a config file present.
- Data: new helper field `ap_config` from `autopilot-state.sh config-show --json` (effective value, nothing re-derived).

## Solution

- `sl-autopilot-config` (`hud/scripts/hud-lib.sh`) calls `config-show --json` with `AUTOPILOT_CONFIG_FILE` pointed at the repo, only when the autopilot is on/paused or the config file exists; `hud-data.sh` adds it as `ap_config`.
- `reserved_slots` is null when the autopilot script does not report the key (an older plugin copy; T20261124-182499 added it), so `max_dop` then shows alone; no assumed default of 2.
- `config-show` costs about 150 ms, so the answer is cached per repo, keyed on a cksum of the config file and of the autopilot script.
- `hud/model.ts`: `dopUse` (running = `busy_slots`, routine = max_dop less reserved, capped when the routine cycles, `busy_routine`, i.e. not marked urgent as in `routine-free`, reach it and are above 0), band cell `dop`, details cell, `drop:dop` step before `drop:ctx`.
- Alternatives rejected: reading `dev/.autopilot-config.json` directly (would copy the default, range and clamp that another job is changing); a new `fields` entry (the cell rides with `ap`).

## Root cause

- Feature gap, not a defect: the helper (`hud/scripts/hud-data.sh`) never read the autopilot config, so the AP band could not show `max_dop` (introduced with the 24h cell, `hud/model.ts` `apVariants`).

## Repo file references

| File | Change |
|---|---|
| `hud/scripts/hud-lib.sh` | `sl-autopilot-config` |
| `hud/scripts/hud-data.sh` | `ap_config` helper field |
| `hud/model.ts`, `types/index.d.ts` | `ApConfig`, `dopUse`, band and WORK-row cells, `drop:dop` step |
| `hud/README.md`, `hud/HELP.md` | "max_dop cell", `## dop` help topic |

## Test plan

- [x] `hud/pure.test.ts`: parseHelper, band value and colours, max_dop lowered under running (8/6), reserved present or absent, autopilot off or no config, narrow drop order, details forms.
- [x] `tests/hud_data.bats`: config absent, default, override, clamp, off with a file, reserved null then read, failing script.

## Done criteria

- [x] AP band shows `dop running/max_dop`: `hud/model.ts` `dopBandSegs`, test "band: AP on shows `dop running/max_dop`".
- [x] Details shows the full form: `dopDetailSegs`, test "details: AP line carries".
- [x] Warning colour at the routine limit and the 8/6 case: tests "warning colour at the routine limit", "max_dop lowered below the running count".
- [x] Silent with the autopilot off and no config: tests "band: silent without a config answer", `tests/hud_data.bats` "ap_config is null".
- [x] One narrow-width step drops it: test "dop sits right after the AP cell".
- [x] README and help updated: `hud/README.md` "max_dop cell", `hud/HELP.md` `## dop`.

## Closed (2026-11-24)

- Shipped in PR #744 (implementation) after claim PR #737 and staging PR #724; the owner asked for "the AP's maxdop" on the HUD "so that at least we know what's the current config".
- Met: band cell `dop 8/16` after the AP cell (warning colour at the routine limit, also when every slot is taken; urgent cycles left out of the routine count), WORK-row details cell, `ap_config` helper field cached per repo, README and `/hud help` topic `dop`; tests in `hud/pure.test.ts` and `tests/hud_data.bats`.
- Unverified: the TypeScript tests run only inside Claude Code; they were run under a local shim of the test runner (5 unrelated failures there come from missing matchers in the shim, same on main).
- Quality regression (shellcheck_error,shellcheck_warning,shellcheck_info,max_fn_lines,file_loc): not new defects. The probe measures whole touched files; the shellcheck findings (SC2066, SC2010) and the long functions are already in `hud/scripts/hud-lib.sh` and `hud/model.ts` on main, and the change adds about 600 lines of tests and docs to files that were already large.
- Review: five independent review rounds on #744 found a stale cache key (same-second rewrite), urgent cycles counted against the routine limit, a missing every-slot-taken warning, an unvalidated cache line and doc drift; all fixed before merge.
- Follow-up: none filed.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, tests were written together with the code in one pass and run until green.
- Verification (`superpowers:verification-before-completion`): yes, bats, the shimmed TS tests, lint-docs, design-score (87) and doc-impact before the PR, and the pre-merge check in /address-pr.
- Systematic debugging: no, did not get stuck.
- Receiving code review (`superpowers:receiving-code-review`): yes, /address-pr 2.d, five rounds on #744, every finding fixed in the same PR.
