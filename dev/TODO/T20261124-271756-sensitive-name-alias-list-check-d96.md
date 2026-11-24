---
status: Open
estimation: 1
source: owner request 2026-11-24 (job 1524), epic E4
related: [T20261121-412600]
description: Customer, partner-name and PII check in /secrets-check or sensitivity-audit driven by an alias list; no real names in the repo
type: feature
---

# T20261124-271756: Customer and partner name check driven by an alias list (d96)

## Problem

- **Type**: feature
- Implements decision d96 (2026-11-12): no customer or partner names, compensation, candidate PII, tax ids, addresses or contract terms in any repo, ledger, context or Slack file (use aliases).
- Today `gcpr-prep.sh sensitivity-check` reads a private deny-list from an env path, and `/secrets-check` covers secrets only; there is no shared alias list and no check on ledger, context or Slack text.
- Wanted: one check (in `/secrets-check` or `synx-skills:sensitivity-audit`, decide in design) that reads the owner's private alias map from a path outside the repo and flags real names, emails and the PII classes above in the diff, PR text, context files and Slack drafts; it prints the file and line, never the matched term.
- No real names in the repo or its tests: fixtures use made-up tokens injected through the env at test time.
- Retire when shipped: nothing; d96 stays as the rule the check enforces (owner decides).

## Done criteria

- Check merged with bats tests using synthetic aliases; `/secrets-check` or the audit runs it; docs say where the private list lives.
