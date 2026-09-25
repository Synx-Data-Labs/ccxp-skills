---
name: claim
description: Use when the user explicitly asks to claim a task, check what this clone currently holds, or release a claim — for interactive work outside the full /drive loop
disable-model-invocation: false
argument-hint: "T<id> | release T<id> | status"
---

Land the durable, cross-session `claimed_by` lock (`_session/task_claim.sh`) on a
task as its own PR to `main` — the same "claim PR" `/drive` Phase 1 opens before
any design or implementation work, extracted as a standalone step. Use this when
you want to claim a task and drive it yourself in the current conversation
(so the board and every other session see it as owned) without invoking the
full `/drive` implement→PR→merge loop.

## Argument

- `/claim T<id>` (default) — release every task this clone currently holds,
  then claim `T<id>`. One PR (or, in solo-repo mode, one branch + local
  merge — see below) carries both effects.
- `/claim release T<id>` — release a single claim without acquiring another
  (abandoning a task, or handing it back).
- `/claim status` — read-only: report the claim(s) this clone currently holds.
  No PR.

## Solo-repo mode (no CI, direct-to-`main`)

Some repos are declared solo/no-CI in their own `dev/guidelines.md` (or
`CLAUDE.md`) Branch and Merge Policy — e.g. *"This is a solo repo with no
CI — direct-to-`main`, not feature-branch PRs."* **Detect it** by checking
whether that doc states direct-to-`main` with no feature-branch PR
requirement (a `grep -qi "no ci"` + `grep -qi "direct.to.main"` on
`dev/guidelines.md`/`CLAUDE.md` is a reasonable heuristic; when it's
ambiguous, ask).

There's no CI to gate a PR and no peer session to race against, so §1–§2's
PR step is pure ceremony there — but the **branch** and the **claim commit
landing on `main` before other work** both still earn their keep for a
different reason: the statusline
(`../statusline-setup/scripts/statusline-command.sh`) reads
the **live working tree**, not a remote — `branch: <name>` is literally
`git symbolic-ref --short HEAD` in the repo root, and `TASK: <id>: <title>`
is whichever `dev/TODO/*.md` has `claimed_by:` matching this clone's
`cc1-<machine-id>:<path-hash>` id. Staying on `main` the whole time, or
collapsing acquire-then-immediately-release into one uncommitted moment,
means both signals never show anything useful — which is exactly the gap
this mode closes.

**Solo-repo replacement for §1 steps 3–6** (steps 1–2's guards are
unchanged):

```bash
git checkout main && git pull   # no-op locally if there's no remote work to pull
git checkout -b t<id>-<slug>    # <slug> from the task title — this IS the "I'm on it" signal
bash ../_session/task_claim.sh release-others T<id>
bash ../_session/task_claim.sh acquire T<id>
git add dev/TODO/*.md dev/PARKING/*.md 2>/dev/null
git commit -m "docs(claim): claim T<id>, release <other-ids-if-any>"

# Land the claim on main immediately — durable, before any real work,
# same intent as the PR auto-merging fast in peer mode. If this fails
# because main moved, rebase the branch onto main first, then retry.
git checkout main && git merge --ff-only t<id>-<slug> && git push

# ...then go BACK to the branch and stay there for the actual work, so
# `branch:` in the statusline reads t<id>-<slug> for the task's duration,
# not main.
git checkout t<id>-<slug>
```

Do the task's real work as further commits on `t<id>-<slug>` — never commit
directly to `main` while a task is checked out this way (that's what makes
the later `--ff-only` merge back safe). At close (`/drive` Phase 7 or a
plain `/claim release`):

```bash
bash ../_session/task_claim.sh release T<id> <final-status>
git add -A   # + any Closed-section / journal-move edits
git commit -m "docs(tasks): close T<id>"   # or fold into the last work commit
git checkout main && git merge --ff-only t<id>-<slug> && git push
git branch -d t<id>-<slug>   # clears the statusline's branch signal back to main
```

Everything else in §1–§3 (the free/claimable checks, `release-others`
scoping, the reporting) is identical — only the branch/PR/CI plumbing
around the same `task_claim.sh` calls changes. `/drive` Phase 1's "Claim
PR" carries the peer-mode version of this same recipe; its own Solo-repo
mode note there is kept in sync with this one.

## Workflow

### §1. `/claim T<id>` — claim, releasing everything else this clone holds

1. **Clone-locality guard.** `bash ../_taskid/in-this-repo.sh T<id>`
   — exit 0 = the task file lives in this repo's `dev/TODO`/`dev/PARKING`;
   non-zero = wrong clone (it names the sibling clone that has it). Don't
   proceed past a non-zero result — `cd` there instead.
2. **Free + claimable checks.**
   - `bash ../_session/task_claim.sh read T<id>` — if
     `claimed_by` is set and is **not** this session's own id
     (`task_claim.sh claimant-id`), the task is held by another agent. Check
     `task_claim.sh reclaimable T<id>` — `live` means stop and report who
     holds it; `reclaimable` means a stale claim you may take over.
   - `bash ../_session/lint_frozen.sh is-frozen dev/TODO/T<id>-*.md`
     — exit 0 (frozen) means the claim PR cannot merge (a pre-existing
     frontmatter lint failure the changed-mode check will re-trip). Report
     the freeze reason and stop rather than opening an un-mergeable PR.
3. **Branch, release-others, acquire** (peer/CI mode — repos with CI and
   possible concurrent sessions; for a repo declared solo/no-CI, use
   "Solo-repo mode" above instead of steps 3–6 here):

   ```bash
   git checkout main && git pull
   git checkout -b t<id>-claim
   bash ../_session/task_claim.sh release-others T<id>
   bash ../_session/task_claim.sh acquire T<id>
   ```

   `release-others` frees every task this `cc1-<machine-id>:<path-hash>` identity
   currently holds except `T<id>` (release-on-pickup — keeps the claim count
   at ≤1 per clone); `acquire` sets `T<id>`'s `claimed_by` and flips
   `status: In Progress` (or `Design`, matching `/drive` Phase 1's own-judgment
   call on whether design work is still needed — default to `In Progress` if
   unsure).
4. **Commit and PR** — pure frontmatter change, docs-only, no other edits:

   ```bash
   git add dev/TODO/*.md dev/PARKING/*.md 2>/dev/null
   git commit -m "docs(claim): claim T<id>, release <other-ids-if-any>"
   git push -u origin t<id>-claim
   bash ../_gh/gh.sh pr create --title "docs(claim): claim T<id>" --body "..."
   ```

   Hand off to `/address-pr` — it auto-merges under the pure-status-change
   tier once CI is green.
5. **Conflict = you lost the race.** If the PR can't merge because another
   session's `claimed_by:` edit landed on `main` first (the merge conflicts
   on the same line), do not force it. `git checkout main && git pull`,
   re-read the task's new `claimed_by`, and report — the conflict **is** the
   lock rejecting the acquire. Don't re-attempt the same claim.
6. **Report:** which task got claimed, which (if any) got released, and the
   merged PR URL.

### §2. `/claim release T<id>` — release one claim without acquiring another

Same branch/commit/PR shape as §1.3–§1.6 (or the Solo-repo mode equivalent),
but only:

```bash
bash ../_session/task_claim.sh release T<id> Open
```

(pass a different final status — e.g. `Blocked by T...` — if that's why the
claim is being dropped, matching `/drive` Phase 7's close-release convention).

### §3. `/claim status` — read-only

**Do not `grep` for `claimed_by:` across whole files** — a task's prose body
can mention `claimed_by:` in passing (e.g. citing another task's claim in a
history note), producing a false positive. Use `task_claim.sh read`, which
parses only the frontmatter fence, per candidate file:

```bash
ME=$(bash ../_session/task_claim.sh claimant-id)
for f in dev/TODO/*.md dev/PARKING/*.md; do
  [ -f "$f" ] || continue
  id=$(basename "$f" | grep -oP '^T\d{8}-\d{6}')
  [ -n "$id" ] || continue
  out=$(bash ../_session/task_claim.sh read "$id" 2>/dev/null)
  [ "$(printf '%s' "$out" | cut -f2)" = "$ME" ] && echo "$id: $out"
done
```

Report the matching task ID(s) and their current `status:`, or "no active
claims" if none. No branch, no PR — this never mutates anything.

## Important Notes

- **This skill only lands the lock — it does not implement, PR, or merge the
  task's actual work.** For the full pick→design→implement→PR→merge loop,
  use `/drive`. Reach for `/claim` when you want the "somebody is working on
  this, and it's durable on `main`" guarantee without handing the rest of the
  session over to `/drive`'s task-selection and phase machinery — e.g. the
  user already told you which task to work on mid-conversation.
- **`≤1 active claim per clone` is the invariant `release-others` enforces.**
  Don't call `acquire` without a preceding `release-others` in the same PR —
  that's how claims silently accumulate on `main` until `/todo next` finds
  nothing pickable for this clone (the failure mode `release-others` exists to
  prevent).
- **One repo = one set of task files.** `/claim` operates on whichever repo's
  `dev/TODO/` the current working directory is in. For a cross-repo task
  (hub task file naming a `target-repo`), claim in the **hub** repo — the
  claim lock lives with the task file, not the implementation.
- Full verb/identity semantics: `_session/README.md` § "Task-claim lock".

## Cross-references

- `/drive` Phase 1 "Peer mode — cross-session claim lock" — the full claim-PR
  recipe this skill extracts
- `/address-pr` — drives the claim PR (and any later implementation PR) to
  merge
- `/todo` — `next` respects the same `claimed_by` lock when scoring
  candidates
- `_session/task_claim.sh` — the underlying script; `_session/README.md` for
  the design rationale
