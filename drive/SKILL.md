---
name: drive
description: Use when the user explicitly asks to work a single task end-to-end — implement, PR, merge, recursing into blockers; never switch laterally to unrelated work
disable-model-invocation: false
argument-hint: "[task-id]"
---

Single-task work loop: pick ONE task (or accept one from the user), implement it, create a PR, babysit through CI and Copilot review, merge, done. If the task becomes blocked by **another task** (a dependency), recurse INTO that blocker and drive IT to done, then pop back up and resume. Never switch laterally to an unrelated task — that's `/ccxp`'s job.

**Invariant**: one invocation of `/drive` owns one goal-task and follows its chain of blockers. It exits when the goal-task is merged (or permanently blocked by an external dependency with no actionable sub-task).

## Argument

`<arg>` is optional:

- `/drive` — auto-pick using `/todo next` scoring
- `/drive T254701` — work on a specific task
- `--dispatch-blockers` (combinable with either form above) — at Phase 6 step 3, drive each
  blocker via a fresh dispatched sub-agent instead of inline in this conversation. See Phase 6
  step 3 for the mechanics. **Opt-in only** — omitting this flag keeps the default, fully-inline
  behavior unchanged (T20260719-204917).

## Workflow

### Phase 0: Drain open PRs first

Before picking new work, make one forward move on the PR backlog by handing off to `/address-pr`:

Call `/address-pr` with no args once. It auto-picks the first open PR authored by us that isn't deferred by ownership (§1's `auto-pick.sh`, oldest-first, walking past any `owned:<other>`/`unknown` candidate instead of stopping at the single oldest — T20260919-266165), reads that PR's ownership (§1.6 — *derived* from the implementing task's `claimed_by` on `main`), runs the hard merge gate, and then either merges, addresses-and-loops, or exits with a non-actionable status (nothing pickable at all). After it returns, proceed to Phase 1.

- **0 open PRs** → `/address-pr` reports "No open PRs to address" and exits; proceed to Phase 1 normally.
- **Multiple actionable PRs** → only the oldest is driven this session; the rest wait for the next session's Phase 0. `/drive` Phase 0's job is to make ONE forward move on the PR backlog before picking new work, not to drain all of it — this matches the single-goal-task principle the rest of the skill follows.
- **PRs owned by another session, or blocked on CI / external review / approval / pipeline** → `/address-pr` defers, fixes, or exits without an unsafe merge as appropriate. The §1.6 ownership guard (the anti-steal protection against a concurrent-session-drives-the-same-PR failure mode — a PR lives on GitHub, reachable from every clone, so nothing local stops two sessions from driving it at once without an explicit lock) and the hard merge gate live inside `/address-pr`, so no separate per-PR pre-classification is needed here.
- **PR's task is unclaimed (`free`)** → `/address-pr` §1.6 now claims the task itself (same mechanism as this skill's Phase 1 Claim PR) before driving the PR further — don't just proceed against an unclaimed task (an unclaimed task's PR can sit open, unnoticed, for weeks before this gets caught).

**Skip Phase 0 when:** the user gave an explicit task ID (`/drive T254701`) — they want that specific task worked on, not a PR sweep.

### Phase 0.5: Check escalation replies

Before picking new work, check if prior escalations have received replies:

1. Run `/slack-check-reply all`
2. For each thread with replies:
   - Parse the most recent reply for a directive (e.g., "go with A", "skip", "merge it")
   - Mark the thread as `resolved: true` in `.claude/state/drive-threads.json`
3. If a reply unblocks a previously stopped task, that task gets priority in Phase 1
4. If no pending escalations or no replies, proceed normally

### Phase 1: Pick task

If no task ID given (auto-pick):

1. **Run `/todo sweep` first.** Auto-pick reads `queue.md`'s order via `/todo next`, and `sweep` is the only workflow that keeps `queue.md` in sync with `dev/TODO/` (adds untracked files, strikes closed/parked entries, fixes stale blockers, re-orders on blocker violations). Skipping it risks picking a stale queue entry (a task already closed by another session) or missing blocker-ordering fixes that would have changed the #1 slot. Run it every auto-pick, not just periodically — it's idempotent and a no-op when nothing has drifted.
2. Run `/todo next` logic — read all `dev/TODO/*.md`, build dependency graph, score by readiness + priority + unblocks
3. Select the #1 recommendation
4. Flip the task file's Status `Open` → `Design` (in-place). **Peer mode is on by default** (disable with `CCXP_PEER_MODE=0`), so cross-session collisions ARE possible (ccxp + interactive sessions run as parallel peers) — see the peer-mode claim block in "Claim PR" below before picking. (With `CCXP_PEER_MODE=0`, the old one-session-per-clone assumption applies — no separate claim registry, no collisions to detect.)
5. Report the pick to the user: task ID, title, current status, what "done" looks like.

If task ID given:

1. Read the task file
2. Verify it's not Blocked or Done
3. Flip the task file's Status to the appropriate next state (Open → Design, Design → In Progress, etc.) in-place

**Clone-locality guard (run right after the id is resolved, before any status/claim write — T20260626-298293):**

A task's claim, journal, and file all live in ONE repo. Working a task from a *different* clone takes the claim against the wrong `dev/` tree and leaves the clone-scoped status line blind to it. Before flipping status, assert the task file is actually in this clone:

```bash
bash ../_taskid/in-this-repo.sh <task-id>   # exit 0 = here; non-zero = closed/cross-repo (prints where to look)
```

- **Exit 0** — present in this repo's `dev/TODO`/`dev/PARKING`; proceed.
- **Non-zero, warn-only (default)** — a loud banner naming the current repo + (best-effort) the sibling clone that has it. Deliberate cross-clone work via absolute paths is legitimate, so this does **not** stop you — but `cd` to the named clone unless you mean to work cross-clone.
- **`DRIVE_STRICT_CLONE=1`** — hard-refuse on a cross-repo id (for unattended ccxp loops that must never pick a task they can't fully own from their own clone).

(Auto-pick via `/todo next` only surfaces tasks already in this clone, so the guard is a no-op there; it's the explicit-id path that needs it.)

**Status mirror** (best-effort, never blocks):

After picking the task and updating its frontmatter `status:`, mirror that stage to the Project board so the team can see what stage the task is in:

```bash
# Frontmatter status → Project Status single-select (e.g. Open → Design)
bash ../_session/status.sh <task-id> <Design|In Progress>
```

This call is pure visualization — nothing depends on the write succeeding, and other sessions won't be blocked from picking the same task. See `_session/README.md` for the design. If it fails (missing PAT, network, etc.), it logs to stderr and exits 0 — continue with the task. The frontmatter `status:` field in the task file remains the source of truth; the Project Status field just mirrors it for the board view.

**Claim PR — land the status change on `main` before working (maintainer ask 2026-06-10):**

The in-place status flip above and the `status.sh` board mirror are **not durable**. The flip lives only on the working tree until some later PR carries it to `main`, and the mirror is best-effort — it is lost on a PAT/network failure, and the next `sync-tasks-to-issues` run (which reads from `main`, where the file still says `Open`) overwrites the board back to Open. So a session can be deep in implementation while `main` — and the GitHub Issue the board is driven from — still shows the task **Open / unclaimed**.

Close that gap by landing a tiny **claim PR as the very first thing**, before any design or implementation work:

1. Branch `t<id>-claim` off `main`.
2. Edit **only** the task file's `status:` frontmatter line: `Open` → `In Progress` (or `Open` → `Design` when a design PR will follow in Phase 2). A short prose note is fine (`claimed YYYY-MM-DD`). Change nothing else — keep it a **pure status-change** so it auto-merges under the carve-out in `dev/branch-merge-policy.md`.
3. Commit, push, `gh pr create`, then run `/address-pr` on it. It auto-merges on the pure-status-change tier once CI is green (no manual approval needed). (No doc-lint guard here — the claim PR is a pure frontmatter `status:`/`claimed_by:` change and cannot trip MD032, a body-list rule; the guard runs on the body-doc paths — Phase 4 via `/gcpr` Step 1.5 and the Phase 7 journal-move. T20260627-192311.)
4. After it merges, `git checkout main && git pull && git remote prune origin` (see **Important Notes → Post-merge branch hygiene**), then continue to Phase 2/3 on a fresh implementation branch.

This makes "somebody is working on T<id>" true **on `main`** at claim time — durable, and visible to every other session and the Project board — instead of only after the implementation PR lands, for the price of one fast docs-only PR. **Same-repo / hub-side only**: the claim PR touches the hub task file; in cross-repo mode it still lands in the hub repo and is independent of the Phase 1.5 target clone.

**Peer mode — cross-session claim lock (default; `CCXP_PEER_MODE=0` to disable):** Peer mode is **on by default** — ccxp and interactive sessions run as parallel peers (even sharing GitHub state), so the one-session-per-clone assumption no longer holds and the claim PR becomes the **cross-machine lock**, not just a status flip. (Default-on means *every* session claims — no env-var-symmetry gap.) The lock lives in a single frontmatter field the merge-to-`main` arbitrates atomically: `claimed_by: cc1-<machine-id>:<path-hash>` (the canonical single-line conflict point — a clone-stable identity that already carries the working-dir, so a new invocation in the same clone is the *same* claimant). Use `_session/task_claim.sh` instead of a bare `status:` flip:

1. **Before picking, confirm the task is free:** `bash ../_session/task_claim.sh read <id>` → if `claimed_by` is non-empty and is **not** this session's id (`task_claim.sh claimant-id`), the task is held by another session — **do not pick it**. Check `task_claim.sh reclaimable <id>` (a stale claim — no open PR, no commits in N days — may be reclaimed); otherwise go back to `/todo next` for a different task.

   **Also confirm it is not lint-frozen (T20260629-185057):** `bash ../_session/lint_frozen.sh is-frozen <task-file>` (exit 0 = frozen). A frozen task's claim PR **cannot merge** — the changed-mode `Lint task frontmatter` check re-validates the *whole* file and fails on a pre-existing non-allowlisted field / non-bucket `estimation` (the [T20260626-353630] schema-fork class). If frozen, do **not** open an un-mergeable claim PR (a real observed case wasted a full claim cycle this way): report the freeze reason and re-pick via `/todo next` — or, for an explicit `<id>`, exit with the reason. `/todo next` already excludes frozen candidates (step 4); this is the **backstop for the explicit-id path** that bypasses it. Fail-safe is inverted vs the IPM drain gate — an unclassifiable probe ⇒ **claimable** (never hide pickable work).
2. **Release any prior claim, then `acquire`** (release-on-pickup — keeps ≤1 active claim per clone): on the `t<id>-claim` branch, **first** run `bash ../_session/task_claim.sh release-others <id>` to free any task this clone still holds from an earlier pickup (it keeps `<id>`, the one you're about to claim). This is what stops a live session's claims from accumulating on `main` until `/todo next` finds nothing pickable. **Then** `bash ../_session/task_claim.sh acquire <id>` — it sets `claimed_by` and `status: In Progress`. Commit the result: the claim on `<id>` **plus** any `release-others` edits to *other* task files all land in this same claim PR (still docs-only, auto-merge-eligible). The released tasks return to the pickable pool (`In Progress`/`Design` → `Open`; `Blocked by`/`Review`/terminal statuses are preserved).
3. **Claim-PR conflict = you lost the race.** If the claim PR cannot merge because of a conflict on the `claimed_by:` line, another session acquired the same task in the same window. Do **not** force it — `git checkout main && git pull && git remote prune origin`, then re-pick via `/todo next`. **The merge conflict IS the lock rejecting your acquire.**
4. **Release on close.** In Phase 7 (task done/parked), `bash ../_session/task_claim.sh release <id> <final-status>` clears `claimed_by` as part of the journal-move/close PR.

With **`CCXP_PEER_MODE=0`** (the opt-out), the claim PR flips only `status:` exactly as described above — no lock, no `task_claim.sh` — for repos/sessions that don't want cross-session claiming.

**Solo-repo mode (no CI, direct-to-`main`):** a repo whose own `dev/guidelines.md`/`CLAUDE.md` Branch and Merge Policy declares itself solo/no-CI (direct-to-`main`, no feature-branch PRs) has no CI to gate the claim PR and no peer session to race — but still wants the two signals a branch + durable claim give: the statusline (`statusline-setup/scripts/statusline-command.sh`) shows the live `branch:` (so staying on `main` the whole task shows nothing useful) and `TASK:` (from whichever `dev/TODO/*.md` has `claimed_by:` set to this clone, which requires the claim to actually land as its own commit rather than being collapsed straight into a later close). Replace steps 1–3 above with: branch `t<id>-<slug>`, `release-others` + `acquire`, commit, `git checkout main && git merge --ff-only t<id>-<slug> && git push` to land the claim immediately, then `git checkout t<id>-<slug>` back and stay there for all of Phase 2/3's work (never commit to `main` directly mid-task). At Phase 7 close: `task_claim.sh release`, commit, merge `--ff-only` back to `main`, push, delete the branch. Full recipe: `/claim` skill's own "Solo-repo mode" section (kept in sync with this one).

Interaction with the Phase 2 design PR:

- **Design PR will run** → claim PR flips `Open` → `Design` first (design-writing can take a while; don't leave the board Open meanwhile), then Phase 2 carries the design *content*.
- **Design PR is skipped** (self-evident fix / in-conversation-approved — see Phase 2 "When to skip") → the claim PR is the **only** thing that lands the status before the implementation PR, so it is **required** in that path; flip `Open` → `In Progress`.

### Phase 1.5: Cross-repo dispatch (optional)

If the task file frontmatter has `Target repo` set, the implementation lives in a DIFFERENT repo from the task file. The **hub repo** is where the task file lives (`dev/TODO/` / `dev/JOURNAL/`); the **target repo** is where the code change lands. Typical shape:

```
- **Target repo**: your-org/example-website.com
```

If `Target repo` is unset **and** the change genuinely lands in this hub repo: **same-repo mode** — everything happens in the hub repo, skip the rest of this phase.

> **Undeclared cross-repo (common — T20260629-332546).** A task can be cross-repo *in practice* without a `Target repo:` line: that key is **not** on the `lint_tasks.py` allowlist (T20260626-353630), so stamping it would trip the changed-mode frontmatter lint (it re-checks the whole file, failing on the pre-existing non-allowlisted key). A skill/spec change whose code lands in `your-org/ccxp-skills` (it edits a `*/SKILL.md`), a website change in `example-website.com`, etc., is cross-repo even with no marker. **Treat a task as cross-repo when *either* `Target repo:` is set *or* you can see the implementation lands in another repo.** Set `TARGET_REPO` to the declared value or the one you recognize; the resume guard and pointer-recording below apply in both cases.

**Phase 1.5.0 — cross-repo existing-work guard (run BEFORE cloning/implementing — T20260629-332546).** `/drive`'s hub-side resume check (`git branch -r | grep <id>`, Phase 6) is **blind** to a cross-repo task's work: the work branches + PRs live in the *target* repo, and the hub task file's `status:` stays at its pre-implementation value (the cross-repo impl PR never flips the hub status to `Review`). So an unattended loop re-picks the same cross-repo task each tick, finds "no existing work" in the hub, and re-implements — opening a **duplicate** target PR every time (an observed run produced three convergent implementations across multiple open PRs for a single task, one of them broken despite green CI and nearly merged). Before you clone or write any code, query the **target** repo for existing work:

```bash
bash ../_gh/gh.sh pr list --repo "$TARGET_REPO" --search "<task-id>" --state all \
  --json number,state,title,headRefName,url --jq '.[]'
```

- **An OPEN PR matches** → do **not** re-implement. Check out its `headRefName` (clone the target repo at that branch), verify it against the design + test plan, and drive it through Phase 5 (`/address-pr`) instead. This is exactly the move that dodged a 4th duplicate on T20260614-261293 (2026-06-29).
- **A recently-MERGED PR matches** *and the hub task is still in `dev/TODO/`* → the implementation already shipped; the task just never got closed in the hub. Skip Phase 3/4 and go straight to Phase 7 (the hub journal-move / close PR).
- **No match** → proceed to clone + implement below, and **record the pointer** (Phase 4 cross-repo step 5) so the *next* tick takes the cheap path instead of re-searching.

If set (declared) or recognized (undeclared), enable **cross-repo mode** by cloning the target repo into a fresh ephemeral path:

```bash
TARGET="/tmp/T<task-id>-<slug>-target"
rm -rf "$TARGET"          # idempotent: kill any leftover from a prior crashed run
git clone --depth=20 --recurse-submodules \
  "git@github.com:${TARGET_REPO}.git" "$TARGET"
trap 'rm -rf "$TARGET"' EXIT      # cleanup on any exit path, clean or aborted
```

That's it. No safety guards, no JIT-refresh logic. A fresh clone is clean, on `main`, with no concurrent ops by construction — the entire class of "respect another process's state" coordination disappears because there is no other process in our clone.

Track both paths for the remaining phases:

- **hub repo** (`$HUB`) — durable session cwd, where the task file lives.
- **target repo** (`$TARGET`) — ephemeral clone, lifetime = this task, deleted in Phase 7 close-up.

Phase split:

- Phase 2 (design updates to the task file) and Phase 7 (journal move + close-up) run in `$HUB`.
- Phase 3 (implement), Phase 4 (create PR), Phase 5 (`/address-pr`) run in `$TARGET` — `cd $TARGET` before any git or gh operation.

Branch naming in the target repo uses the same `t<task-id>-<slug>` pattern as single-repo mode — the hub task ID is the canonical reference.

**Frontmatter override** (rare). If the task file ALSO sets `Target path: <path>`, reuse that path instead of creating an ephemeral clone. Use this only when the user has an existing checkout with WIP that must not be re-cloned (e.g., a long-lived integration branch with unpushed work). The override skips the cleanup trap — the user owns the path's lifecycle.

**Why ephemeral**: parallel `/drive` sessions on the same target repo each get their own ephemeral clone, so the design has zero collision surface. Hub-side has no coordination either — the convention is one session per clone (see T20260513-422869). If you need parallel hub-side work, open a new hub clone. No cross-session state to maintain.

**Clone-cost mitigations** (defaults baked in above):

- `--depth=20`: enough history for any feature-branch work. `fetch --unshallow` if Phase 3 reveals a need for deeper history.
- `--recurse-submodules`: correct for repos with submodules. Skip with `SUBMODULES=0` env var if the user wants faster clones for repos without them.
- For very large repos (e.g. a large monorepo), the user can additionally pass `--filter=blob:none` via a `CLONE_EXTRA_FLAGS` env var; defaults stay simple.

**Orphan cleanup**: the `trap EXIT` covers normal completion + ctrl-c + most crashes. A weekly sweep (ccxp Phase 0 addition, optional) prunes `/tmp/T*-target/` older than 7 days as a backstop.

(History — see T20260513-403409 in `dev/JOURNAL/`. Previous design required 3 safety guards [worktree clean, no in-flight git op, branch=main] + JIT-refresh + degraded path to share an existing target clone with other processes. The ephemeral-clone model makes those unnecessary.)

### Phase 2: Design — write, raise design PR, get reviewed, merge

The design lives in the task file (`dev/TODO/T<id>-<slug>.md`). The first thing that lands is a **design PR** containing only the task-file changes — no implementation yet. This gives Copilot a chance to review the design and the maintainer a chance to revise it before any code is written.

1. Read the task file fully — understand problem, existing design, test plan.
2. If the task has no design section (or only a stub): research the codebase and write the design by filling out [`repo-conventions/templates/design-doc.md`](../repo-conventions/templates/design-doc.md). It is **kind-scaled** (reuse the Phase 3.0 docs/code classifier): every task gets the §Common sections — TLDR *(mandatory, scored — 3-5 skimmable bullets)*, Problem *with reproduction evidence*, Context, Solution *(or `Plan`/`Scope` — same section) with alternatives-rejected*, Test plan, Done criteria *each mapped to a test or `file:line`*, Closed, Skills invoked; code/bug tasks additionally get §Code-only — Root cause *with git archaeology* (introduced-in `<SHA>`, deliberate-vs-oversight) and a Repo file references table. Anchor every claim to a `file:line` / SHA / command output and label *verified* vs *assumed*. **Scale to the task** — a docs chore omits the code-only sections; the target is the right sections completed, not a line count. **One-pager discipline**: most tasks read top-to-bottom on one scrolled screen — a `15m`/`1h`/`2h` task earns a few bullets per section, only a `2d`+ or Critical/RCA task earns real length.
3. Update task status: `Open` → `Design`.
4. **Create the design PR** — branch `t<id>-design`, commit ONLY the task-file changes, push, open PR. PR body: 1-paragraph summary of the design + "Design-only PR — implementation lands in a follow-up after this merges." Run `/address-pr` on it (CI will be green for docs-only; Copilot reviews the design itself; maintainer reviews and approves).
5. **Wait for the design PR to merge.** This is a checkpoint — do NOT proceed to Phase 3 until the design PR is on `main`.
6. After merge: `git checkout main && git pull && git remote prune origin` (see **Important Notes → Post-merge branch hygiene**), flip the task file's status `Design` → `In Progress` (in a follow-up commit on the implementation branch — see Phase 3).
7. **Design-score gate (hard gate — Phase 2 → Phase 3, per T20260609-204303 D3).** Before any code, score the merged design deterministically:

   ```bash
   bash ../design-score/scripts/score.sh <task-file>
   ```

   Exit 0 (`score >= threshold`, default 70) ⇒ proceed to Phase 3.0. Exit 1 ⇒ the design is **not ready** — read the per-check breakdown, fix the gaps (missing §Common sections, anchor-less prose, unmapped done-criteria, placeholder text, missing alternatives-rejected) in a follow-up design commit, re-score, and only then proceed. **Kind-scaled** — `score.sh` auto-detects code-vs-docs (same classifier as Phase 3.0); pass `--kind code|docs` to override. This is a cheap deterministic counterpart to the Phase 3.6 completeness gate, run *up front* so design decay is caught before any code exists. (When the design PR is skipped — see below — run the gate against the on-`main` task file before coding all the same.)

**When to skip the design PR (rare):**

- The "design" is a one-line bug-fix that's self-evident from the failing test
- The task was filed with the design already in the file AND the maintainer has explicitly approved it in conversation ("yeah, file a new task and start"). In that case, log the in-conversation approval in the task file's status note and proceed — the task file itself is on `main` already, so the design is reviewable in-place.

If you skip, note `Design approved in-conversation YYYY-MM-DD` in the task file's status line so the audit trail is clear. **The Phase 1 claim PR is still required when the design PR is skipped** — it is the only thing that lands a non-`Open` status on `main` before the implementation PR, so the board doesn't read "unclaimed" while you code.

**Escalation**: If the design requires a decision between multiple approaches and the trade-offs are unclear, the design PR is the natural place for that — open it with both options described and let the maintainer pick in the PR review. Only fall back to Slack-escalation if the PR can't capture the question (e.g., requires secrets the maintainer would expose in a thread).

### Phase 3: Implement

#### Phase 3.0: Detect change kind (route TDD + verification)

Classify the change:

```bash
CHANGED=$(git diff --name-only main...HEAD 2>/dev/null || git status --porcelain | awk '{print $2}')
```

| Pattern | Classification |
|---|---|
| `dev/**`, `docs/**` (any depth) | docs |
| `*.md` at any depth (incl. `README.md`, `CLAUDE.md`, `SKILL.md`) | docs |
| `.github/ISSUE_TEMPLATE/**`, `.github/pull_request_template.md` | docs |
| Everything else (incl. `.github/workflows/*.yml`, `scripts/**/*.sh`, `**/*.bats`, `Makefile`, build configs) | code |

Aggregate: all docs → **docs**; any code → **code** (mixed treated as code — stricter wins).

- **code-class**: invoke `superpowers:test-driven-development` BEFORE step 1 below. The TDD skill owns red → green → refactor.
- **docs-class**: skip TDD; continue to step 1.
- **empty diff**: defer classification; re-run after the first commit.

#### Phase 3.1: Drive substantive code-class tasks as a sequential Workflow

For **code-class, non-trivial** tasks (per the Phase 3.0 classifier), execute the core work —
**design → implement → test → verify** — as a single **sequential** `Workflow` (the Workflow
tool): **one agent per stage, awaited in order, NO `parallel()` / no fan-out** (maintainer
decision 2026-06-13, T20260613-508663). Each stage hands its structured result to the next; the
final stage adversarially verifies the change before you open the PR.

This is what gives the headless `-p /ccxp` cron ultracode-style orchestration *without* ultracode
session-mode (which is unreachable for a slash-command `-p` prompt — verified 2026-06-13). The
Workflow tool is available in headless sessions, and authoring a Workflow from a skill is the
sanctioned mechanism for invoking it (the platform permits the Workflow tool when a skill's
instructions call for it). The surrounding lifecycle is unchanged — the Phase 2 design
checkpoint, Phase 3.5–3.7 gates, Phase 4 PR, and Phase 7 close-out still apply; the Workflow is
just *how you execute* the design+implement+test work for a substantive task.

**Cross-repo: before authoring/running the Workflow, `cd $TARGET` and confirm `pwd` matches
`$TARGET`** — the Workflow's agents inherit this cwd, so a wrong cwd makes them edit the wrong
clone (the failure that step 2 below warns about).

**Trivial-task guard — stay LINEAR (no Workflow), do the steps below directly, when ANY of:**

- docs-class (Phase 3.0) — prose / markdown / task-file / journal / SKILL.md changes;
- a one-line or self-evident fix (the kind that skips the Phase 2 design PR);
- status-only / claim / journal-move changes;
- a single-file change under ~20 lines with no test changes.

When a task is borderline, **stay linear** — the guard is deliberately conservative (a spurious
Workflow wastes tokens; a missed one just means a linear task ran linearly).

**Sequential template** (adapt the prompts to the task; keep it strictly sequential — never add
`parallel()`):

```js
export const meta = {
  name: 'drive-impl',
  description: 'Sequential design→implement→test→verify for one code-class task',
  phases: [{ title: 'Design' }, { title: 'Implement' }, { title: 'Test' }, { title: 'Verify' }],
}
// One agent per stage, awaited in order — sequential by construction. No parallel(), no fan-out.
phase('Design')
const design = await agent(
  `Task T<id>: <one-line goal>. Produce a concrete implementation design — files to change, the
   approach, and a test plan — anchored to file:line in the repo at the current working dir.`,
  { label: 'design', schema: { type: 'object', additionalProperties: false,
    properties: { files: { type: 'array', items: { type: 'string' } },
      approach: { type: 'string' }, testPlan: { type: 'array', items: { type: 'string' } } },
    required: ['files', 'approach', 'testPlan'] } })

phase('Implement')
const impl = await agent(
  `Implement this design by editing files in the current repo, following its guidelines.
   Design: ${JSON.stringify(design)}. Return the files changed and a short summary.`,
  { label: 'implement', schema: { type: 'object', additionalProperties: false,
    properties: { filesChanged: { type: 'array', items: { type: 'string' } },
      summary: { type: 'string' } }, required: ['filesChanged', 'summary'] } })

phase('Test')
const test = await agent(
  `Run the test plan for the change just made (${JSON.stringify(impl.filesChanged)}):
   ${JSON.stringify(design.testPlan)}. Run the repo's tests; report pass/fail with output.`,
  { label: 'test', schema: { type: 'object', additionalProperties: false,
    properties: { passed: { type: 'boolean' }, details: { type: 'string' } },
    required: ['passed', 'details'] } })

phase('Verify')
const verdict = await agent(
  `Adversarially verify the change is correct AND complete vs the task's done-criteria — try to
   find what's wrong or missing. Design: ${JSON.stringify(design)}; tests: ${JSON.stringify(test)}.
   Return real issues only (empty array if none).`,
  { label: 'verify', schema: { type: 'object', additionalProperties: false,
    properties: { ok: { type: 'boolean' }, issues: { type: 'array', items: { type: 'string' } } },
    required: ['ok', 'issues'] } })

return { design, impl, test, verdict }
```

After the Workflow returns: if **Test** failed or **Verify** returned issues, fix them (a direct
edit, or another sequential pass) before Phase 4. Review the actual diff yourself — the
implement stage ran as a subagent, so confirm the working-tree changes match the design.

**How this maps to the numbered steps below:** do steps 1–2 (read design, `cd`/cwd) *before* the
Workflow; the Implement/Test stages perform steps 3–5 (write code, write/run tests); then **you**
do step 6 onward *after* the Workflow returns (commit the agent-produced working tree, then the
Phase 3.5–3.7 gates and the Phase 4 PR). The linear (trivial-guard) path just runs steps 1–7
directly.

1. Read the design and test plan
2. **Cross-repo mode:** `cd $TARGET` before touching any code. All subsequent git operations run in the target repo. Never edit target-repo files while cwd is still `$HUB` — that silently creates untracked files in the wrong place.

   **cwd discipline**: Before *any* `git` or `gh pr` invocation in cross-repo mode, verify `pwd` literally matches the expected absolute path — `$TARGET` for implementation steps (Phase 3 + Phase 4), `$HUB` for the journal-move PR (Phase 7). The cost of one `pwd` check is trivial; the cost of committing to the wrong repo and force-pushing the "fix" is hours. If a session bounces between the ccxp-skills checkout, the target repo's `/tmp/cc-...` clone, and the hub-repo hub, expect to lose cwd at least once and assert defensively.

   For cross-repo target clones, **always clone fresh under `/tmp/cc-<repo>-<purpose>-$(date +%s)`** — never reuse another session's clone or the maintainer's working clone. The Tasks-as-Issues mirror workflow runs on every push, so a stray commit in someone else's clone has visible consequences. The ephemeral clone pattern is what `/drive` Phase 1.5 codifies; this is the operational reinforcement.
3. Write the code — follow `dev/guidelines.md` conventions (the target repo's guidelines take precedence when they differ)
4. Write tests if the test plan calls for them (scripts in `scripts/` must have BATS tests)
5. Run tests locally: `bats tests/` — fix any failures before proceeding
6. Commit on the feature branch
7. **Workflow verification** — if the change touches workflow files (`.github/workflows/*.yml`), build scripts, or manifests: **trigger the affected workflow on the feature branch and verify it passes before creating the PR**. Use `--ref <branch>` and `dry_run=true` / `skip_upload=true`. Wait for completion and confirm success.

   **Exception 1**: brand-new workflows that don't exist on `main` yet can't be triggered from a branch — note this in the PR and test immediately after merge.

   **Exception 2 (channel-noise carve-out)**: if the brand-new workflow's failure path notifies a public/team Slack channel AND the post-merge dispatch would predictably fail (missing source artifacts, unset prerequisites), **do NOT do the post-merge dispatch** — the failure alert is indistinguishable from a real incident. Trust BATS + actionlint + the first real invocation. See `dev/branch-merge-policy.md` for the full rule.

**Scope guard**: Track files changed. If implementation touches **more than 8 files** not mentioned in the design's "Files changed" table, **stop and escalate** (see Slack Escalation Protocol):

- Send: `*T{id}*: Scope check — implementation touching {N} files beyond design scope. Review before continuing.`
- Type: `scope-check`

**New dependency discovered**: If implementation reveals a blocker not in the task file — or ANY new issue worth tracking on its own (a regression your own fix caused, a latent bug you tripped over, anything with a "why does this exist" a future reader would ask) — file it **before** touching any code for it:

1. **Mint the ID and immediately create the task file** — `bash ../_taskid/new.sh --check ./dev` then write `dev/TODO/<id>-<slug>.md` from `repo-conventions/templates/task.md` in the same breath. **Do not reference the ID anywhere else — code comments, test names, commit messages — until the task file exists on disk.** An ID minted and used but never filed is an orphaned reference (`_taskid/check-orphaned-refs.sh` catches this in CI, but don't rely on the backstop over doing it in order — this rule exists because of a real observed incident, not a hypothetical one).
2. It's a **dependency**, so auto-stage it into the **current** iteration by stamping `scheduled:` after the file is written: `bash ../_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md current` (token-free: committed IPM → Project API → next-Monday fallback; update-forward-only)
3. **If you're about to fix it right now** (soft blocker, working around it inline): claim it first — `bash ../_session/task_claim.sh acquire <id>` on a claim-PR branch, same as any other task pickup (Phase 1) — *then* write the fix. Filed-but-unclaimed is fine when you're just noting it and moving on; claimed-and-being-worked-right-now without a claim on record is the gap this rule closes.
4. Escalate (see Slack Escalation Protocol):
   - Send: `*T{id}*: New blocker discovered — created T{new_id} ({title}). Continuing on T{id} if possible, otherwise stopping.`
   - Type: `blocker`
5. If the blocker is hard (can't proceed without it): stop
6. If the blocker is soft (can work around for now): note it and continue

#### Phase 3.5: If implementation gets stuck — invoke systematic-debugging

Triggers (any of): a test won't go green after 2 fix attempts; a behavior contradicts the design's stated invariant; a pipeline fails in a way the pre-merge check can't explain; you catch yourself "trying things" rather than forming hypotheses.

When triggered, invoke `superpowers:systematic-debugging` before continuing — it enforces hypothesis-driven debugging over trial-and-error. Soft trigger: invoke when the smell appears, not on every test failure.

#### Phase 3.6: Before declaring impl complete — invoke verification-before-completion

Before opening the PR (Phase 4), invoke `superpowers:verification-before-completion`. It challenges "I'm done" by surfacing un-tested assumptions, missed edge cases, and "it compiles, ships" thinking. Exit only when the skill says ready. For **docs**-class changes, verification is lighter (markdown parse + link check + frontmatter validity) but still gated — invoke the skill and let it scope to the change kind.

**Design-doc completeness gate** (cheap structural counterpart to the above): confirm the task file carries the [`repo-conventions/templates/design-doc.md`](../repo-conventions/templates/design-doc.md) §Common sections (plus §Code-only for code/bug tasks), and that **every `## Done criteria` item names the test or `file:line` that satisfies it**. A criterion you can't map to a verification is untested or vague — fix it before the PR, not at close.

#### Phase 3.7: Documentation revision — keep docs in lockstep with the change

Before opening the PR, run the doc-freshness check so a behaviour / structure / setup change ships with the docs that describe it (the gate that would have caught a stale `README`):

```bash
bash ../_docs/doc-impact.sh "${BASE_REF:-origin/main}"
```

It flags repo docs (`README*`, `CLAUDE.md`, `dev/guidelines.md`, `*/SKILL.md`, `docs/**`) that reference what you changed, or that a newly-added workflow / action / script implies. For each flag: **update the doc on this branch** so it lands in the *same* PR, or — if it's genuinely unaffected — note "reviewed, no change needed". Kind-scaled via the Phase 3.0 classifier; for a large doc surface, escalate to `/proof-read` on the touched docs.

- **Interactive (a human is driving):** soft gate — resolve every flag (update or acknowledge) before Phase 4.
- **Unattended (ccxp loop):** never block the loop — update what's clearly in scope, then for any remaining flags **file a follow-up doc-conformance task** (`bash ../_taskid/new.sh --check ./dev`) — a **follow-up**, so stage it into the **next** iteration by stamping `scheduled:` after the file is written: `bash ../_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md next` — and proceed. Drift becomes tracked backlog, not a silent miss.

Cross-repo: run this in `$TARGET` (the repo whose code changed); doc updates land in the target PR.

#### Phase 3.8: Quality probe — record + warn (code-class only, per T20260609-204303 D2)

**Code-class tasks only** (per the Phase 3.0 classifier — docs-class changes touch no measurable code; skip with a one-line note). Before opening the PR, measure quality on the task's **touched files** and append one record to the target repo's append-only scoreboard:

```bash
bash ../quality-probe/scripts/probe.sh \
  --task "T<id>" --range "${BASE_REF:-origin/main}...HEAD" \
  --repo-root "${TARGET:-.}" --design-score "<Phase 2 gate score, if known>"
```

- **Record + warn, never block.** The probe exits 0 even on a regression; a loud `WARNING: <metric> regressed` line is the signal, *not* a gate. This is the deliberate asymmetry with the Phase 2 design-score **hard** gate — the cheap deterministic check gates; the noisier trailing metrics observe-first until trusted (see [`quality-probe/SKILL.md`](../quality-probe/SKILL.md)).
- **The append ships in this PR.** The new `dev/quality/metrics.jsonl` line is staged in Phase 4 so the scoreboard is durable on `main` and `/retro` Phase 4d can read the trend. (First run in a repo creates the dir/file idempotently.)
- **`--design-score N`** — pass the Phase 2 design-score so the leading + trailing indicators share one record; omit when unknown (recorded `null`). A missing scanner records that field `null` + logs a skip — never an error.
- **Carry the summary forward.** Copy the probe's one-line summary into the task's close note / JOURNAL entry so the trend is human-readable, not only in the JSONL.
- **Cross-repo:** run in `$TARGET`; the scoreboard lives in the target repo and lands in the target PR (not the hub).

### Phase 4: Create PR

Use the `/gcpr` skill workflow:

**Same-repo mode:**

1. Group changes into logical commits
2. If this PR completes the task: flip the task file's frontmatter `status:` to `Done` via `bash ../_session/task_claim.sh release <id> Done` (clears `claimed_by` in the same step — do **not** hand-edit the `status:` line directly, or the claim silently survives the close; caught 2026-07-18 on T20260717-329670, where a hand-edit close needed a follow-up release PR), then do the journal move (`git mv dev/TODO/{id}.md dev/JOURNAL/{date}-{id}.md`, **before** writing the `## Closed (YYYY-MM-DD)` and "Skills invoked" blocks — see the order-of-operations guard in Phase 7.0) as part of the commits. Always immediate, every close (T20260914-422854) — retired the old in-place-only default that deferred the move to the Friday retro's batch journal-sweep (`/retro` Phase 2b), because that default made most of the week's just-closed tasks invisible to `/retro`'s own Phase 2 classification, which runs *before* Phase 2b's sweep in the same invocation.
3. Push to feature branch
4. Create PR with summary + test plan

**Cross-repo mode:**

1. `cd $TARGET` (should already be there from Phase 3) — commits, push, and PR all land in the target repo
2. **Do NOT move the task file to JOURNAL in this PR** — the task file lives in `$HUB` and this PR only touches `$TARGET`. The journal move happens in Phase 7 via a separate hub-repo PR
3. The PR body **must include** a link back to the task so reviewers can trace scope:

   ```
   Task: https://github.com/<hub-owner>/<hub-repo>/blob/main/dev/TODO/T<id>-<slug>.md
   ```

   Put this as the first line of the Summary section, before the bullets.
4. Push and create PR in the target repo
5. **Record the cross-repo pointer + flip the hub status (T20260629-332546)** — so the next tick's Phase-1.5.0 guard finds this PR by pointer instead of re-searching, and the board reads past-`Design`. The pointer recording closes the duplication window the moment the PR exists (don't defer it to Phase 7). On a short `t<id>-xrepo-pointer` branch **in `$HUB`** (a tiny docs PR — auto-merges as status-change tier):
   - Append a `## Cross-repo work` line to the hub task **body** (not frontmatter — a `target_pr:` frontmatter key would need a `lint_tasks.py` allowlist entry, coupling to the T20260626-353630 schema fork): `` - Implementation: <target-repo>#<pr-number> (`<headRefName>`) — opened <YYYY-MM-DD>. ``
   - Flip the hub task `status:` → `Review` (it was `In Progress` from the claim PR), and mirror it: `bash ../_session/status.sh <id> Review`.
   - **Lint-frozen fallback (T20260626-353630 class):** if the hub task file's pre-existing frontmatter trips the changed-mode `Lint task frontmatter` check (so even a body edit's whole-file lint fails), **skip the pointer edit** — the Phase-1.5.0 `gh pr list --search` guard already finds the PR with zero recorded state, so the safety net holds without an unmergeable edit.

### Phase 5: Address PR

Use `/address-pr <PR number>` — it handles CI, Copilot review, comment resolution, test plan verification, pipeline verification, and merge/notify per the tiered merge policy. Do not duplicate its logic here.

If a pipeline or build is triggered for verification (5+ min wait), **wait in the background** (Bash with `run_in_background` or Monitor). Do NOT pick up an unrelated task — `/drive` drives one goal. If there's nothing actionable *on the current chain*, idle until the background signal arrives.

### Phase 6: Encountering a blocker — recurse into it

When the current task (G, the goal) can't progress because it depends on another task (B, the blocker), do NOT switch laterally to an unrelated task. Chase B:

1. **Identify the blocker.** A blocker is another `T{id}` task referenced from G's file as a `Blocked by` / `Depends on` entry, or discovered mid-work (e.g., a failing CI is the symptom of an undiagnosed bug — file it as a new task, that's B). A newly-filed blocker is a **dependency** → auto-stage it into the **current** iteration (`bash ../_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md current`; see Important Notes).
2. **Park G minimally.** Commit and push any clean-state progress on G's branch. Leave G's branch in a pushable state. Record in G's task file: `Blocked by T{B} — resumed after B closes`. Do NOT mark G done. Mirror the block to the Project view:

   ```bash
   bash ../_session/status.sh <G-task-id> Blocked
   ```

   Best-effort; the local `Blocked by` line in the task file is the source of truth.

   **Checkpoint discipline (applies to ANY mid-task park, blocker or session-budget checkpoint):**
   - The task-file update recording the park (status + **the exact branch name** + what's done/what remains) must land **on main** (small docs PR — auto-merges as status-change tier). A progress note committed only to the work branch is invisible to every future session: main's task file still reads as un-started "In Progress", and the resuming session re-does the work on a fresh branch (observed incident: a feature was implemented twice on two branches because a park/resume didn't record which branch had the in-progress work).
   - **On resuming any `In Progress` task, FIRST look for existing work**: `git fetch -q && git branch -r | grep -i "t{id-digits}"` and read the task file's recorded branch pointer. Continue the newest matching branch — do not create a fresh one unless none exists or the existing one is explicitly recorded as abandoned. **If the task is cross-repo** (Target repo set, a `## Cross-repo work` pointer recorded, or the implementation lands in another repo — see Phase 1.5.0), this hub `git branch` grep is **blind** to the target-repo work: also run the Phase-1.5.0 guard (`bash ../_gh/gh.sh pr list --repo "$TARGET_REPO" --search "t{id-digits}" --state all`) and drive/verify any existing target PR instead of re-implementing (T20260629-332546).
   - Before exiting the session, return the clone to `main` (the cron wrapper executes from this working tree; a parked branch makes the wrapper itself go stale — see T20260605-862341 JOURNAL).
3. **Recurse into B.** Default (no flag) — invoke the `/drive` workflow on B **inline, in this
   same conversation**:
   - Flip B's Status to the appropriate next state.
   - Run Phase 2 → Phase 5 on B end-to-end.
   - If B itself is blocked by another task C, recurse again (same rules). Typical chain depth is 1-2; deeper is a smell — stop and slack.

   **`--dispatch-blockers` mode (opt-in — T20260719-204917, Factor 10 "small, focused
   agents").** Instead of recursing inline, dispatch B to a fresh sub-agent and only read back
   its compact result. Rationale: a fully-inline blocker chain (each blocker's own investigation,
   fixes, and PR loop) keeps growing the SAME conversation's context for work that is logically
   independent of the goal-task G — the exact pattern that ballooned this session's context
   driving T20260629-281129's blocker chain (T20260718-300856, T20260718-274226,
   T20260718-206307), each a substantial, self-contained investigation.

   - Dispatch via the `Agent` tool, `isolation: "worktree"` (B's `/drive` run will checkout
     branches and edit files — same reasoning as the cross-repo ephemeral-clone isolation in
     Phase 1.5, applied here to a same-repo worktree instead of a clone).
   - The prompt must be self-contained (the sub-agent has no memory of G or this conversation):
     state B's task ID, that the caller is `/drive` recursing from goal-task G (name G), and the
     ask — "drive B to merged (or to a permanently-blocked, escalation-worthy state) via `/drive
     T{B-id}`; report back: final status (merged / still blocked, and by what / escalated), the
     PR number(s) if any, and one paragraph of what changed."
   - Read back ONLY that compact report — do not pull the sub-agent's full transcript into this
     conversation. Record it in G's task file the same way an inline recursion would (`Blocked by
     T{B} — resumed after B closes`, updated once B's report lands).
   - If the sub-agent reports B is itself blocked by C: do not chase C from here. Either dispatch
     C the same way (a fresh, independent decision — this is not automatic multi-level fan-out)
     or fall back to the default inline path — same depth/escalation rules as the inline mode
     apply (chain depth ≥ 3 is still a smell; still escalate on circular blockers, missing
     secrets/permissions, or explicit urgency).
   - This mode is **additive**: it changes nothing about Phase 2-5 gates, merge policy, or claim
     mechanics — B is still claimed, designed, implemented, and merged under all the same rules,
     just by a different agent instance. Default (no flag) behavior is unchanged.
4. **Pop back up.** When B merges, `git checkout main && git pull && git remote prune origin` (see **Important Notes → Post-merge branch hygiene**), and resume G. Re-evaluate G's blocker list — maybe unblocking B cleared a cascade.
5. **Exit G when it merges** (same rules as a top-level task).

**Background waits are not blockers.** If G is waiting on its own pipeline run (5+ min), just wait — don't interpret that as a cue to grab a new task. The goal of `/drive` is depth, not throughput.

**When to escalate instead of recursing:**

- Circular blocker (G blocks B blocks G) — impossible state; slack.
- B requires secrets, permissions, or human decisions this session can't make — slack.
- Chain depth ≥ 3 — signal of task-graph rot; slack so the maintainer can re-scope.
- User invoked with an explicit task ID and expressed urgency — ask whether to recurse or notify.

### Phase 7: Post-merge

After merge (auto or approved):

#### Phase 7.0: Final verification + "Skills invoked" audit block

**Final verification.** Before declaring the goal-task done, invoke `superpowers:verification-before-completion` once more from the merged-on-main perspective. Common catches: a follow-up cross-repo PR still needed (the hub journal-move PR); a source GitHub issue not yet closed; a memory rule worth saving from this task's surprises; unchecked "Done when" items.

**Write the `## Closed (YYYY-MM-DD)` section** (standardized name — **not** "Resolution"/"Outcome"/"Done", so `/retro` and greps find it predictably) per [`repo-conventions/templates/design-doc.md`](../repo-conventions/templates/design-doc.md): shipped-in **PR #N** + run/evidence links, what's met, what's external/unverified and when it'll be confirmed, and any **follow-up tasks filed** (T-ids) — file each as a **follow-up** staged into the **next** iteration (`bash ../_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md next`; see Important Notes). Then —

**Append a "Skills invoked" block to the task body** before the close (Phase 4/Phase 7 `status: Done` flip or immediate journal move), so `/retro` Phase 4c can grade compliance by grepping JOURNAL:

```markdown
## Skills invoked

- TDD (`superpowers:test-driven-development`): {yes — Phase 3.0, code-class | no — docs-class}
- Verification (`superpowers:verification-before-completion`): yes — Phase 3.6 + 7.0 + /address-pr §2.a ×{N}
- Systematic debugging (`superpowers:systematic-debugging`): {yes — Phase 3.5 when X | no — didn't get stuck}
- Receiving code review (`superpowers:receiving-code-review`): {yes — /address-pr §2.d, {N} pushbacks | no — no Copilot comments}
```

Fill the bracketed alternatives from what actually happened; the block lands directly in the `dev/JOURNAL/` file at close time — every close journal-moves immediately (T20260914-422854), no deferred-to-Friday path anymore.

> **Order-of-operations guard (else the close content is silently dropped).** `git mv` stages the **HEAD blob** under the new path; any working-tree edits you made *before* the move stay **unstaged**, so a plain `git commit` lands a pure **100% rename, 0 insertions/0 deletions** — the `## Closed` section, `status: Done`, and checked boxes never reach the committed blob (a real observed case — caught only because the post-merge `git checkout main` aborted on a dirty tree). This bites **every close now** (the journal-move is the only path — T20260914-422854 retired the old deferred-to-Friday default that used to make this a rare case). Either **`git mv` FIRST, then edit at the new JOURNAL path**, or after editing run an explicit **`git add <journal-path>`** (or `git commit -a`). Then **verify before pushing**: `git show --stat HEAD` must show real insertions/deletions, not `100% rename` / `0 insertions(+), 0 deletions(-)`.

**Status=Done** (run right after Phase 7.0, before the remaining Phase 7 steps):

```bash
# Status mirror → Done (the file move to JOURNAL is the source of truth;
# this just keeps the board accurate without waiting for the mirror workflow)
bash ../_session/status.sh <task-id> Done
```

This call is best-effort, idempotent, and never blocks subsequent steps. If `/address-pr` already wrote `Status=Done` at merge time, the explicit call here is a no-op (same value).

**Same-repo mode:**

1. `git checkout main && git pull && git remote prune origin` (see **Important Notes → Post-merge branch hygiene**)
2. Verify the journal move (`dev/TODO/` → `dev/JOURNAL/`) landed in the PR from Phase 4, with `status: Done` set on the moved file — every close journal-moves immediately now (T20260914-422854), there is no in-place-only path left to check instead.
3. **Verify `claimed_by` was actually cleared, not just `status:` flipped.** If Phase 4's close commit set `status: Done` via a hand-edit rather than `task_claim.sh release <id> Done`, the claim can survive the flip (T20260717-329670, 2026-07-18 — the close PR flipped status but left `claimed_by` set, needing a follow-up release PR). Check: `grep claimed_by dev/TODO/T<id>-*.md`. If still set, open a one-line follow-up PR running `bash ../_session/task_claim.sh release <id> Done` — don't hand-edit the field directly; the script is what keeps `status:` and `claimed_by:` atomic.
4. If the task has `Source: GitHub issue #N`, update and close the issue:

   ```bash
   bash ../_gh/gh.sh issue reopen <N>
   bash ../_gh/gh.sh issue close <N> --comment "Fixed in PR #<pr-number>. See {task-id} for details." --reason completed
   ```

5. **If we recursed into this task as a blocker for a parent goal-task G**: pop back to G. Restore G's branch (`git checkout <g-branch>`), pull latest main, rebase if needed, update G's task file to clear the `Blocked by T{this}` line, and resume G from wherever it left off.
6. **If this IS the goal-task**: exit `/drive`. Report "T{id} done — PR #N merged." No next-task pick — `/drive` drives one goal.

**Cross-repo mode (additional steps):**

1. In `$TARGET`: pull latest main, confirm the merge landed.
2. `cd $HUB` and `git checkout main && git pull && git remote prune origin` (see **Important Notes → Post-merge branch hygiene**).
3. Open a **separate hub-repo PR** that closes the task — every close journal-moves immediately now (T20260914-422854, retired the old in-place-only default that deferred the move to the Friday retro's batch journal-sweep):

   ```bash
   git checkout -b t<id>-journal-move
   bash ../_session/task_claim.sh release <id> Done   # sets status: Done AND clears claimed_by atomically, before the move
   git mv dev/TODO/T<id>-<slug>.md dev/JOURNAL/$(date +%F)-T<id>-<slug>.md
   # Add a short "## Closed (YYYY-MM-DD)" section pointing at the target PR URL
   # (mv FIRST then edit, as above — else `git add` the JOURNAL path before committing)
   bash ../_docs/lint-docs.sh --fix "dev/JOURNAL/$(date +%F)-T<id>-<slug>.md" || true   # doc-lint guard, scoped to just this file (T20260910-919422) — shared script (T20260719-111051), see /gcpr Step 1.5 (T20260627-192311)
   git add dev/JOURNAL/$(date +%F)-T<id>-<slug>.md
   git commit -m "docs(tasks): close T<id> (shipped in <target-repo>#<pr-number>)"
   git show --stat HEAD   # must show insertions, NOT "100% rename / 0 insertions"
   bash ../_gh/gh.sh pr create ...
   ```

   This PR is docs-only, typically auto-mergeable (pure status-move — see the auto-merge carve-out in `dev/guidelines.md`), and closes the task lifecycle. Run `/address-pr` on it as usual.
4. Close the source GitHub issue (same as same-repo).
5. Pop back to parent goal if recursed; otherwise exit (same as same-repo).
6. **Remove the ephemeral target clone**: `rm -rf "$TARGET"`. The `trap EXIT` from Phase 1.5 also handles this on abort, but doing it explicitly at normal close-up keeps `/tmp/` tidy without waiting for shell exit. Skip this step if Phase 1.5 used the `Target path` override (the path is user-owned).

(Phase 7.5 parking-lot review removed — lateral housekeeping belongs in `/ccxp`, not `/drive`. `/drive` drives the current goal-task only.)

## Slack Escalation Protocol

**Decide-don't-wait gate (maintainer policy, 2026-06-06).** Before escalating, ask: *could I make a defensible call here and record it in the PR/task file for post-hoc review?* If yes — decide, act, note the decision and its rationale where the maintainer will see it, and keep pushing the committed IPM tasks. Escalate-and-WAIT is reserved for: (a) genuinely can't determine *what* to do or *how* to do it correctly, (b) design forks with real trade-offs the maintainer owns, (c) irreversible / outward-facing actions, (d) missing credentials/access. Everything else is decide-and-report. An escalation may still be *sent* for visibility on a decision made — but then continue working; don't park the task. (Context: 2026-06-06 — sessions were draining to `no_actionable_items` while decidable questions sat in Slack threads.)

When escalating to the user via Slack, use the MCP `slack_send_message` tool (not the `/slack` webhook) so that replies can be tracked.

### Sending

`DRIVE_ESCALATION_CHANNEL_ID` — the Slack channel_id escalations post to. Required, no baked-in default — resolved the same way as every other `~/.claude/.env`-backed var in this suite: already-exported wins, else `~/.claude/.env` (see `SLACK_STANDUP_CHANNEL` in `/slack-check-reply`).

If unset, do not let the `slack_send_message` call crash the `/drive` run and do not silently drop the escalation either: skip steps 1-2 below, log a clear `ERROR: DRIVE_ESCALATION_CHANNEL_ID not configured — cannot send escalation for T<id>` line, and record the escalation's message + type directly in the task file's status note in place of the `drive-threads.json` entry from step 3 — the escalation is surfaced in the task file, not lost. The triggering condition still governs whether `/drive` stops or continues (see Escalation Rules below); only the Slack transport degrades, an escalation mechanism is not something that gets skipped with a one-line note the way a read-only search does.

1. Use the `$DRIVE_ESCALATION_CHANNEL_ID` channel
2. Send via `slack_send_message` with `channel_id: "$DRIVE_ESCALATION_CHANNEL_ID"` and the message text
3. Save the thread reference to `.claude/state/drive-threads.json` (create dir/file if missing):

   ```json
   { "T304536": { "channel_id": "C...", "message_ts": "...", "type": "design-decision", "summary": "...", "sent_at": "...", "resolved": false } }
   ```

4. If a previous unresolved entry exists for the same task, mark it `resolved: true` first

### Checking replies

Use `/slack-check-reply <task-id>` or `/slack-check-reply all`. Phase 0.5 runs this automatically.

## Escalation Rules

**Stop and slack the user when:**

| Trigger | Action |
|---------|--------|
| Design decision with unclear trade-offs | Slack options, stop |
| Scope creep (>8 files beyond design) | Slack warning, stop |
| Hard blocker discovered | Create task, slack, stop |
| Test failures after 2 fix attempts | Slack with error details, stop |
| Build/CI failure not caused by our changes | Slack, stop |
| Task requires secrets/permissions not available | Slack, stop |

**Continue autonomously when:**

| Trigger | Action |
|---------|--------|
| Soft blocker (workaround exists) | Create task, note it, continue |
| Copilot style suggestion (not a bug) | Reply with justification, resolve, continue |
| Minor test fix needed | Fix, re-run, continue |
| Design is clear, implementation is straightforward | Code, test, PR, continue |

## Branch naming

Follow `dev/guidelines.md`:

- Tracked task: `t{task-id}-short-description` (e.g., `t254701-upstream-prepare`)
- Untracked: `fix/short-description` or `feat/short-description`

## Important Notes

- **Auto-stage every task you CREATE into an iteration** (maintainer policy 2026-06-18) — so it lands on the board's *Iterations* view, not just the backlog. After writing the task file, stamp its `scheduled:` frontmatter with `_ipm/stamp-scheduled.sh <task-file> <current|next>`, keyed by **kind**:
  - **Dependency / blocker** (Phase 3 "New dependency discovered", Phase 6 blocker discovered mid-work) → the **current** iteration: `bash ../_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md current` — it's needed to unblock the goal-task *now*.
  - **Follow-up** (Phase 3.7 doc-conformance task, Phase 7 close-time follow-ups) → the **next** iteration: `bash ../_ipm/stamp-scheduled.sh dev/TODO/<id>-<slug>.md next` — deferred work, not this iteration's commitment.

  The stamper resolves the Monday token-free (committed IPM file → Project API → next-Monday fallback) and writes it **update-forward-only**, printing the effective date. Token-free means it still stages correctly in the ccxp cron (no PAT) — unlike the old `_session/iteration.sh` inline call, which returned empty without a token and silently left the task unscheduled (T20260626-190842). It only no-ops on a non-YAML/legacy task file. `scheduled` is a lint-allowlisted key. (Closed tasks get their iteration automatically from the close-date via `sync-tasks` — see that action; this rule is only for *live* tasks at creation.)

- **Keep the task file current.** Update the task file in `dev/TODO/` after every phase transition, checklist item completion, pipeline result (pass or fail), or new issue discovered. The task file is the single source of truth for progress — if it's stale, the user can't tell what happened. Specifically:
  - Phase transition (Open → Design, In Progress → Review, etc.): update status line
  - Checklist item done: check it off with `[x]`
  - Pipeline/build finished: record run ID, result, and any errors
  - New blocker or issue found: add it as a new checklist item
- **Concurrency safety — hard rule.** Read-only operations (git log, gh pr view, file reads, API queries) may run in parallel. **Side-effecting operations (checkout, stash, edit, commit, push, branch switch) must run sequentially — never in parallel tool calls.** Before switching branches (e.g., recursing into a blocker), ensure the current branch has zero uncommitted changes and all pushes are complete. This applies across all phases: Phase 0 (one PR at a time), Phase 6 (clean state before recursing into a blocker), and background notification handling.
- **Post-merge branch hygiene (every merge, not just the final one).** After ANY `gh pr merge` in this flow — claim PR, design PR, implementation PR, close/release PR — do not just move on to the next branch: `git checkout main && git pull && git remote prune origin`. `--delete-branch` removes the branch on GitHub (and locally if you were on it), but your clone's cached remote-tracking ref (`refs/remotes/origin/<branch>`) lingers until pruned — Phase 6's existing-work check (`git branch -r | grep -i "t{id-digits}"`) can silently match a long-dead branch if this is skipped, and `main` can be several commits stale for the next branch you cut. (Observed incident: three merges landed back-to-back without a prune step; stale refs for all three lingered until caught and cleaned up manually.) Every "pull latest main" instruction elsewhere in this skill means this full three-part command, not just `git pull`.
- **Wait, don't switch.** If waiting for a long operation (5+ min) on the goal-task's chain, just wait (Bash `run_in_background` or Monitor). Do NOT grab an unrelated task. `/drive` depth > throughput.
- **Read guidelines first.** Always read `dev/guidelines.md` before making changes.
- **Read the task file fully** before starting — don't skip the design or test plan.
- **Don't update CLAUDE.md on feature branches** — only on main after merge.
- **Commit messages**: conventional commits (`fix:`, `feat:`, `docs:`, `refactor:`) with `Co-Authored-By` trailer.
- **Run tests before pushing** — `bats tests/` must pass. Don't push broken code.
- **Context budget**: if the task is too large for one session (>500 lines of new code, >10 files), break it into subtasks and implement the first one.

## Exit condition

`/drive` exits when the goal-task merges. No next-task auto-pick. Report:

```
T{goal-id} done — PR #N merged.
Chain depth: {N levels}  (e.g., goal → blocker → blocker's-blocker → merged)
Parked nothing. Ready for the next invocation.
```

Use `/ccxp` (lateral "pick next task" strategy) when you want continuous forward progress across the backlog. `/drive` owns depth; `/ccxp` owns breadth. Don't mix the two within one invocation.
