---
status: Open
estimation: 1
source: Owner standing rule on customer/partner confidentiality, 2026-11-07
description: Intake skills must alias names; /gcpr gets a local-denylist sensitivity check
---

# T20261107-132909: Sensitive-names guard in intake skills and /gcpr

## Problem

- A customer prospect's and a partner's names leaked into a hub repo via a task file filed from pasted email text.
- Owner rule: no customer or partner names, compensation, candidate PII, tax ids, addresses or contract terms in any repo, task, PR, commit or log.
- `/new-task`, `/to-task` and `/incept` never tell the agent to scrub pasted raw text before writing it down.
- `/gcpr` has a secrets check but no sensitivity check for names.

## Solution

- Intake skills (`/new-task`, `/to-task`, `/incept`):
  - add a step: never paste raw email or chat text verbatim
  - replace customer, prospect and partner names, emails and domains with aliases (customer A, partner B) before writing the task file, `source:`, commit message or PR
- `/gcpr`:
  - new `gcpr-prep.sh sensitivity-check [--base B]` verb, called next to the secrets-check step
  - deny-list from `SENSITIVE_NAMES_DENYLIST_FILE` (private file) or `SENSITIVE_NAMES_DENYLIST` (same content inline); newline-separated, whole-word, case-insensitive
  - scans added diff lines (working tree, index and `B...HEAD`) and commit messages
  - hit output is `file:line` (or `commit <sha8> message`) plus a count, never the term
  - unset or unreadable list: warn and exit 0 (fail-soft)
- Reuse: `repo-conventions/scripts/lint_identifiers.py` already has the committed-never env/file deny-list design; it matches substrings and prints terms, so the new verb has its own whole-word matcher and does not call it.

## Test plan

- BATS in `tests/gcpr_prep.bats`: unset warns and exits 0, file and inline list hit on added lines, whole-word and case-insensitive, commit message hit, output never contains the term, removed lines and pre-existing lines are ignored.
- BATS for the three intake skills carrying the alias step.

## Done criteria

- Both changes merged, tests green, no release or tag cut.
