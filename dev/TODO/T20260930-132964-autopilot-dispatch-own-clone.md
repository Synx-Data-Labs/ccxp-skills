---
status: Open
estimation: 1h
source: this conversation, 2026-09-30
---

# T20260930-132964: Give /autopilot's dispatched /drive cycles their own persistent clone

## Problem

- **Type**: feature
- `/autopilot`'s Phase 3 dispatches `/drive` via the `Agent` tool with
  **no isolation**, deliberately — running the dispatched cycle inline in
  the parent session's own working directory
  (`autopilot/SKILL.md` Phase 3).
- This lets a background-dispatched `/drive` cycle collide with the
  interactive session doing other git work in the *same* clone at the same
  time — observed directly this session: a dispatched `/drive` cycle was
  still running (`ListAgents` showed a live subagent, ~26min in) while the
  interactive session was asked to run `/todo sweep` and then a fresh
  `/autopilot 8hr`, on the same clone.
- Naive fix (`isolation: "worktree"` per dispatch) doesn't work: a literal
  `git worktree` refuses to check out a branch already checked out
  elsewhere (`fatal: 'main' is already checked out at ...`), and `/drive`
  does `git checkout main && git pull` at nearly every phase transition —
  the parent session normally sits on `main` at rest, so this would
  collide almost every cycle. A fresh worktree/clone per dispatch also
  breaks task-claim identity, which is derived from the clone's path
  (`_session/claimant-id.sh`'s `claimant_id()` hashes
  `git rev-parse --show-toplevel`) — a different path every cycle means a
  different claimant every cycle, breaking the "same clone = same
  claimant, self-releases its own prior claim" assumption
  `_session/task_claim.sh` depends on.

## Solution (brainstormed and approved 2026-09-30)

- Add `dispatch_clone_path` (string or `null`) to `dev/.autopilot-state.json`.
- Lazily create a full (non-shallow) clone — own `.git`, not a worktree —
  at the first Phase 3 dispatch of a run, if `dispatch_clone_path` is
  unset or the directory no longer exists:
  `/tmp/autopilot-clone-<repo-basename>-<8-hex-hash-of-repo-root-path>`.
  Record the path in the state file immediately after.
- Reuse that same path every subsequent cycle in the run — same path every
  time means the same `claimant_id` every time, so task claims from the
  dispatch clone behave exactly like a normal second peer clone (already
  supported by peer-mode claiming).
- Each dispatch prompt instructs the sub-agent to `cd` into that path
  first and sync (`git checkout main && git pull`) before running
  `/drive` — never operate in the interactive session's own directory.
- Tear the clone down (`rm -rf`) at Phase 5 stop.
- Rewrite Phase 3's current "deliberately no isolation" rationale
  paragraph to describe this persistent-clone mechanism instead of arguing
  against isolation.
- Note next to `drive/SKILL.md` Phase 1.5's existing `/tmp/T*-target/`
  orphan-sweep mention that the same sweep should also glob
  `/tmp/autopilot-clone-*/`.

## Done criteria

- [ ] `autopilot/SKILL.md`'s State file section documents
  `dispatch_clone_path`.
- [ ] Phase 3 creates the clone lazily (only if missing) and reuses it
  otherwise, with the naming convention above.
- [ ] Phase 3's dispatch prompt tells the sub-agent to `cd` into the
  dispatch clone and sync before running `/drive`.
- [ ] Phase 5 removes the dispatch clone on stop.
- [ ] Phase 3's "deliberately no isolation" paragraph is rewritten to
  match the new mechanism (no stale rationale left behind).
- [ ] `drive/SKILL.md`'s orphan-sweep note also mentions
  `/tmp/autopilot-clone-*/`.
