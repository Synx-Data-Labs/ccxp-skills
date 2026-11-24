---
status: Open
estimation: 2
blocks: [T20261124-870400]
blocked-by: T20261124-420719
source: owner request 2026-11-24 (decision d155), epic E2
related: [T20261124-147908, T20261124-420719]
description: Move the persona's Detached jobs, Decisions log and Terms procedures into agent-pairing docs and scripts, leaving pointers
---

# T20261124-315192: Persona move 2: detached jobs, decisions log, terms become pointers

## Problem

- **Type**: chore
- Epic E2. Persona sections: Detached jobs 2303 B, Terms 2552 B, Decisions log 1583 B (6438 B, 32 lines); docs `bg-jobs.md`, `terms.md`, `decisions.md` and scripts `job-launch.sh`, `job-status.sh`, `terms.sh` exist.
- Keep in the persona only what identifies behaviour (record only on the owner's typed words, show each new ref, retire only with approval); the how-to (flags, schema, lock rules, review block) goes to the docs and scripts. Each section becomes 2 to 4 lines. Target: persona at most 41500 B (with T20261124-420719).
- Room for the pending additions d147 (re-dispatch after the fix), d129 (fetch and rebase before work), d96 (no customer data) is made here or in a follow-up: decide with the owner using `persona-review.sh size`.
- Bats: cap test plus key-rule presence test; check the refresh flow in `persona-refresh.md` (the pointers must name a doc that ships in the plugin).
- After this task, file the next clusters (CI failure response and Repo freshness, HUD job ledger, Consent, Writing a job prompt) per the epic.

## Done criteria

- Persona at most 41500 B, behaviour identical, tests green, epic E2 updated with the measured result and the next clusters.
