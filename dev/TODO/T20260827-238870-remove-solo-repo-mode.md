---
status: Open
estimation: 1h
source: User request 2026-08-27 — reverses recent work (see below)
---

# T20260827-238870: Remove solo-repo (no-CI) mode; always follow the team-repo (peer/CI) process

## Problem

- `claim/SKILL.md` (§ "Solo-repo mode (no CI, direct-to-`main`)", lines
  ~25-87) and `drive/SKILL.md` (line ~118) both carry a "solo-repo" branch
  that skips PR/CI ceremony for repos whose `dev/guidelines.md`/`CLAUDE.md`
  declares themselves solo/no-CI — landing the claim (and eventually the
  work) straight to `main` via `git merge --ff-only` instead of a
  CI-gated PR.
- This mode was added recently and deliberately (`1323c5c feat(claim,drive):
  add solo-repo (no-CI) mode`, `02b0882 docs(claim,drive): drop
  personal-repo/task references from solo-repo mode`) — this task reverses
  that decision, not a bug fix.
- **User's rationale for reversing it**: the "solo repo, single contributor"
  premise the mode was built on doesn't hold going forward — agentic coding
  with multiple agents is becoming the norm, so even a nominally "solo" repo
  can have several agents (sessions/clones) working it concurrently and
  needs the same coordination a team repo needs. The extra ceremony a claim
  PR costs in a single-contributor repo is real, but consistency of process
  (one engineering lifecycle, not two branching behaviors to keep in sync
  and reason about) is worth more than that savings.
- Done = `claim/SKILL.md`'s "Solo-repo mode" section is removed (§1 steps
  3-6 become the only path, no branching on repo declaration), the
  `drive/SKILL.md:118` pointer is removed, and Phase 1/§1's step 3 wording
  that currently says "for a repo declared solo/no-CI, use Solo-repo mode
  above instead" is deleted so peer/CI mode is unconditional.

## Notes

- Check whether any live repo's `dev/guidelines.md`/`CLAUDE.md` actually
  *declares* itself solo/no-CI (the detection heuristic in the section being
  removed: `grep -qi "no ci"` + `grep -qi "direct.to.main"`) — if one does,
  that repo's own Branch and Merge Policy needs updating too, as a
  follow-up task in that repo (not in scope here, which is just the
  `synx-skills` skill definitions).
- Preserve the statusline rationale the removed section documents (branch +
  durable claim commit exist so `statusline-setup`'s `branch:`/`TASK:`
  signals show something useful) — that reasoning still applies to the
  peer/CI claim-PR path that remains; don't lose it, just don't need a
  second mode to restate it.
