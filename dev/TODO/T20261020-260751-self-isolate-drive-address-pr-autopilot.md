---
status: Open
estimation: 1
source: this conversation, 2026-10-20 (maintainer direct instruction — "file it and start driving", design PR still required, not skipped, per explicit instruction below)
related: [T20261019-554821, T20261019-174788]
---

# T20261020-260751: Self-isolate ccxp-skills write-operations (worktree) inside `/drive`, `/address-pr`, `/autopilot` — not just at dispatcher level

## TLDR

- **Type**: feature (architecture / safety hardening)
- **Problem**: the dispatcher-level `isolation: "worktree"` mandate
  (T20261019-554821) only protects jobs routed through a `ccxp-agent`
  dispatch. `/drive` and `/address-pr` have zero internal self-isolation
  for the common same-repo case; `/autopilot` self-isolates, but only via
  its own separate convention. Two real incidents this session happened
  because safety depended on the caller remembering to isolate externally.
- **Solution**: move default worktree self-isolation for write-mutating
  phases INSIDE the skills themselves — one worktree per task/PR
  lifetime, with already-isolated detection, an explicit interactive
  opt-out, and self-cleanup — scoped to `/drive`, `/address-pr`,
  `/autopilot` in this pass.

## Problem

- **Incident 1 (unrecoverable data loss)**: a `ccxp-agent`-dispatched
  background job ran a repo-changing `git checkout` directly in the
  shared/ambient clone instead of an isolated worktree, overwriting the
  user's own pre-existing staged, uncommitted change — unrecoverable.
  This is the documented rationale for T20261019-554821
  (`dev/JOURNAL/2026-10-19-T20261019-554821-rename-dispatcher-to-ccxp-agent.md:20-31`).
- **Incident 2 (cross-job PR pollution)**: a job working its own task
  committed an unrelated `queue.md` line onto a concurrently-running
  job's already-open PR
  [#355](https://github.com/Synx-Data-Labs/ccxp-skills/pull/355)
  ("docs(queue): stage T20261016-393753") because it operated directly
  in the shared clone before reaching its own isolated worktree.
  *(Reported by the maintainer this session; the final merged [PR #355](https://github.com/Synx-Data-Labs/ccxp-skills/pull/355)
  diff is a single clean commit with no stray line — consistent with
  the pollution being caught and fixed before merge; not independently
  re-derivable from git history beyond that — labeled assumed, not
  verified, on that detail only.)*
- The dispatcher-level fix (T20261019-554821, [PR #368](https://github.com/Synx-Data-Labs/ccxp-skills/pull/368), merged) made the
  `ccxp-agent` persona hard-mandate `isolation: "worktree"` for every job
  **it dispatches** (`agent-pairing/assets/ccxp-agent.md:42`). This closes
  the gap only for jobs that go *through* a `ccxp-agent` dispatch.
- That same line carries a carve-out: *"skill-driven jobs (`/drive`,
  `/autopilot`, `/land`, `/address-pr`) manage their own clone or
  worktree isolation internally... so give them no isolation at the
  dispatch level."* Verified false for the common same-repo case:
  - `/drive` (`drive/SKILL.md`) only creates its own clone/worktree in
    Phase 1.5 (`drive/SKILL.md:146-208`, cross-repo mode — `Target
    repo` set) and in the Phase 6 `--dispatch-blockers` sub-case
    (`drive/SKILL.md:483-485`, one-off, opt-in). Phase 1's claim PR,
    Phase 2's design-PR branch, and Phase 3's implementation branch for
    the ordinary same-repo task (no `Target repo:`) all operate
    directly on whatever clone the session is already in — no
    worktree, no clone (`drive/SKILL.md:106-145`, `210-241`).
  - `/address-pr` (`address-pr/SKILL.md`) has a "Clone-locality note"
    (`address-pr/SKILL.md:78-86`) that is explicitly **informational
    only** — it never isolates; it operates directly in whichever
    clone/cwd it's invoked from for the same-repo case.
  - `/autopilot` (`autopilot/SKILL.md`) genuinely self-isolates, but via
    its OWN mechanism — a single dedicated full clone
    (`autopilot/SKILL.md:95-107`), reused across cycles, deliberately
    never a worktree (`autopilot/SKILL.md:106`) — and it dispatches
    `/drive T<id> --auto-selected` with **no isolation** at the
    Agent-tool level (`autopilot/SKILL.md:111`), relying entirely on its
    own clone convention, not on anything `/drive` itself does.
- Net effect: real safety this session came entirely from `ccxp-agent`
  manually supplying `isolation: "worktree"` externally, or from
  `/autopilot`'s own separate clone convention — never from `/drive` or
  `/address-pr` protecting themselves. Any caller that invokes these
  skills without going through `ccxp-agent` (an interactive human, a
  bare `/ccxp` cron session, a hand-run `/drive`) gets zero protection
  against incident-1/2-style collisions.

## Context

- This suite already runs multiple ccxp sessions as parallel peers by
  default (`CCXP_PEER_MODE`, `drive/SKILL.md:122`,
  `_session/task_claim.sh`) — concurrent write access to the same clone
  is the normal operating mode, not an edge case.
- Existing isolation precedent to **extend, not invent**: `/drive`
  Phase 1.5 (`drive/SKILL.md:146-208`) already does exactly this for
  cross-repo tasks — one ephemeral clone per task, reused across the
  task's phases, explicit `rm -rf` cleanup at Phase 7
  (`drive/SKILL.md:589`), with an orphan-sweep backstop
  (`drive/SKILL.md:208`).
- Stale-worktree accumulation is an existing, already-known problem
  this change must not worsen: 8 worktrees found live in this one
  workspace at authoring time (`git worktree list`, verified
  2026-10-20: 4 under `ccxp-skills/.claude/worktrees/`, 2 sibling
  `ccxp-skills-wt-*` dirs, 1 scratchpad clone, 1 primary checkout); the
  maintainer separately reports ~30 accumulated in this session's
  conversation (not independently re-verified beyond this snapshot —
  labeled assumed). `T20261019-174788` (open, related) already flags
  "no shared convention" for sibling worktrees as an open design
  question.
- Path-resolution is **not a new risk**: this very task is being driven
  by an agent whose own primary working directory is a git worktree of
  a *different* sibling repo
  (`synxdb-build-pipeline/.claude/worktrees/agent-ad5c405625297af13`),
  created by the exact `ccxp-agent` `isolation: "worktree"` mechanism
  this task extends — confirmed first-hand, live, that skill content,
  relative script paths, and `<skills-root>` resolution all work
  correctly from inside a worktree with no special-casing. Worktrees
  share the parent repo's `.git` object store/history by design, so a
  worktree of `ccxp-skills` itself (the self-referential case here,
  since the target repo IS `ccxp-skills`) resolves identically.
- `T20261019-554821` (merged, [PR #368](https://github.com/Synx-Data-Labs/ccxp-skills/pull/368)) is the dispatcher-level sibling
  fix — it stays as defense-in-depth; this task does not touch its hard
  mandate, only the carve-out's accuracy.

## Solution

- **Scope: write operations only** (*alternative rejected*: force
  worktree isolation on every skill invocation uniformly, for
  simplicity — rejected because it penalizes the majority read-only
  call pattern, `/todo status`, `/eta`, `claim status`, `audit`, for no
  safety benefit, and the maintainer explicitly ruled this out in the
  pre-task discussion).
- **Granularity: one worktree per task/unit-of-work, not per call.**
  Mirror `/drive` Phase 1.5's own cross-repo pattern — create once,
  reuse across claim → design → implement → close, remove once at
  close. (*Alternative rejected*: a fresh worktree per skill call within
  one task, e.g. a separate one for the claim PR vs. the design PR —
  rejected as needless create/destroy churn, worsening the exact
  staleness problem this task must not make worse.)
- **Detection: skip self-isolation when already isolated**, instead of
  blindly nesting a worktree inside a worktree every time. Checked in
  order: (a) explicit opt-out (below); (b) cwd already under
  `.claude/worktrees/` (the `ccxp-agent`/platform dispatch convention)
  or matching `/tmp/autopilot-clone-*` / `/tmp/T*-target` (the existing
  dedicated-clone conventions) — skip, operate in place. (*Alternative
  rejected*: track isolation state only via an explicit env var set by
  every caller, never path sniffing — rejected because it requires
  every existing caller, including historical `ccxp-agent` dispatches
  and `/autopilot`'s current `--auto-selected` dispatch — neither of
  which sets any such var today — to be updated in lockstep before the
  safety net engages; path-based detection degrades safely, worst case
  a harmless redundant nested worktree, never a missed isolation.)
  `/autopilot` additionally passes the signal explicitly when
  dispatching `/drive` (defense-in-depth for its own known case, not
  reliance on path-sniffing alone).
- **Same-repo self-isolation mechanism (new)**, for `/drive` and
  `/address-pr`: a new shared helper, `_worktree/self-isolate.sh`
  (mirrors the `_session/`, `_gh/` sourceable-helper convention) with:
  - `acquire <task-id-or-pr> <slug>` — creates (or, idempotently,
    returns the path of an already-existing worktree for the same id —
    needed across a park/resume cycle) a worktree at
    `<repo-root>/.claude/worktrees/t<id>-<slug>` on a fresh branch off
    `main`; prints the absolute path.
  - `release <path>` — `git worktree remove <path> --force` + `git
    worktree prune`; safe/no-op on an already-removed path.
  - `/drive` Phase 1 (same-repo branch only — `Target repo` unset):
    call `acquire` right after the clone-locality guard, before the
    claim PR; do all subsequent same-repo phases (claim PR, design PR,
    implementation, PR) from that worktree path exactly as Phase 1.5
    does for `$TARGET` — tracked here as a new `$WORK` path. Phase 7
    same-repo close calls `release $WORK` as its last step, mirroring
    the existing Phase 1.5 cross-repo cleanup pattern.
  - `/address-pr`, invoked **standalone** (not nested inside an
    already-isolated `/drive` run): `acquire` keyed by the PR's
    branch/number before checking it out, work there, `release` on
    exit (merge or defer). Invoked **nested** from `/drive` (the common
    case — Phase 0/2/4/5 call `/address-pr` on a specific PR from
    within `/drive`'s own already-isolated `$WORK`): the
    already-isolated detection recognizes the cwd and skips
    re-isolating — `/address-pr` just operates in the `$WORK` it was
    handed.
- **Interactive opt-out** (not forced isolation for a human at their
  own terminal): new `/drive --no-isolate` flag (combinable with
  existing flags, same pattern as `--dispatch-blockers`/
  `--auto-selected`) and `DRIVE_NO_ISOLATE=1` env var for a whole
  session. Defaults to isolate-on. Distinct from `/drive`'s existing
  "Solo-repo mode" (`drive/SKILL.md:137-139`, about no-CI repos going
  direct-to-`main`) — `--no-isolate` is about *where the work happens*
  (worktree vs. current directory), independent of CI/merge policy.
  (*Alternative rejected*: no opt-out, force isolation unconditionally —
  rejected per the maintainer's explicit UX concern: a human can't
  see/edit files in an invisible worktree elsewhere, and neither
  incident originated from the single-threaded interactive case.)
- **Cleanup ships in this PR**, not a follow-up: `release` above, wired
  into every new self-isolation call site (Phase 7 for `/drive`,
  on-exit for `/address-pr`). Additionally extend the existing
  orphan-sweep backstop (`drive/SKILL.md:208`, currently only
  `/tmp/T*-target/` + `/tmp/autopilot-clone-*/`) to also glob
  `.claude/worktrees/t*` older than 7 days with no corresponding live
  `In Progress`/`Design` task — the exact gap that let the current
  stale worktrees accumulate with "no shared convention"
  (`T20261019-174788`).
- **Out of scope, follow-up task filed at close**: `/land` (`/gcpr`),
  `/stage`, `/claim`, `/ipm` get the same self-isolation treatment as a
  documented follow-up — not blocking this pass. The
  `ccxp-agent.md:42` carve-out line is corrected in this PR to name
  only the skills that actually self-isolate after this change lands.
  The **external** dispatcher-level `isolation: "worktree"` hard
  mandate in that same file (the "Repo-changing jobs MUST be dispatched
  with isolation: worktree" rule) is explicitly **not** removed or
  weakened — it remains defense-in-depth even after skills self-isolate.

## Root cause

- The carve-out line (`agent-pairing/assets/ccxp-agent.md:42`,
  "skill-driven jobs... manage their own clone or worktree isolation
  internally") was introduced verbatim (pre-rename) in the very first
  commit that added this persona, `12efa46` (2026-10-10,
  T20261010-736699) — `agent-pairing/assets/dispatcher.md:38` at that
  commit: *"Exception: skill-driven jobs (`/drive`, `/autopilot`,
  `/land`, `/address-pr`) manage their own clones and PRs, so give them
  no isolation."*
- At that time `/drive` Phase 1.5's cross-repo ephemeral-clone mechanism
  already existed (present since `5afe835`, "Initial public release",
  2026-09-28 — verified via `git log -S"Phase 1.5" -- drive/SKILL.md`),
  so the claim was true for cross-repo tasks. The author generalized
  "true for cross-repo" to "true for all of `/drive`'s operation"
  without checking the same-repo path, which has never had its own
  isolation — not a deliberate decision, an unverified assumption that
  happened to be half-right and was never revisited.
- T20261019-554821 (2026-10-19, [PR #368](https://github.com/Synx-Data-Labs/ccxp-skills/pull/368)) rewrote the surrounding
  "Repo-changing jobs" bullet into today's hard dispatcher-level mandate
  and *reworded* the carve-out ("so it reads as one specific carve-out,
  not a precedent for skipping isolation elsewhere" —
  `dev/JOURNAL/2026-10-19-T20261019-554821-rename-dispatcher-to-ccxp-agent.md:59-71`)
  but explicitly kept the carve-out's list and substance unchanged — the
  investigation that would have caught the same-repo gap (reading
  `/drive`'s and `/address-pr`'s own SKILL.md phase-by-phase, as this
  task's Problem section above does) was out of scope for that task,
  which was itself scoped to the rename plus the dispatcher-level hard
  rule.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `drive/SKILL.md` | 64-145 (Phase 1), 146-208 (Phase 1.5), 210-241 (Phase 2), 514-591 (Phase 7) | add same-repo `$WORK` self-isolation (`acquire` in Phase 1, `release` in Phase 7), `--no-isolate` flag |
| `address-pr/SKILL.md` | 78-86 (clone-locality note), entry point | add standalone self-isolation + nested-detection |
| `autopilot/SKILL.md` | 95-117 (dispatch clone + `/drive` dispatch) | doc update: explicit already-isolated signal passed to dispatched `/drive`; note interaction |
| `agent-pairing/assets/ccxp-agent.md` | 42 (carve-out line) | correct wording to match actual post-change state; external hard mandate unchanged |
| `_worktree/self-isolate.sh` (new) | — | `acquire`/`release` helper, BATS-tested |
| `tests/self_isolate.bats` (new) | — | acquire/release/idempotency/already-isolated-detection coverage |

## Test plan

- [ ] `bats tests/self_isolate.bats` (new): `acquire` creates a worktree
      at the deterministic path; `acquire` is idempotent (second call on
      the same id returns the same path, no duplicate/failure);
      `release` removes it and is idempotent on an already-missing
      path; already-isolated detection correctly skips under
      `.claude/worktrees/*`, `/tmp/autopilot-clone-*`, `/tmp/T*-target`,
      and with the opt-out env var set.
- [ ] `bats tests/` full suite green — no regressions.
- [ ] Manual dry run: invoke `/drive` on a throwaway same-repo task
      end-to-end and confirm it operates from a `.claude/worktrees/t<id>-*`
      path, not the ambient clone, and the worktree is gone after close.
- [ ] Manual dry run: invoke `/address-pr <N>` standalone on a real open
      PR and confirm it isolates; invoke it nested from inside a
      `/drive` run and confirm it does NOT double-isolate.
- [ ] `/drive --no-isolate` (or `DRIVE_NO_ISOLATE=1`) confirmed to skip
      isolation and operate in the current directory.

## Done criteria

- [ ] `_worktree/self-isolate.sh:1` defines `acquire`/`release`,
      satisfied by `tests/self_isolate.bats:1` (all green, test names
      `acquire creates worktree` / `acquire is idempotent` /
      `release removes worktree` / `release is idempotent` /
      `already-isolated detection skips`).
- [ ] `drive/SKILL.md:~70` (new call, same-repo Phase 1, right after
      the clone-locality guard at `drive/SKILL.md:80-92`) invokes
      `acquire`; `drive/SKILL.md:~551` (same-repo Phase 7 close, after
      `drive/SKILL.md:551`) invokes `release $WORK` as the last step.
- [ ] `drive/SKILL.md:19` (the Argument section, alongside the existing
      `--dispatch-blockers`/`--auto-selected` bullets at
      `drive/SKILL.md:25-33`) documents the new `--no-isolate` flag and
      `DRIVE_NO_ISOLATE=1` env var, defaulting to isolate-on.
- [ ] `address-pr/SKILL.md:78-86` (replacing the "informational only"
      clone-locality note) calls `acquire`/already-isolated-detection
      for the standalone case, and reuses the caller's `$WORK` for the
      nested case.
- [ ] `autopilot/SKILL.md:111` (the `/drive` dispatch call) documents
      the explicit already-isolated signal it now passes.
- [ ] `agent-pairing/assets/ccxp-agent.md:42` carve-out line corrected
      to describe the actual post-change state; `git diff` on that file
      shows the hard `isolation: "worktree"` mandate sentence
      unchanged/not removed.
- [ ] `drive/SKILL.md:208` (the existing orphan-sweep note) extended to
      also glob `.claude/worktrees/t*`.
- [ ] A new follow-up `T<id>` task file exists under `dev/TODO/` (filed
      via `_taskid/new.sh`, staged via `/stage`) scoping `/land`/`/gcpr`,
      `/stage`, `/claim`, `/ipm` self-isolation, and is referenced from
      this task's `## Closed` section below.
- [ ] `bats tests/self_isolate.bats tests/*.bats` exits 0 (full suite,
      no regressions).

## Closed

## Skills invoked
