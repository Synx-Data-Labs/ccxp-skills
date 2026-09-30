---
status: In Progress
estimation: 1h
source: this conversation, 2026-09-30
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-28
---

# T20260930-132964: Give /autopilot's dispatched /drive cycles their own persistent clone

Design approved in-conversation 2026-09-30 (brainstormed with the user
before filing — the Solution section below is that approved design);
skipping the separate design PR.

## TLDR

- **Type**: feature
- **Problem**: `/autopilot`'s dispatched `/drive` cycles run inline in the
  parent session's own clone, so a background cycle can collide with the
  interactive session doing other git work at the same time.
- **Solution**: give the dispatch its own persistent, path-stable clone —
  created once per run, reused every cycle, torn down at stop — rather than
  a per-call `isolation: "worktree"` (which would break both the
  git-worktree branch lock and task-claim identity stability).

## Problem

- `/autopilot`'s Phase 3 dispatches `/drive` via the `Agent` tool with
  **no isolation**, deliberately — running the dispatched cycle inline in
  the parent session's own working directory (`autopilot/SKILL.md:55`).
- This lets a background-dispatched `/drive` cycle collide with the
  interactive session doing other git work in the *same* clone at the same
  time — observed directly this session: a dispatched `/drive` cycle was
  still running (`ListAgents` showed a live subagent, ~26min in) while the
  interactive session was asked to run `/todo sweep` and then a fresh
  `/autopilot 8hr`, on the same clone.
- Naive fix (`isolation: "worktree"` per dispatch, mirroring `/drive`
  Phase 6 step 3's `--dispatch-blockers` mode) doesn't work here: a literal
  `git worktree` refuses to check out a branch already checked out
  elsewhere (`fatal: 'main' is already checked out at ...`), and `/drive`
  does `git checkout main && git pull` at nearly every phase transition
  (e.g. `drive/SKILL.md`'s "Post-merge branch hygiene" note) — the parent
  session normally sits on `main` at rest, so this would collide almost
  every cycle.
- A fresh worktree/clone per dispatch also breaks task-claim identity,
  which is derived from the clone's path (`_session/claimant-id.sh`'s
  `claimant_id()`, line ~78, hashes `git rev-parse --show-toplevel`) — a
  different path every cycle means a different claimant every cycle,
  breaking the "same clone = same claimant, self-releases its own prior
  claim" assumption `_session/task_claim.sh` depends on
  (`autopilot/SKILL.md:55`'s own existing rationale for why it currently
  avoids isolation at all).

## Context

- **Feature** — this only changes how `/autopilot` Phase 3 dispatches
  `/drive`; it does not touch `/drive`, `task_claim.sh`, or
  `claimant-id.sh` themselves.
- `--dispatch-blockers` (`drive/SKILL.md` Phase 6 step 3) already uses
  `isolation: "worktree"` for a **single, one-off** dispatch — that's fine
  there because the claim only has to succeed once and there's no reuse
  requirement. `/autopilot` dispatches repeatedly, cycle after cycle,
  which is what makes claimant-identity stability matter here and not
  there.
- `_session/task_claim.sh`'s peer-mode claiming (on by default,
  `CCXP_PEER_MODE`) already supports multiple clones of the same repo
  claiming tasks concurrently — a dedicated dispatch clone is just another
  peer from its perspective, no new mechanism needed there.

## Solution (brainstormed and approved 2026-09-30)

- Add `dispatch_clone_path` (string or `null`) to `dev/.autopilot-state.json`
  (`autopilot/SKILL.md:19-28`'s JSON schema).
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
- Tear the clone down (`rm -rf`) at Phase 5 stop
  (`autopilot/SKILL.md:83-104`).
- Rewrite Phase 3's current "deliberately no isolation" rationale
  paragraph (`autopilot/SKILL.md:55`) to describe this persistent-clone
  mechanism instead of arguing against isolation.
- Note next to `drive/SKILL.md:178`'s existing `/tmp/T*-target/`
  orphan-sweep mention that the same sweep should also glob
  `/tmp/autopilot-clone-*/`.
- **Alternatives considered and rejected**:
  - *Literal `git worktree` isolation per dispatch* — rejected: git
    refuses to check out a branch already checked out in another worktree
    of the same `.git`, and `/drive` checks out `main` constantly; the
    parent session normally sits on `main` at rest, so this would collide
    almost every cycle.
  - *Fresh clone per dispatch (ephemeral, like `/drive` Phase 1.5's
    cross-repo target clone)* — rejected: a different path every cycle
    means a different `claimant_id` every cycle
    (`_session/claimant-id.sh`), breaking the "same clone = same
    claimant, self-releases its own prior claim" assumption
    `task_claim.sh` depends on — exactly the problem the existing
    "deliberately no isolation" rationale (`autopilot/SKILL.md:55`)
    already correctly identified for the worktree case; a fresh clone has
    the identical failure mode.
  - *Override `claimant_id()`/`task_claim.sh` to accept an explicit path
    pinned back to the parent clone* — rejected: `claimant_id()` already
    takes an optional path argument (`_session/claimant-id.sh`), but
    `_tc_claimant_id()` (`_session/task_claim.sh:108-125`) never threads
    one through, so this would mean touching widely-shared claim/identity
    infrastructure used by every skill in the repo for a need that a
    plain persistent-clone (peer-mode-compatible) approach already solves
    with zero changes there.

## Test plan

- [x] Manual read-through: `autopilot/SKILL.md` Phase 3/5 + State file
  section describe the persistent-clone mechanism consistently (no stale
  "deliberately no isolation" prose left).
- [x] Manual read-through: `drive/SKILL.md:178`'s orphan-sweep note
  mentions `/tmp/autopilot-clone-*/`.
- [x] `skill-quality` ratchet (`skill_score.py --check
  dev/quality/skill-scores.json`) passes on `autopilot/SKILL.md` — no
  regression from the prose changes (48/48 skills at or above baseline).
- [x] `_docs/lint-docs.sh` / `lint_paragraphs.py` clean on both edited
  files.
- No BATS tests — this is a skill-prose change (dispatch mechanics
  described in `autopilot/SKILL.md`, no new script), not executable code.

## Done criteria

- [x] `autopilot/SKILL.md`'s State file section (line 19-28) documents
  `dispatch_clone_path`.
- [x] Phase 3 (line 56-72) creates the clone lazily (only if missing) and
  reuses it otherwise, with the naming convention above.
- [x] Phase 3's dispatch prompt (line 72) tells the sub-agent to `cd`
  into the dispatch clone and sync before running `/drive`.
- [x] Phase 5 (line 118) removes the dispatch clone on stop.
- [x] Phase 3's "deliberately no isolation" paragraph (former line 55) is
  rewritten to match the new mechanism (no stale rationale left behind).
- [x] `drive/SKILL.md:178`'s orphan-sweep note also mentions
  `/tmp/autopilot-clone-*/`.

## Root cause

- `autopilot/SKILL.md:55` (Phase 3) hard-codes no isolation, with an
  explicit, deliberate rationale: a per-dispatch worktree/clone would
  break claimant-identity stability. This was a **correct** call at the
  time the skill was authored — the tradeoff it rejected (isolation) was
  real, and the tradeoff it accepted (shared working directory) was
  believed low-risk since `/autopilot` is meant to run unattended.
- The gap: it didn't anticipate the **interactive** use case — a human
  driving the same session/clone concurrently with a dispatched cycle
  (this exact conversation: `/autopilot 8hr` was invoked while an earlier
  autopilot run's dispatched `/drive` cycle was still live in the same
  clone). That's an omission in scope, not a wrong design decision for
  the unattended-only case it was written for.
- This task doesn't relitigate the original no-isolation call — it
  removes the tradeoff entirely by making the dispatch clone
  *persistent-and-reused* rather than *per-call*, which gets isolation
  without paying the identity-instability cost the original rationale
  correctly flagged.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `autopilot/SKILL.md` | 15-28 (§ State file) | add `dispatch_clone_path` field |
| `autopilot/SKILL.md` | 53-73 (Phase 3) | lazy clone creation/reuse, dispatch prompt `cd` instruction, rewritten rationale |
| `autopilot/SKILL.md` | 83-104 (Phase 5) | tear down the dispatch clone on stop |
| `drive/SKILL.md` | 178 (orphan-sweep note) | mention `/tmp/autopilot-clone-*/` alongside `/tmp/T*-target/` |
| `_session/claimant-id.sh` | `claimant_id()` (~line 78) | confirms path-based identity derivation (read-only reference, not touched) |
| `_session/task_claim.sh` | `_tc_claimant_id()` (108-125) | confirms no path override exists today (read-only reference, not touched) |
