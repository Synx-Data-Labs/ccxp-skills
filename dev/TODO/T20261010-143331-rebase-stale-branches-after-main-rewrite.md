---
status: Open
estimation: 1
source: this conversation, 2026-10-10
---

# T20261010-143331: Rebase stale branches onto rewritten main and close them

## Problem

- **Type**: chore
- main was force-pushed rewritten (79e9e8b -> 83fbf56, all hashes changed; local backup branch `backup/pre-343482-cleanup`); branches below still carry old history, including removed Drata content.
- Stale branches:
  - remote `t20261010-736699-journal-close` (plus a local branch of the same name)
  - remote `t20261010-736699-agent-pairing-dispatcher-skill`
  - remote `claude/optimistic-dijkstra-lbd22e`
  - remote `docs/close-t20260923-425414-superseded`
- Work: rebase each onto new main (or recreate), drop Drata content, force-push with lease.
- Then close them asap: land (merge) each, or delete if superseded by the rewritten main.
- Done: no branch carries pre-rewrite history; each is merged or deleted.
