---
status: Open
estimation: 2h
source: this conversation, 2026-09-14 — maintainer asked to speed up `/todo next`
related: T20260911-347027
description: Port /todo next's queue-walk logic into a sourceable bash script so it can run without an LLM turn
---

# T20260914-359646: Convert `/todo next`'s queue-walk logic into a token-free local script

## Problem

- **Type**: feature
- `/todo next` (`todo/SKILL.md`) is a slash-command skill: every invocation spends an LLM turn re-reading `dev/TODO/queue.md`, each candidate task's frontmatter, and `_session/task_claim.sh read`/`reclaimable` output to walk the queue and skip `Done`/`Parked`/peer-claimed entries — even though that walk is fully deterministic and already spelled out step-by-step in the skill doc.
- Maintainer ask (this conversation, 2026-09-14): make this runnable as a plain script so the common case ("what should I work on next") doesn't cost tokens at all.
- Done looks like: a `todo/scripts/todo-next.sh` (or similar) that reads `queue.md` + task frontmatter + claim state directly and prints the same top-3 report `/todo next` currently produces (queue position, status verbatim, deadline/scheduled, claim status, `Unblocks:` list) — runnable standalone (`bash todo/scripts/todo-next.sh`) with no model call.

## Scope

- Cover `/todo next`'s walk rules only (skip `Done`/legacy `Revisit`/`Parked`; peer-mode claim filtering via `task_claim.sh read`/`claimant-id`/`reclaimable`, disable via `CCXP_PEER_MODE=0`) — not `/todo list`'s drift-detection or `/todo sweep`'s mutating logic, which stay in the skill (they already do real editing/judgment work, not just a deterministic read).
- The skill (`todo/SKILL.md`) should still document the underlying logic (for `list`/`sweep` reuse and for a human reading the skill), but `next`'s own workflow section should shell out to the script instead of re-deriving the walk inline.

## Test plan

- [ ] BATS coverage: queue with a mix of Open/Done/Parked/peer-claimed/reclaimable-stale entries → script picks the correct top 3, in queue order
- [ ] `CCXP_PEER_MODE=0` → no claim filtering
- [ ] Empty queue / all-skipped queue → script reports that plainly instead of erroring
- [ ] Manual: `bash todo/scripts/todo-next.sh` from a real ccxp-skills checkout matches `/todo next`'s own output structure

## Done criteria

- [ ] `todo/scripts/todo-next.sh` exists, sourceable, BATS-covered
- [ ] `todo/SKILL.md`'s `next` workflow section invokes the script instead of re-deriving the walk
- [ ] No behavior change to `/todo list` or `/todo sweep`
