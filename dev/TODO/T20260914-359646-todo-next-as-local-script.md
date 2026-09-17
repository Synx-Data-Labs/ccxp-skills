---
status: Open
estimation: 4h
source: this conversation, 2026-09-14 — maintainer asked to speed up `/todo next`; scope broadened 2026-09-16 — maintainer asked why `/todo list`'s table costs an LLM turn too, when it's just as deterministic a read of already-persisted `queue.md`/frontmatter
related: T20260911-347027
description: Port /todo list's table + /todo next's queue-walk logic into sourceable bash scripts so neither needs an LLM turn
---

# T20260914-359646: Convert `/todo list`'s table and `/todo next`'s queue-walk into token-free local scripts

## Problem

- **Type**: feature
- `/todo next` (`todo/SKILL.md`) is a slash-command skill: every invocation spends an LLM turn re-reading `dev/TODO/queue.md`, each candidate task's frontmatter, and `_session/task_claim.sh read`/`reclaimable` output to walk the queue and skip `Done`/`Parked`/peer-claimed entries — even though that walk is fully deterministic and already spelled out step-by-step in the skill doc.
- **Same problem, same root cause, in `/todo list`** (broadened 2026-09-16): it re-reads `queue.md` + every task's frontmatter to render a plain table (`#`/ID/Title/Status/Est/Deadline/Scheduled/Claimed) plus counts and a parking-lot count — all of it a mechanical transform of data already sitting in `queue.md`/task frontmatter, no judgment involved. `list`'s drift-detection (untracked files, stale queue entries, stale `Blocked by T{id}` references) is likewise a plain set/existence check, not a decision — it belongs in the same script, unlike `sweep`'s Phase 2/3 (blocker-order enforcement, park/close/consolidate calls), which really does make judgment calls and stays LLM-driven.
- Maintainer ask (2026-09-14, `next`; reaffirmed 2026-09-16 for `list`): make both runnable as plain scripts so "what's open" / "what's next" don't cost tokens at all.
- Done looks like: `todo/scripts/todo-next.sh` and `todo/scripts/todo-list.sh` (or one script, two subcommands) that read `queue.md` + task frontmatter + claim state directly and print the same reports `/todo next`/`/todo list` currently produce — runnable standalone with no model call.

## Scope

- **`next`**: skip `Done`/legacy `Revisit`/`Parked`; peer-mode claim filtering via `task_claim.sh read`/`claimant-id`/`reclaimable`, disable via `CCXP_PEER_MODE=0`.
- **`list`**: the table (all 8 columns per `todo/SKILL.md`'s `list` workflow), the summary counts (total, by status, committed-to-iteration, claimed mine/peers), the parking-lot count, and drift-detection (untracked `dev/TODO/*.md` not in `queue.md`; stale `queue.md` lines with no file; stale `Blocked by T{id}` references) — all report-only, no mutation.
- **Not in scope**: `/todo sweep`'s mutating logic (Phase 2 blocker-order enforcement, Phase 3 park/close/consolidate judgment calls) — those stay in the skill, they make real decisions, not just a deterministic read.
- The skill (`todo/SKILL.md`) should still document the underlying logic (for `sweep` reuse and for a human reading the skill), but `list`'s and `next`'s own workflow sections should shell out to the script(s) instead of re-deriving the walk/table inline.

## Test plan

- [ ] BATS coverage (`next`): queue with a mix of Open/Done/Parked/peer-claimed/reclaimable-stale entries → script picks the correct top 3, in queue order
- [ ] BATS coverage (`list`): renders the full table + counts correctly; detects an untracked task file, a stale queue line, and a stale `Blocked by T{id}` reference
- [ ] `CCXP_PEER_MODE=0` → no claim filtering (both scripts, where applicable)
- [ ] Empty queue / all-skipped queue → both scripts report that plainly instead of erroring
- [ ] Manual: script output matches `/todo list`'s and `/todo next`'s own current output structure, from a real ccxp-skills checkout

## Done criteria

- [ ] `todo/scripts/todo-next.sh` and `todo/scripts/todo-list.sh` exist, sourceable, BATS-covered
- [ ] `todo/SKILL.md`'s `list` and `next` workflow sections invoke the scripts instead of re-deriving the walk/table
- [ ] No behavior change to `/todo sweep`
