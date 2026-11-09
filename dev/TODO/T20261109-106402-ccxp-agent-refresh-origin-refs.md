---
status: Design
estimation: 1
source: owner request, this conversation, 2026-11-09
description: ccxp-agent persona may run one read-only git fetch origin per turn and read repo state from origin/<default>
claimed_by: cc1-9f320372:f9b2137c9918a8ee
claimed_role: interactive
scheduled: 2026-11-09
---

# T20261109-106402: ccxp-agent refreshes origin refs, never the owner's clone

## Problem

- **Type**: feature
- Owner asked whether the ccxp-agent should always refresh the local clone it works on, because a stale local clone gives stale answers (queue, task files).
- The persona (`agent-pairing/assets/ccxp-agent.md`) allows only read-only Bash inline, with a closed carve-out list, so even a `git fetch` is not covered today.
- The owner's clone is often on a non-main branch with uncommitted work, so the dispatcher must never pull, check out, merge or reset it.
- Wanted:
  - At session start and at each wake or turn the dispatcher may run one read-only `git fetch origin` (remote-tracking refs only) in the session repo.
  - Quick lookups of repo state (queue, task files) read `origin/<default>` with `git show` or `git ls-tree`, not the working tree.
  - Jobs already fetch origin before creating worktrees; say so.
  - The Bash carve-out wording for the fetch is added; the persona's size limits and the persona-refresh tests keep passing.
