---
status: Coding
estimation: 2h
source: this conversation, 2026-09-24
claimed_by: cc1-50ac6891:bf6b098f35f88e3b
claimed_role: interactive
scheduled: 2026-09-21
---

# T20260924-144072: Add /memory-to-skill: standalone, single-clone memory review skill

Design approved in-conversation 2026-09-24 — see Solution direction below;
claimed and driven directly, no separate design PR.

## Problem

- `retro/SKILL.md` Phase 1b ("Review memory") already implements memory
  review + consolidation, but only runs as part of the full weekly
  retrospective — no standalone way to run just memory review on demand
  from a single clone.
- Phase 1b's multi-clone sweep (`ls -d ~/.claude/projects/*"${REPO_BASENAME}"*/memory`)
  and stale-directory detection add complexity not needed for an
  on-demand, single-clone check — scope down to the invoking clone only.
- No existing branch handles a recurring memory that doesn't map to any
  existing skill or doc target — today it's either force-fit into
  `guidelines.md`/a skill it doesn't quite belong in, or silently
  skipped. Need a branch that files a new-skill-design task instead.

## Solution direction

- New skill `memory-to-skill/SKILL.md`, scoped to
  `~/.claude/projects/<encoded-cwd>/memory/` for the current clone only
  (computed directly from `pwd`, no glob sweep).
- Reuse Phase 1b's classification logic (target: `dev/guidelines.md`,
  a skill's own `SKILL.md`, `DEPENDENCIES.md`/`gotchas.md`, or a
  hard-gate hook) and its stale-memory deletion + consolidation-task
  filing (`Category: process`, `Source: memory-to-skill YYYY-MM-DD`).
- New branch: a recurring memory with no existing skill/doc target
  files a new-skill-design task via `new-task`, instead of being
  force-fit or dropped.
- Note in the new skill's own doc (not required to implement yet) that
  `/retro` Phase 1b could later call this skill directly, with the
  multi-clone sweep layered on top, to avoid duplicated logic.

## Test plan

- Dry-run against `synx-data-labs/synxdb-build-pipeline`'s own current
  memory (confirmed over budget: 273 lines / 21.9 KB vs. the 100
  line / 5 KB cap in that repo's `CLAUDE.md`) as the acceptance check.
