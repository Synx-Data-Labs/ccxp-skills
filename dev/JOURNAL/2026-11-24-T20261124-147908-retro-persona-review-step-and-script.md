---
status: Done
estimation: 2
blocks: [T20261124-420719]
source: owner request 2026-11-24 (decision d155), epic E2
related: [T20261124-420719, T20261124-315192]
description: /retro reviews the decisions log against the persona and proposes persona and skill edits through a tested script
claimed_by:
claimed_role:
scheduled: 2026-11-23
---

# T20261124-147908: /retro persona-review step and `persona-review.sh`

## Problem

- **Type**: feature
- Epic E2 (`dev/EPICS/E2-persona-to-skills.md`), first member. Owner (d155): "let's enhance the /retro to continously improve the ccxp-persona from the decisions".
- Today decisions pile up: job #1456 needed a manual read of 32 active decisions against the persona (48481 of 48500 B cap) to find 3 persona additions, 7 retire/fold candidates and 1 contradiction. `/retro` has no step for it (phases 1b memory, 1d chores, 4c skill quality exist; none reads `ccxp-decisions.json`).
- Add `retro/scripts/persona-review.sh` (deterministic parts only) and a short retro step that uses it; `SKILL.md` stays judgment and orchestration, at most 15 added lines.
- Script subcommands (sourceable, `set -euo pipefail`, tests in `tests/persona_review.bats`):
  - `list`: active decisions via `hud/scripts/ledger.sh decision list --json` (honours `CCXP_DECISIONS_FILE`), with scope and age.
  - `overlap`: per decision, the persona lines (section heading + line number) sharing 2+ meaningful words or its `d<n>` ref; flags "already covered" candidates.
  - `size`: persona bytes and lines, bytes per section, headroom to the 48500 B cap read from `tests/agent_pairing.bats`; says how many bytes an addition must trim.
  - `bucket`: a hint per decision (persona / skill-task / profile-config / keep-in-log / already-covered / retire / contradiction) from scope, wording and overlap; a hint only, the retro agent decides.
  - `commands`: prints the exact `decision retire/supersede` lines for the buckets marked retire or fold, as text to show the owner, never run.
- Retro step: run `list`, `overlap`, `size`, `bucket`; read `decision review` output; write a "Persona review" section in the retro report with the bucket table, proposed persona and skill edits (with the trims that pay for them) and the `commands` output; offer a docs PR proposal.
- Never applies a decision, never edits the persona, never runs `decision add/retire/supersede` (the retro agent has no consent for them); the owner agrees first.
- Worked example and fixture source: the #1456 report (buckets, 3 additions, size tight against the cap).

## Done criteria

- [x] `retro/scripts/persona-review.sh` with list, overlap, size, bucket, commands; `tests/persona_review.bats` (11 tests) green.
- [x] `retro/SKILL.md` Phase 4f added (15 lines) plus a `## Persona review` report section.
- [x] Persona asset untouched (48481 B, headroom 18 B under the 48500 cap).

## Closed (2026-11-24)

- Shipped in the PR that carries this journal move (see `git log -- retro/scripts/persona-review.sh`).
- Script is read-only by test (decisions log and persona checksums unchanged); `commands` only prints lines for the owner.
- Bucket hints are heuristics (words, scope, `decision review` stale/contradiction output); the retro agent confirms each.
- Quality regression (file_loc): new 160-line script plus a 15-line SKILL.md step; the logic was put in the script on purpose to keep SKILL.md short.
- Follow-up: T20261124-420719 (persona move 1) is unblocked.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no, written together with its tests in one pass; tests were run red-to-green once (line numbers fixed).
- Verification (`superpowers:verification-before-completion`): yes, ratchets, doc-impact, lint-identifiers and bats run before the PR.
- Systematic debugging: no, did not get stuck.
- Receiving code review: see PR (independent review via /address-pr).
