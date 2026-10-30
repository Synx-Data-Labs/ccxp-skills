---
name: gcpr
description: Use when the user explicitly asks to commit & push uncommitted changes and open a PR (then hands off to /address-pr)
argument-hint: [commit-message-or-description]
---

> `<skills-root>` = this skill's "Base directory" minus its last component; substitute the literal path (`skill-conventions` §9).

Group-Commit-PR — automates the branch workflow up to PR creation. Once the PR is open, hand off to the `/address-pr` skill, which owns CI watching, Copilot review handling, pre-merge gating, and merge. Keeping the split clean means each skill has one job.

Also invocable as `/land` (see `land/SKILL.md`) — same skill, more natural name.

## Argument

`$ARGUMENTS` optionally contains:

- A commit message or short description: `/gcpr fix conan profile mismatch`
- A branch name hint: `/gcpr --branch t63-conan-fix fix conan profile`
- Empty: `/gcpr` (will infer message from staged changes)

## Workflow

Execute these steps in order. Stop and report if any step fails.

**Non-destructive git only.** This skill must never use destructive operations — no `git reset`, no `git stash`, no `git checkout --`, no `--force`. Those commands can silently drop committed work or clobber uncommitted edits. Prefer `git add`/`git add -p` to control staging, `git restore --staged` (non-destructive: only unstages, keeps working-tree changes) when you need to unstage, `git cherry-pick` to move commits between branches, and `git revert` to undo landed commits. If you find yourself reaching for a destructive command, stop and ask the user.

### 1. Assess changes

The mechanical prep lives in `<skills-root>/gcpr/scripts/gcpr-prep.sh` (verbs below; the script never commits, pushes or opens a PR, those stay in this workflow). Run:

```bash
bash <skills-root>/gcpr/scripts/gcpr-prep.sh assess      # prints STATE=, BRANCH=, AHEAD=, PR=; exit 0 = work to do, 3 = nothing to do, 2/4 = problem
```

A clean tree doesn't mean there's nothing left to do: `assess` also checks whether the branch is ahead of `main` with committed work that has no PR yet. Act on `STATE`:

- **`clean-main`** (on `main`, nothing ahead) or **`clean-no-commits`** (feature branch, nothing ahead): genuinely nothing to do. Stop and tell the user "nothing to commit".
- **`dirty`**: continue with steps 1.5-4.
- **`ahead-no-pr`**: skip steps 2-4 (nothing to group/commit); run `secrets-check --base main` (step 2) over the committed work, then step 5 (push), step 6 (create PR), step 7 (hand off to `/address-pr`).
- **`ahead-pr:<n>`**: don't create a duplicate. Report that PR's URL and hand off directly to `/address-pr <n>`.
- **`unknown`** / exit 4 (the PR lookup failed) or exit 2: stop and report; never guess "no PR".

### 1.5 Doc-lint guard (pre-commit) — catch MD032 before docs reach `main`

The `Markdown Lint` CI gates only *post*-push, so a malformed standup / journal / IPM / retro doc reds `main` until a fix-PR lands. Before staging, run the lint bundle over the changed files:

```bash
bash <skills-root>/gcpr/scripts/gcpr-prep.sh lint
```

It runs, only over the changed non-deleted paths (the script resolves renames and untracked files; `gcpr-prep.sh changed md|tasks|refs` lists them):

- `_docs/lint-docs.sh` on changed `.md` (check-only; auto-fixing MD032 is out, see that script's header);
- `repo-conventions/scripts/lint_paragraphs.py --changed` on changed `dev/TODO`/`dev/PARKING` files: a "bullets, not paragraphs" nudge (`templates/guidelines.md`), never a gate; Root cause and Closed stay prose;
- `repo-conventions/scripts/lint_refs.py --fix --changed` on changed `dev/TODO`/`dev/JOURNAL` files: makes `T<id>` and typed `PR #N`/`issue #N` refs clickable; a ref it can't resolve (e.g. a cross-repo T-id) stays bare, which is expected.

Policy is **check-then-continue**: `lint` always exits 0 and a violation surfaces loudly without blocking the commit. The PR's own `Markdown Lint` check is the authoritative gate. This is the canonical recipe; the ad-hoc doc-push sites in `/ccxp` and `/drive` call the one-line form of `_docs/lint-docs.sh`.

### 2. Group into logical commits

This is the critical step. Analyze ALL uncommitted changes and split them into logical groups. Each group becomes one commit.

**Grouping rules (apply in order):**

1. **By category**: separate docs, config, functional code, tests, infrastructure
2. **By scope**: changes to the same feature/component belong together
3. **Secrets check** (fail closed): before staging anything, run `bash <skills-root>/gcpr/scripts/gcpr-prep.sh secrets-check`. It lists `BLOCK <path>:<line> <rule>` (never the matched text) and exits 1 on any hit, 2 if it could not run; unscannable files (non-media binaries, symlinks) count as hits. On a block do not stage those paths: report them to the user and leave them out. Never print or paste a matched value.

**How to group:**

- Read the diffs to understand what each file change does
- Classify each file into a group based on its purpose
- If all changes are logically related (same feature, same scope), make one commit
- If changes span different concerns (e.g., docs fix + config change + new feature), split into multiple commits
- Each group gets its own commit message (conventional commits style)

**Do NOT ask the user to confirm grouping** — use your judgment and proceed. The user trusts you to make the right call.

### 3. Create feature branch

- If already on a feature branch (not `main`), stay on it
- If on `main`, create a branch:
  - If `$ARGUMENTS` contains `--branch <name>`, use that after `gcpr-prep.sh branch-name --check <name>` passes (exit 0)
  - Otherwise pick the type and wording yourself and let the script format it: `gcpr-prep.sh branch-name <feat|fix|docs|chore|refactor|test|ci> <text...>` prints `<type>/<slug>`
- `git checkout -b <branch>`

### 3.5 Splitting unrelated work onto a separate branch/PR

If — after committing in step 4 — you notice that some commits on the current branch are logically unrelated to the others (different feature, different scope, shouldn't land together), DO NOT use `git reset`, `git stash`, or any other destructive operation to "move" them. Destructive commands risk losing work.

Instead, use cherry-pick:

1. Identify the commit SHAs you want to move.
2. Create a new branch off `main` for the split-out work: `git checkout main && git checkout -b <new-branch>`.
3. Cherry-pick each target commit: `git cherry-pick <sha>...`.
4. Push the new branch and open its own PR.
5. Leave the original branch alone — its commits stay in place. If the unrelated commits should be removed from the original branch, do that with an explicit `git rebase -i` only after the cherry-picked PR has merged (or ask the user first).

Rule: **never use `git reset`, `git stash`, or `git checkout --` to relocate committed work.** Cherry-pick preserves history; reset/stash can silently drop commits.

### 4. Commit (one per group)

**cwd discipline (cross-repo mode)**: Before any `git add` / `git commit` / `git push` invocation in cross-repo mode, verify `pwd` literally matches the target-repo clone path (typically `/tmp/cc-<repo>-...` or whatever `$TARGET` resolves to). The `gcpr` workflow is most often invoked from `/drive` Phase 4, which has already `cd`'d into `$TARGET` — but if you're driving it manually, an `assert pwd == $TARGET` check costs nothing and prevents committing the wrong repo's changes. Same rule applies to /address-pr.

For each logical group:

- Stage only the files in that group with `git add <file>...`
- Draft a concise commit message (conventional commits style: `fix:`, `feat:`, `docs:`, `refactor:`)
- If `$ARGUMENTS` provides a message and there is only one group, use it as the commit title
- Always append the attribution trailer the session specifies (the system-reminder's "End git commit messages with:" line carries the correct model name). Never hardcode a model/version; if the session gives none, use `Co-Authored-By: Claude <noreply@anthropic.com>`.

- Commit using HEREDOC format:

  ```bash
  git commit -m "$(cat <<'EOF'
  <message>

  <attribution trailer from the session, per above>
  EOF
  )"
  ```

### 5. Push branch

On a machine with multiple `gh`-authenticated accounts, a bare `git push` can silently
authenticate as whichever account is globally active — which may not have write access to
this repo. Route through `_gh/git.sh`, which auto-detects the account with write access the
same way `_gh/gh.sh` does for `gh` calls (process-scoped `GH_TOKEN`, no global `gh auth
switch`):

```bash
bash <skills-root>/_gh/git.sh push -u origin <branch>
```

### 6. Create PR

- Generate a PR title (short, under 70 chars) that covers all commits
- Write the Summary bullets and the Pre-merge / Post-merge checklists (your judgment) to temp files, then assemble the body mechanically:

  ```bash
  bash <skills-root>/gcpr/scripts/gcpr-prep.sh body --summary-file S --pre P --post Q [--task-url URL] > body.md
  ```

  It always emits both sections (an empty or absent file becomes `N/A`), puts `--task-url` first in the Summary and ends with the "Generated with" footer (`--footer TEXT` replaces it when the session specifies one, e.g. a leading robot emoji). Resulting format:

  ```
  ## Summary
  <1-3 bullet points>

  ## Test plan

  ### Pre-merge
  <checklist — items that must be verified before merging>

  ### Post-merge
  <checklist — items that can only be verified after merge>
  (write "N/A" if no post-merge items)

  Generated with [Claude Code](https://claude.com/claude-code)
  ```

  **Always include both `### Pre-merge` and `### Post-merge` sections** — even if one has no items (use "N/A"). This makes the intent explicit.

  **Rules for which section:**
  - **Pre-merge**: CI checks, BATS tests, Copilot review, pipeline dry-runs on branch, code review items
  - **Post-merge**: New workflows (can't dispatch from branch), production pipeline runs, artifact verification on the package registry, end-to-end validation

#### Cross-repo tasks

If this PR is opened in a target repo on behalf of a task that lives in a different hub repo (e.g., implementation in `example-website.com`, task tracker in `hub-repo`), pass the task URL as `--task-url` to `body` so this line leads the `## Summary` section:

```
Task: https://github.com/<hub-owner>/<hub-repo>/blob/main/dev/TODO/T<id>-<slug>.md
```

Do not move the task file to JOURNAL in this PR — the task file lives in the hub repo, not this one. The `/drive` skill's Phase 7 opens a separate hub-repo PR for the journal move after this target PR merges.

- Use: `bash <skills-root>/_gh/gh.sh pr create --title "..." --body-file body.md`

### 6.5 Task-file Status `Review` — do this before Step 4, not here

If the PR implements a tracked task whose `status:` is `In Progress`, flip it to `Review` in `dev/TODO/T<id>-*.md` **before Step 4's commit**, so the change ships in this very PR (lifecycle in `dev/guidelines.md`: `Open → Design → In Progress → Review → Done`). Do **not** edit the task file after `gh pr create`: nothing would commit it, leaving an orphaned dirty edit that the next branch swallows or loses. Run `bash <skills-root>/gcpr/scripts/gcpr-prep.sh review-flip T<id>` (exit 0 flipped, 3 nothing to flip; `--dry-run` previews). Skip when the PR closes the task (Phase 4 of `/drive` sets `Done` instead) or for untracked work.

### 6.6 Annotate the Project item title with the PR ref (best-effort)

Also right after `gh pr create` succeeds, if the work is tracked (the branch/PR maps to a `T<id>` task), append the PR ref to the task's Project item title so the board surfaces the task→PR mapping at a glance — e.g. `T20260510-285938: … (ccxp-skills#37)`:

```bash
TASK_ID=$(bash <skills-root>/_session/pr_task_id.sh <pr-number>)
[ -n "$TASK_ID" ] && bash <skills-root>/_session/set-pr-ref.sh "$TASK_ID" "<pr-url>"
```

`<pr-url>` is the URL printed by `gh pr create`. Idempotent and best-effort — failures log to stderr and never block. `/address-pr` re-asserts the same stamp on entry, so a skipped or failed call here is recovered there. Skip silently for untracked work (no `T<id>`).

### 7. Report and hand off to `/address-pr`

Once the PR is created, gcpr's job is done. Report to the user and explicitly hand off:

- PR number and URL
- Number of commits
- Current branch

Then trigger `/address-pr <pr-number>` to take over: that skill requests Copilot review, waits for CI, handles review comments, runs the pre-merge gate, and follows the tiered merge policy from `dev/guidelines.md`.

**Why the split:** gcpr owns the local-git-to-PR-creation path. Everything after PR creation — CI watching, Copilot requesting + waiting, comment handling, pre-merge gating, merge — is address-pr's responsibility. Keeping them separate means a failed review cycle doesn't re-run the commit/push machinery, and address-pr works equally well on PRs you opened via gcpr, the GitHub UI, or any other path.
