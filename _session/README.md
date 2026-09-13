# `_session/` — cross-session coordination

This lib provides four things, with deliberately different semantics:

1. **Project board mirror** (`status.sh`, `set-pr-ref.sh`) — task-keyed, written to the **Project V2 board**. Pure visualization: best-effort writes, no locking, no `/todo next` impact. Documented immediately below.
2. **On-main task-claim lock** (`task_claim.sh`) — the durable cross-session claim, written to the task file's `claimed_by` frontmatter and arbitrated atomically by the merge-to-`main`. This is the authoritative "who owns this task" lock; the `sync-tasks` workflow projects it onto the board. See [Task-claim lock](#task-claim-lock-task_claimsh--on-main-authoritative) below.
3. **PR ownership — DERIVED from the task claim** (`task_claim.sh pr-owner`). A PR is owned by whoever owns the **task it implements**; there is no separate per-PR ownership state. This replaced the old PR-resident `cc-owned` label + marker comment (`pr_owner.sh`), whose stranded markers under dead sessions were the recurring pain (T20260622-404636). See [PR ownership](#pr-ownership-derived-from-the-task-claim) below.
4. **Task attribution by location** (`attribution.sh`) — a read-only *consumer* of the `claimed_by` data (no writes, no locking). It buckets task counts by the `<host>:<clone-path>` identity over a window and labels each location `ccxp` / `interactive` / `unattributed`, for the ccxp Phase 1.3 standup section that measures autonomous-vs-interactive throughput (T20260624-313487). Completed tasks recover their (close-time-cleared) `claimed_by` from git history; classification keys on `ATTRIBUTION_CCXP_PATHS`. See its script header for the API.
5. **Lint-frozen pick-path probe** (`lint_frozen.sh`) — a read-only probe used by `/todo next` (step 4 exclude) and `/drive` (Phase 1 claim guard) to skip tasks whose *current* frontmatter already fails the changed-mode `Lint task frontmatter` check (the [T20260626-353630] schema-fork class), so the picker never recommends — and `/drive` never opens an un-mergeable claim PR for — a task it could only abandon at claim time (T20260629-185057). `lint_frozen_is_frozen <file> [repo]`: return `0` = frozen, `1` = claimable (lint-clean **or** unclassifiable — the inverted fail-safe vs the IPM drain gate, so it never hides pickable work). Reuses the `lint_tasks.py --changed` primitive (override path via `LINT_TASKS_PY`; `LINT_FROZEN_IDS` is the hermetic test hook). Pick-path analogue of the drain-gate exemption `_ipm_drain_is_lint_frozen` (build-pipeline, T20260628-951477); becomes a no-op once T20260626-353630 lands. See its script header for the API.

> **Note:** the legacy *soft session-visualization* layer (`claim.sh` / `heartbeat.sh` / `read.sh` / `release.sh` / `prune.sh`, plus the 4 Project fields `machine` / `clone_path` / `cc_session_id` / `last_heartbeat`) was **retired** (T20260616-308030) in favor of the on-main `claimed_by` lock projected by `sync-tasks`. It had no reader and required a token the cron lacks. The Project Status mirror, PR-ref annotation, and identity helpers below survive it.

## Project board mirror (Project V2)

Lets `/drive` and `/address-pr` reflect a task's **stage** (Status) and its **task→PR mapping** (issue-title suffix) onto the Project board, for human-visible coordination. Pure visualization — no decision-making, no locking, no `/todo next` impact.

The task's **Status** single-select is mirrored from the task file's frontmatter `status:` by `status.sh` (Open/Design/Coding/Review/Blocked/Parked/Done). Writes are best-effort, failures are logged and ignored — the frontmatter `status:` (and, on `main`, the `sync-tasks` projection) remains the source of truth.

Separately, the task's **issue title** (which the Project item inherits) gets a `(<repo>#<num>)` suffix appended by `set-pr-ref.sh` when a PR opens, e.g. `T20260510-285938: … (ccxp-skills#37)`. The `<task-id>:` prefix is preserved, so the title-prefix lookup keeps working. It is *not* cleared on close — the task→PR mapping stays as a permanent annotation.

## Scripts

| Script | Purpose | Cost |
|--------|---------|------|
| `status.sh <task-id> <value>` | Set the Project `Status` single-select (Open/Design/Coding/Review/Blocked/Parked/Done). Mirrors the task file's frontmatter `status:` to the board. | 4-5 GraphQL calls |
| `set-pr-ref.sh <task-id> <pr-url-or-shortform>` | Append `(<repo>#<num>)` to the task's issue title (which the board inherits) so the task→PR mapping is visible at a glance. Idempotent. | 1 walk + 1 mutation |
| `pr_task_id.sh <pr-number>` | Echo the task ID for a PR (branch name → body `Task:` link → commit-message fallback) or empty. No mutations. | 1-3 `gh pr view` calls |

All `source` `_lib.sh` for shared GraphQL plumbing and identity helpers.

## Configuration

Env vars consumed by `_lib.sh` (all optional except auth):

| Variable | Default | Purpose |
|----------|---------|---------|
| `PROJECT_OWNER` | *(none — required)* | Org login owning the Project V2 board. No adopting-team default is baked in; set via `~/.claude/.env`. Unset means the Project-board mirror is a no-op — the task file's `status:` frontmatter stays the source of truth. |
| `PROJECT_NUMBER` | *(none — required)* | Project V2 number. Same resolution/degrade as `PROJECT_OWNER` above. |
| `SESSION_TOKEN` / `PROJECT_PAT` / `GH_TOKEN` | (one required) | Token with org-level `Projects: Read and write` |
| `CLAUDE_CODE_SESSION_ID` | (runtime-provided) | Falls back to `~/.claude/state/session-id` if unset |

## Failure mode

Every Project-mirror operation is best-effort:

- Token missing → log + continue (caller doesn't see an error)
- Network failure → log + continue
- Project item not found for the task ID → log + continue

This is **soft visualization**, not hard coordination. A Status mirror that didn't get written is a visualization gap, not a correctness gap.

The actual coordination invariant is the on-main **task-claim lock** (`task_claim.sh`, below) — durable, projected onto the board by `sync-tasks`.

## PR ownership: derived from the task claim

PR ownership is **not tracked separately** (T20260622-404636). A PR is owned by whoever owns the **task it implements** — that task's `claimed_by: <machine>:<clone-path>` on `main` (the lock below). There is no PR-resident marker. `task_claim.sh pr-owner <pr>` resolves PR → task → `claimed_by` and answers "may I drive this PR?":

| Output | Meaning |
|--------|---------|
| `mine` | this `<host>:<path>` agent holds the PR's task — proceed |
| `free` | the task is unclaimed — proceed |
| `untracked` | the PR maps to no task (`fix/*` branch, no `Task:` link) — no cross-session task to coordinate on, proceed |
| `owned:<by>` | a **different** agent holds the task — defer; do not drive or merge |
| `unknown` | the task file couldn't be resolved (network / not found) — **fail-safe: defer**, never a silent merge |

Resolution reads the **authoritative `main` value** over the GitHub API (`contents?ref=main`), so it works cross-repo (the task lives in the hub repo; the PR may be in a target repo, located via the PR body's `Task:` link) and never trusts a possibly-edited branch copy.

**Why this replaced the old `cc-owned` marker.** The retired `pr_owner.sh` kept a PR-resident `cc-owned` label + hidden marker comment per *session*. When the owning session died holding it (crash / kill / reboot), the marker stranded a green, merge-ready PR and blocked every other session until a human cleared it by hand — recurring on #1361/#1326/#1386/#1524. The "obvious" fix (detect the dead owner and take over) needs a reliable per-session liveness probe, which **is not feasible on stable signals** (an idle session keeps its `CLAUDE_CODE_SESSION_ID` in no persistent process; see the T20260622-404636 JOURNAL). Deriving ownership from the task removes the second ownership state entirely, so there is nothing to strand:

- **One ownership concept, on `main`.** The task claim is durable, GitHub-persisted, and atomically arbitrated by the merge — the same lock `/drive` Phase 1 already takes.
- **A dead owner's claim self-clears.** Same `<host>:<path>` agent: its next pickup runs `release-others` (release-on-pickup) and frees the stale claim. Foreign dead agent: the [reclaim sweep](#reclaiming-dead-claims) frees it once the claim is stale (open PRs are reclaimed by **PR-activity** staleness, not main-branch commits — T20260622-404636).
- **No heartbeat, no explicit PR release.** Ownership is set at task-claim time and released at task close (`task_claim.sh release`); `/address-pr` only *reads* it.

**Caveat (load-bearing):** because the agent identity is `<host>:<path>`, two sessions sharing a clone are indistinguishable. The cron-vs-human anti-steal (the failure mode the old per-session marker guarded) now rests on the **one-session-per-clone** convention — cron, interactive, and `/tmp` cross-repo clones are distinct paths. Keep them distinct.

## Integration points

| Skill | Phase | Call |
|-------|-------|------|
| `/drive` | Phase 1 (after picking task) | `status.sh <task_id> Design` |
| `/drive` | Phase 6 (park as blocked) | `status.sh <task_id> Blocked` |
| `/drive` | Phase 7 (close) | `status.sh <task_id> Done` |
| `/gcpr` | Step 6.6 (after `gh pr create`) | `pr_task_id.sh` → `set-pr-ref.sh <task_id> <pr-url>` |
| `/address-pr` | Start (after PR identified via `pr_task_id.sh`) | `status.sh <task_id> Review` + `set-pr-ref.sh <task_id> <pr-url>` |
| `/address-pr` | End (post-merge) | `status.sh <task_id> Done` |
| `/ccxp` | Phase 2a.3 (design pass produces Design section) | `status.sh <task_id> Design` |
| `/address-pr` | §1.6 (start, before any PR work) | `task_claim.sh pr-owner <pr>` → `mine`/`free`/`untracked` proceed; `owned:*`/`unknown` defer |
| `/drive` | Phase 1 (claim PR, peer mode) | `task_claim.sh read\|reclaimable\|release-others\|acquire <id>` (release-others before acquire = release-on-pickup); Phase 7 `task_claim.sh release <id> <status>` |
| `/ccxp` | Phase 0 tick | `reclaim_sweep.sh --apply` → free foreign dead-agent claims (incl. abandoned open-PR tasks) |

## Task-claim lock (`task_claim.sh`) — on-main, authoritative

The durable "who owns this task" lock. Unlike the Project-board mirror above, it does NOT live on the board: it lives in the task file's `claimed_by: <machine>:<working-dir>` frontmatter, and the **merge-to-`main` arbitrates it atomically** — two sessions racing for the same task collide on the `claimed_by:` line, and the loser's claim PR fails to merge. The `sync-tasks` workflow projects this on-main state onto the Project board (an opaque TEXT field — format-agnostic), so the board reflects the real claim without any board-side write.

**Claimant identity = `<machine>:<working-dir>`** (e.g. `build-host:/home/ci/focus/some-repo`), the (host, clone-path) pair — **not** a per-invocation session id (`T20260615-169917` retired the old `<sid>@<machine>`). It is stable across CC invocations in the same clone (one clone = one session), so a new `/drive`/ccxp run is the *same* claimant and supersedes its own prior claim instead of stacking. Legacy `<sid>@<machine>` claims still parse and defer (never stolen); they age out via the reclaim sweep / `release`. This same identity now also defines **PR ownership** (a PR is owned by the agent holding its task — T20260622-404636); `session_cc_session_id` survives in `_lib.sh` only as a generic per-host helper, used by neither lock.

**Convention: claim before flipping status.** Any path that moves a task's `status:` out of `Open` — `/drive`'s Phase 1, `/ccxp`'s Phase 2a.3 design pass, or a session acting on a direct maintainer prompt outside either — should call `task_claim.sh acquire` (with `release-others` first, for release-on-pickup) before or alongside the status change. `status.sh` alone is visualization-only and takes no lock (T20260610-248248); a status flip with no claim is invisible to a peer session's `/todo next` and can race. `_session/claim_gap.sh` (below) detects the gap when this convention is missed.

Verbs (`task_claim.sh <verb> <id> [...]`): `read` (echo current `claimed_by`), `claimant-id` (this session's id), `pr-owner <pr>` (derive PR ownership from the PR's task — see [PR ownership](#pr-ownership-derived-from-the-task-claim)), `reclaimable <id>` (is the claim stale — see below), `acquire <id>` (write `claimed_by` / `status: Coding`), `release <id> <final-status>` (clear the lock on close), `release-others [except-id]` (**release-on-pickup** — clear *every* task held by this identity so a session holds ≤1 active claim; the pick step calls this before `acquire`, keeping the optional about-to-be-acquired `except-id`). Pure logic is unit-tested in `tests/task_claim.bats`. See `/drive` Phase 1 ("Peer mode — cross-session claim lock") for the full claim-PR flow.

### Reclaiming dead claims

A claim whose owning agent died (crash / kill / reboot) is freed two ways. **Same `<host>:<path>` agent:** its next pickup runs `release-others` and drops the stale claim (instant; the common case — the cron/clone restarts regularly). **Foreign dead agent:** `reclaim_sweep.sh --apply` (a `/ccxp` Phase-0 tick) frees it once `reclaimable` reports the claim stale. `reclaimable` is **git/PR-activity** liveness, not a process probe (verified-dead PID detection isn't feasible on stable signals — T20260622-404636):

- a **no-PR** task is stale when the last commit mentioning it on `main` is older than the window (`TASK_CLAIM_STALE_DAYS`, default 2);
- an **open-PR** task is stale when the PR's last activity (`updatedAt` — push / comment / review) is older than the window. Open PRs are **no longer** auto-excluded from reclaim (the old rule leaked dead-owner open-PR tasks forever — T20260622-404636), but an actively-driven PR still reads `live`.

The sweep never frees this session's own claim (self-guard), and a reclaim is never silent (each freed task is logged + Slacked).

### Detecting never-claimed active tasks (`claim_gap.sh`)

The complementary gap (T20260610-248248): a task whose `status:` is `Coding`
but whose `claimed_by` was never set — the failure mode when some path flips
status via `status.sh` alone, without ever calling `task_claim.sh acquire`.
`_session/claim_gap.sh` enumerates `Coding`-status task files and flags any
with an empty `claimed_by`, one line per gap. Detector only — it never
mutates a task file, unlike `reclaim_sweep.sh --apply`.

**`Design`/`Review` + empty `claimed_by` is deliberately NOT flagged**
(corrected T20260809-310724, 2026-08-09): that's the normal resting state of
an unclaimed backlog design/review — `/todo next`'s peer-claim filter only
skips a task on a *non-empty* `claimed_by`, so nothing is invisible to
claim-based coordination there. Verified live: most of a previously-flagged
`Design`-status set had simply never been claimed at all.

`claim_gap_changed` (the entry point `_session/claim_gap.sh` dispatches to
directly) additionally dedups: it remembers the last-posted gap list's hash
in `.claude/state/claim-gap-last.json` and stays silent on a repeat call with
an unchanged list, so a caller that Slacks non-empty stdout won't re-post the
same finding every tick. Run once per `/ccxp` Phase-0 tick alongside the
reclaim sweep; see `ccxp/SKILL.md`'s Phase-0 tick section.

## Unified state query (`task-state.sh`)

`task-state.sh <task-id> [--json]` answers "what's the status of T\<id\>" in ONE call — task-file
`status:`/`claimed_by:`, any matching remote branch, referencing PRs (`gh pr list --search`), and
one line of status for each directly-referenced blocker/related id (no recursion beyond that
level — same discipline `/stage`/`/top` use for transitive chains). It is read-only: no
frontmatter writes, no board mutation, no claim interaction. Built to close a concrete gap
(T20260719-204917): repeatedly re-deriving this by hand — separately grepping the task file,
`git branch -r`, and `gh pr view` — while driving a task and its blocker chain.

It resolves the task file via `_taskid/url.sh`'s `taskid-path` (TODO > PARKING > JOURNAL glob) and
falls back to `_taskid/in-this-repo.sh`'s cross-repo/closed-here banner when the id isn't in this
clone at all — the same primitives `/stage`/`/top`/`/drive` already use, not a parallel resolver.
Its frontmatter reader is a small intentional copy of `task_claim.sh`'s `_tc_fm_get` (which is
underscore-private to that script), following the same precedent as `attribution.sh`'s own copy.

## What this does NOT do

Explicitly out of scope for the **Project-board mirror** — note these limits are exactly why the on-main `task_claim.sh` lock (which also backs PR ownership) exists:

- **No `/todo next` ranking impact** — the board mirror itself doesn't gate task picking; the on-main `task_claim.sh` lock does
- **No hard locking (board mirror)** — the Status / PR-ref writes never block. Both task-level claiming **and** PR ownership (derived from it) live in `task_claim.sh`.
- **No dependency surfacing via the board** — `Blocked by T<id>` stays frontmatter-only
- **No same-clone race protection** — covered by the existing one-session-per-clone convention, not this lib (and now load-bearing for PR ownership too — see the PR-ownership caveat)

## Cross-references

- ccxp-skills#48 — `_claims/` retirement (the over-engineered ancestor of the retired soft layer)
- T20260616-308030 — retirement of the soft session-visualization layer (claim/heartbeat/read/release/prune + the 4 Project fields)
- hub-repo#91 / build-pipeline-repo#748 — Tasks-as-Issues mirror (the workflow that creates the Project items this lib writes to)
- build-pipeline-repo `T20260611-104067` — peer-mode parallel dev that the on-main `task_claim.sh` lock arbitrates
