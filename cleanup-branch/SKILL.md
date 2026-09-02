---
name: cleanup-branch
description: Use when the user explicitly asks to clean up local branches after merged PRs — a specific just-merged branch, a full PR-merge sweep, or a bulk prune of branches whose upstream is gone
disable-model-invocation: false
argument-hint: "[branch-name | prune [--dry-run]]"
---

Post-merge branch hygiene, in two safety tiers. All logic is deterministic and
lives in `scripts/cleanup-branch.sh` — this skill runs it and relays the
report; it does not re-derive the per-branch decisions.

## Argument

`$ARGUMENTS` selects the mode:

- `/cleanup-branch` — PR-verified sweep of **all** local branches (§1)
- `/cleanup-branch docs/foo` — PR-verified sweep scoped to one branch (§1)
- `/cleanup-branch prune` — delete branches whose upstream is gone, no PR check (§2)
- `/cleanup-branch prune --dry-run` — list what §2 would delete, don't delete (§2)

## Workflow

```bash
bash ~/.claude/skills/cleanup-branch/scripts/cleanup-branch.sh $ARGUMENTS
```

Relay its stdout as the report — a tab-separated `BRANCH / STATUS / PR` table
for §1, a count for §2. Render it as a table; the safety gate (merged-PR
check for §1, `[gone]` upstream state for §2) is already applied and reported
inside the script, so there is no per-branch judgment call left to make.

- §1 tries `git branch -d` first, and only force-deletes with `-D` when
  GitHub already confirmed the PR merged — handles rebase/squash-merged
  branches, where local SHAs never match `main`.
- §2 always force-deletes (no merge confirmation to justify the safe path
  first), and never touches the default branch or the one currently checked
  out.

## Important Notes

- The script exits non-zero only on a condition that needs a human call, never
  on a normal "nothing to clean up":
  - **`git checkout main` failed** (uncommitted changes on the current
    branch). Stop and report the error. Do **not** stash or discard to work
    around it — that's the caller's uncommitted work to decide on, not this
    skill's.
  - Any other non-zero exit (missing `origin` remote, `gh` auth failure,
    etc.) — report the stderr output verbatim and stop.
