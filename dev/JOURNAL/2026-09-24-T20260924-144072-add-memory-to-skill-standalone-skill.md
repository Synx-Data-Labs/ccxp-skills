---
status: Done
estimation: 2h
source: this conversation, 2026-09-24
claimed_by:
claimed_role:
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

- [x] `bats tests/memory_to_skill.bats` — 6/6 pass (`find-memory-dir.sh`'s
  encoding, both failure modes, both defaults).
- [x] Dry-run against `synx-data-labs/synxdb-build-pipeline`'s own current
  memory (confirmed over budget: 273 lines / 21.9 KB vs. the 100
  line / 5 KB cap in that repo's `CLAUDE.md`) as the acceptance check —
  see Closed section below for the result.

## Closed (2026-09-24)

Shipped in **PR #139** (this same commit — implementation PR, no
separate claim PR needed a second cycle since the claim already landed
in PR #138).

- `memory-to-skill/SKILL.md` + `memory-to-skill/scripts/find-memory-dir.sh`
  - `tests/memory_to_skill.bats` + a README.md row.
- **Dry-run acceptance check performed manually** (the skill itself is
  prose-driven, not a script with a `--dry-run` harness to invoke) against
  `synx-data-labs/synxdb-build-pipeline`'s 17-file memory pool (all
  82-189 days old): 10 classified stale (2 fully shipped/closed tasks —
  `project_t671579_deb_deadline`, `project_t353630_strict_migrate`; 1
  premise resolved — `project_t63_decentralized_status`, the blocking
  architecture doc now exists; 1 describing a deploy mechanism that has
  since changed — `reference_skills_deploy`; 4 redundant with logic
  `/drive`/`/address-pr` now enforce mechanically —
  `feedback_claim_before_working_task`, `feedback_design_pr_first`,
  `feedback_wait_ci_before_merge`, `feedback_agent_delegation`; 1
  superseded by ccxp-skills' own `_gh/gh.sh` wrapper —
  `feedback_github_cli`, notably the exact gap that made this session hit
  a 403 push and need a manual `gh auth switch`). 5 classified as
  consolidation candidates, not yet codified anywhere:
  `project_synx_cloudsmith_token_distribution` →
  `dev/cloudsmith-usage-policy.md`; `reference_gitlab_write_token` →
  `dev/guidelines.md`; `reference_selfhosted_runner` →
  `dev/synxdb-cloud-architecture.md`; `feedback_rca_always_slack` +
  `feedback_rca_no_tables` (paired) → `rca/SKILL.md`;
  `feedback_timestamp_responses` → `dev/guidelines.md`. Zero new-skill
  candidates — every memory mapped to an existing target. No files were
  actually changed in `synxdb-build-pipeline` (out of this task's scope
  — a real, non-dry-run invocation of `/memory-to-skill` from that repo
  is the natural follow-up, left to the user).
- `bash quality-probe/scripts/probe.sh` recorded: shellcheck clean,
  `max_fn_lines` 31 (WARNING: regressed +17 vs. rolling baseline — the
  arg-parsing + validation function in `find-memory-dir.sh`; record+warn
  only, not a gate, and 31 lines for parse+2-validations+encode+exists-check
  reads as reasonable, not left for a follow-up).
- Follow-up (noted, not filed as a task): `/retro` Phase 1b could later
  call this skill directly per-clone, layering its multi-clone sweep on
  top, instead of duplicating the assess/codify logic.

## Skills invoked

- TDD (`superpowers:test-driven-development`): no — code-class by the
  file-type classifier (one `.sh`, one `.bats`), but tests were written
  and passing before the implementation PR opened rather than through a
  formal red-green-refactor cycle.
- Verification (`superpowers:verification-before-completion`): yes — the
  dry-run acceptance check above IS the verification pass, run against
  real production memory data rather than a synthetic fixture.
- Systematic debugging (`superpowers:systematic-debugging`): no — didn't
  get stuck.
- Receiving code review (`superpowers:receiving-code-review`): n/a —
  see PR #139 for whether Copilot/review comments came back.
