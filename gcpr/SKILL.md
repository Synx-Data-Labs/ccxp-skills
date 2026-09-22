---
name: gcpr
description: Use when the user explicitly asks to commit & push uncommitted changes and open a PR (then hands off to /address-pr)
disable-model-invocation: false
argument-hint: [commit-message-or-description]
---

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

```bash
git status --short
git diff --stat
git diff --staged --stat
```

If there are no changes (no untracked, no modified, no staged), don't stop yet — a clean
tree doesn't mean there's nothing left to do. Check whether the current branch is already
ahead of `main` with committed work that hasn't made it into a PR:

```bash
git rev-parse --abbrev-ref HEAD                  # skip this check entirely if this is "main"
git log --oneline main..HEAD                     # any commits ahead?
bash ../_gh/gh.sh pr list --head <branch> --state all   # does a PR already exist?
```

- **On `main`, no ahead-commits**: genuinely nothing to do — stop and tell the user "nothing
  to commit".
- **Not on `main`, no commits ahead of `main`**: same — stop and report "nothing to commit".
- **Not on `main`, commits ahead of `main`, no PR found**: skip steps 2-4 (nothing to
  group/commit) and jump straight to step 5 (push) → step 6 (create PR) → step 7 (hand off
  to `/address-pr`).
- **Not on `main`, commits ahead of `main`, a PR already exists**: don't create a duplicate —
  report that PR's URL and hand off directly to `/address-pr <number>`.

### 1.5 Doc-lint guard (pre-commit) — catch MD032 before docs reach `main`

The `Markdown Lint` CI gates only *post*-push, so a malformed standup / journal / IPM / retro doc
reds `main` until a fix-PR lands. Before staging, run the shared doc-lint guard so the
recurring formatting class (chiefly MD032, blanks-around-lists) is auto-fixed locally and folded
into the commit — only when the change touches markdown:

```bash
CHANGED_MD=$(git status --porcelain | awk '{print $2}' | grep -E '\.md$' || true)
if [ -n "$CHANGED_MD" ]; then
  # shellcheck disable=SC2086  # word-splitting is intended: one path per changed file
  bash ../_docs/lint-docs.sh --fix $CHANGED_MD \
    || echo "::warning::lint-docs: unfixable markdown issues remain — CI Markdown Lint will gate"
fi
```

`../_docs/lint-docs.sh` (T20260626-117003; moved here from build-pipeline's own
scripts/ and generalized by T20260719-111051) ships with the skill, so it's available in every repo
gcpr runs in (ccxp-skills / example-website.com / hub-repo / build-pipeline-repo) — no more
per-repo `[ -f ]` no-op. Policy is **fix-then-continue**: `--fix` corrects what it can; a residual
unfixable violation surfaces loudly but does not block the commit — the PR's own `Markdown Lint`
check is the authoritative gate. This is the canonical recipe; the ad-hoc doc-push sites in
`/ccxp` and `/drive` call the one-line form of it. (T20260627-192311.)

Also run the paragraph-length nudge over any changed `dev/TODO/`/`dev/PARKING/` files — same
non-blocking, print-and-continue policy, surfaced right before the commit so the agent sees it
about its own writing:

```bash
CHANGED_TASKS=$(git status --porcelain | awk '{print $2}' | grep -E '^dev/(TODO|PARKING)/.*\.md$' || true)
if [ -n "$CHANGED_TASKS" ]; then
  python3 ../repo-conventions/scripts/lint_paragraphs.py --changed $CHANGED_TASKS
fi
```

`lint_paragraphs.py` (`repo-conventions/scripts/`) never fails the commit — it's a nudge toward the
"bullets, not paragraphs" house style (`templates/guidelines.md`), not a gate. Revise where the
flagged content genuinely decomposes into bullets; leave narrative sections (Root cause, Closed) as
prose — the script already exempts those two headings.

Also auto-link task/issue/PR references in any changed `dev/TODO/`/`dev/JOURNAL/` files — makes
`T<id>` refs and typed `PR #N`/`issue #N` refs clickable (T20260616-130977):

```bash
CHANGED_REFS=$(git status --porcelain | awk '{print $2}' | grep -E '^dev/(TODO|JOURNAL)/.*\.md$' || true)
if [ -n "$CHANGED_REFS" ]; then
  python3 ../repo-conventions/scripts/lint_refs.py --fix --changed $CHANGED_REFS
fi
```

`lint_refs.py --fix` also never fails the commit — a reference it can't resolve (e.g. a cross-repo
T-id) is left bare rather than guessed at, and that's expected, not an error.

### 2. Group into logical commits

This is the critical step. Analyze ALL uncommitted changes and split them into logical groups. Each group becomes one commit.

**Grouping rules (apply in order):**

1. **By category**: separate docs, config, functional code, tests, infrastructure
2. **By scope**: changes to the same feature/component belong together
3. **Secrets check**: never stage `.env`, credentials, tokens — warn the user

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
  - If `$ARGUMENTS` contains `--branch <name>`, use that
  - Otherwise generate from the changes: `fix/short-slug` or `feat/short-slug` or `docs/short-slug`
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
- Always append:

  ```
  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  ```

- Commit using HEREDOC format:

  ```bash
  git commit -m "$(cat <<'EOF'
  <message>

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

### 5. Push branch

On a machine with multiple `gh`-authenticated accounts, a bare `git push` can silently
authenticate as whichever account is globally active — which may not have write access to
this repo. Route through `_gh/git.sh`, which auto-detects the account with write access the
same way `_gh/gh.sh` does for `gh` calls (process-scoped `GH_TOKEN`, no global `gh auth
switch` — T20260911-140914):

```bash
bash ../_gh/git.sh push -u origin <branch>
```

### 6. Create PR

- Generate a PR title (short, under 70 chars) that covers all commits
- Body format:

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

If this PR is opened in a target repo on behalf of a task that lives in a different hub repo (e.g., implementation in `example-website.com`, task tracker in `hub-repo`), prepend this line to the `## Summary` section:

```
Task: https://github.com/<hub-owner>/<hub-repo>/blob/main/dev/TODO/T<id>-<slug>.md
```

Do not move the task file to JOURNAL in this PR — the task file lives in the hub repo, not this one. The `/drive` skill's Phase 7 opens a separate hub-repo PR for the journal move after this target PR merges.

- Use: `bash ../_gh/gh.sh pr create --title "..." --body "$(cat <<'EOF' ... EOF)"`

### 6.5 Flip task-file Status to `Review`

Right after `gh pr create` succeeds, edit the task file in `dev/TODO/T<id>-*.md` to flip Status from `Coding` to `Review`. This reflects the lifecycle from `dev/guidelines.md` (`Open → Design → Coding → Review → Done`); without it, tasks jump from `Coding` straight to `Done` when the JOURNAL move lands.

Done in-place; no separate registry to update.

### 6.6 Annotate the Project item title with the PR ref (best-effort)

Also right after `gh pr create` succeeds, if the work is tracked (the branch/PR maps to a `T<id>` task), append the PR ref to the task's Project item title so the board surfaces the task→PR mapping at a glance — e.g. `T20260510-285938: … (ccxp-skills#37)`:

```bash
TASK_ID=$(bash ../_session/pr_task_id.sh <pr-number>)
[ -n "$TASK_ID" ] && bash ../_session/set-pr-ref.sh "$TASK_ID" "<pr-url>"
```

`<pr-url>` is the URL printed by `gh pr create`. Idempotent and best-effort — failures log to stderr and never block. `/address-pr` re-asserts the same stamp on entry, so a skipped or failed call here is recovered there. Skip silently for untracked work (no `T<id>`).

### 7. Report and hand off to `/address-pr`

Once the PR is created, gcpr's job is done. Report to the user and explicitly hand off:

- PR number and URL
- Number of commits
- Current branch

Then trigger `/address-pr <pr-number>` to take over: that skill requests Copilot review, waits for CI, handles review comments, runs the pre-merge gate, and follows the tiered merge policy from `dev/guidelines.md`.

**Why the split:** gcpr owns the local-git-to-PR-creation path. Everything after PR creation — CI watching, Copilot requesting + waiting, comment handling, pre-merge gating, merge — is address-pr's responsibility. Keeping them separate means a failed review cycle doesn't re-run the commit/push machinery, and address-pr works equally well on PRs you opened via gcpr, the GitHub UI, or any other path.
