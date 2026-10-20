---
status: Done
scheduled: 2026-10-19
estimation: 2
source: this conversation, 2026-10-19 (maintainer direct instruction, in-conversation approved — drive's "design approved in-conversation" carve-out)
claimed_by:
claimed_role:
---

# T20261019-554821: Rename "dispatcher" agent to "ccxp-agent", mandate worktree isolation for repo-changing jobs

## Problem

- **Type**: rename + hardening (production incident follow-up)
- The `agent-pairing` skill's bundled main-session agent persona was
  named "dispatcher" (`assets/dispatcher.md`, installed to
  `~/.claude/agents/dispatcher.md`, set via `settings.json`'s
  `"agent": "dispatcher"` key). The maintainer asked to rename this
  identity to "ccxp-agent" throughout.
- Separately, a real production incident: a dispatcher session ran a
  background repo-changing job **without worktree isolation**. The job
  operated directly on whatever branch happened to be checked out in
  the shared clone and overwrote the user's own staged, uncommitted
  change — unrecoverable data loss. The agent's own "Jobs that could
  collide" section already had an isolation rule (`isolation:
  "worktree"` for repo-changing jobs), but it read as a soft
  recommendation rather than an unconditional hard rule, leaving room
  for a dispatcher session to misjudge a job as not needing it.
  (Pre-existing memory note referenced this exact gap at
  `assets/dispatcher.md:31`, previously blocked on a believed lack of
  SSH push access to this repo — confirmed resolved this session.)

## Fix

- **Rename**, comprehensive and consistent:
  - `assets/dispatcher.md` -> `assets/ccxp-agent.md` (`git mv`).
  - Frontmatter `name: dispatcher` -> `name: ccxp-agent`; description's
    `claude --agent dispatcher` example -> `claude --agent ccxp-agent`;
    opening identity line now reads "You are ccxp-agent, a dispatcher
    persona."
  - `agent-pairing.sh`: asset path, installed filename
    (`agents/ccxp-agent.md`), the `settings.json` `"agent"` value
    compared/written everywhere (`on`/`off`/`status`), and all
    user-facing messages.
  - `SKILL.md`: every doc example and cross-reference updated.
  - Checked the rest of the repo for other "dispatcher" references
    (`_session/task_claim.sh`, `tests/task_claim.bats`) — those use
    "dispatcher" as the generic case-statement-dispatch English word,
    unrelated to this agent identity; left untouched. JOURNAL entries
    are historical record and were not rewritten.
- **Backward compat**: added a `LEGACY_AGENT_FILE` check in the script
  — `on` now prints a one-line notice if the old
  `agents/dispatcher.md` is still present (never touches or deletes
  it), and `SKILL.md` gained an "Upgrading from the old dispatcher
  name" note: re-running `/agent-pairing on` is sufficient, since a
  stale `"agent": "dispatcher"` value no longer matches the managed
  name and gets flipped forward automatically; the old file is removed
  by hand once the new one is confirmed working.
- **Worktree mandate**, modeled on `/drive`'s own Phase 6
  `--dispatch-blockers` phrasing (`isolation: "worktree"` with a
  one-line rationale): rewrote the "Repo-changing jobs" bullet in
  `assets/ccxp-agent.md`'s "Jobs that could collide" section into an
  explicit hard rule — any job that writes, edits, stages, commits, or
  checks out a branch in the repo must be dispatched with
  `isolation: "worktree"`, no per-job judgment call, erring toward
  isolating on any doubt. States the production incident as the
  rationale. Kept the existing, narrower exception for skill-driven
  jobs (`/drive`, `/autopilot`, `/land`, `/address-pr`) that manage
  their own clone/worktree isolation internally — reworded so it reads
  as one specific carve-out, not a precedent for skipping isolation
  elsewhere.
- **Tests**: renamed every `dispatcher`/`dispatcher.md` occurrence in
  `tests/agent_pairing.bats` to `ccxp-agent`/`ccxp-agent.md` (all 16
  existing tests exercise this identity, none were generic). Added 4
  new tests: frontmatter `name: ccxp-agent`, presence of the hard
  worktree-isolation rule's exact wording, and a legacy-install test
  asserting the old `dispatcher.md` is reported as stale, never
  touched, while `settings.json`'s stale `"agent": "dispatcher"` value
  is flipped forward to `"ccxp-agent"` by `on`.
- 20 BATS tests, all green (`bats tests/agent_pairing.bats`).

## Files changed

| File | Change |
|---|---|
| `agent-pairing/assets/dispatcher.md` -> `assets/ccxp-agent.md` | renamed + edited |
| `agent-pairing/SKILL.md` | docs renamed, upgrade-path note added |
| `agent-pairing/scripts/agent-pairing.sh` | renamed logic, legacy-file notice |
| `tests/agent_pairing.bats` | renamed assertions, 4 new tests |

## Next steps

- None required for this task. Anyone with a locally-installed
  `~/.claude/agents/dispatcher.md` and/or `settings.json`'s
  `"agent": "dispatcher"` should re-run `/agent-pairing on` per the
  new SKILL.md note, then remove the old file by hand.

## Closed

- PR: (filled in after opening)
