#!/usr/bin/env bats
# Tests for ccxp/scripts/sync-and-prune-branches.sh's --skills-dir default
# resolution (T20260925-159860).
#
# The script previously defaulted skills_dir="${HOME}/.claude/skills", which
# on an interactive clone where that path is NOT the ccxp-skills checkout
# (e.g. it's Claude Code's own unrelated session-state dir) silently tried
# `git checkout main` in the wrong repo and surfaced a confusing raw git
# error. The fix: resolve the default relative to the script's OWN location
# ($BASH_SOURCE — the script physically lives inside the ccxp-skills repo at
# ccxp/scripts/), and verify the resolved dir has a ccxp-skills-shaped
# `origin` remote before touching it, failing loudly otherwise.
#
# Hermetic: every repo (the "project" repo the script is run from, and the
# "skills" repo it syncs) is a real local git repo with a local bare
# "remote", seeded under $BATS_TEST_TMPDIR. No network, no reliance on the
# real $HOME or this checkout's own git state. $HOME is deliberately pointed
# at an empty, unrelated directory in every test so a regression back to
# the old "${HOME}/.claude/skills" default is caught rather than
# accidentally passing against the real machine's layout.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT_SRC="$REPO_ROOT/ccxp/scripts/sync-and-prune-branches.sh"

  # Neutralize $HOME so the legacy default (~/.claude/skills) can never
  # accidentally resolve to anything real.
  export HOME="$BATS_TEST_TMPDIR/empty-home"
  mkdir -p "$HOME"

  export GIT_AUTHOR_NAME="bats" GIT_AUTHOR_EMAIL="bats@example.com"
  export GIT_COMMITTER_NAME="bats" GIT_COMMITTER_EMAIL="bats@example.com"
}

# mk_bare NAME -> creates a bare repo at $BATS_TEST_TMPDIR/remotes/NAME.git
# and prints its path. NAME may contain slashes are not supported; keep flat.
mk_bare() {
  local name="$1"
  local bare="$BATS_TEST_TMPDIR/remotes/$name.git"
  mkdir -p "$(dirname "$bare")"
  git init -q --bare "$bare"
  # Pin HEAD to refs/heads/main regardless of this machine's
  # init.defaultBranch (often still "master") — otherwise a bare repo's
  # unborn HEAD and the "main" branch seed_main/push_commit push to point
  # at different, unrelated refs, and a later clone follows the unborn
  # HEAD instead of the real branch.
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  echo "$bare"
}

# seed_main BARE_PATH -> clones BARE_PATH into a throwaway dir, commits an
# initial file on `main`, and pushes it so the bare repo has a real main
# branch other clones can pull.
seed_main() {
  local bare="$1" seed="$BATS_TEST_TMPDIR/seed-$RANDOM"
  git clone -q "$bare" "$seed"
  (
    cd "$seed"
    git checkout -q -b main
    echo "init" > README.md
    git add README.md
    git -c commit.gpgsign=false commit -q -m "init"
    git push -q origin main
  )
}

# push_commit BARE_PATH -> adds one more commit to BARE_PATH's main, so a
# clone that's already up to date has something new to pull.
push_commit() {
  local bare="$1" seed="$BATS_TEST_TMPDIR/push-$RANDOM"
  git clone -q "$bare" "$seed"
  (
    cd "$seed"
    git checkout -q main
    echo "update-$RANDOM" >> README.md
    git add README.md
    git -c commit.gpgsign=false commit -q -m "update"
    git push -q origin main
  )
}

# mk_skills_repo BARE_NAME -> clones BARE_NAME into a fresh dir laid out
# exactly like the real ccxp-skills checkout (script at ccxp/scripts/), and
# prints that dir's path.
mk_skills_repo() {
  local bare_name="$1" bare dir
  bare="$(mk_bare "$bare_name")"
  seed_main "$bare"
  dir="$BATS_TEST_TMPDIR/skills-repo-$RANDOM"
  git clone -q "$bare" "$dir"
  mkdir -p "$dir/ccxp/scripts"
  cp "$SCRIPT_SRC" "$dir/ccxp/scripts/sync-and-prune-branches.sh"
  echo "$dir"
}

# mk_project_repo -> a throwaway "working repo" clone to run the script
# from (its cwd), with its own real bare origin + main branch.
mk_project_repo() {
  local bare dir
  bare="$(mk_bare "project")"
  seed_main "$bare"
  dir="$BATS_TEST_TMPDIR/project-repo"
  git clone -q "$bare" "$dir"
  echo "$dir"
}

@test "defaults skills_dir to the repo containing the script itself, not \$HOME/.claude/skills" {
  SKILLS_REPO="$(mk_skills_repo ccxp-skills)"
  PROJECT_REPO="$(mk_project_repo)"

  # Advance the skills repo's remote so we can prove a real pull landed in
  # THIS dir specifically (not some other default-resolved path).
  push_commit "$BATS_TEST_TMPDIR/remotes/ccxp-skills.git"
  want_head="$(git -C "$BATS_TEST_TMPDIR/remotes/ccxp-skills.git" rev-parse main)"

  cd "$PROJECT_REPO"
  run bash "$SKILLS_REPO/ccxp/scripts/sync-and-prune-branches.sh"
  [ "$status" -eq 0 ]
  [ "$(git -C "$SKILLS_REPO" rev-parse HEAD)" = "$want_head" ]
}

@test "the legacy \$HOME/.claude/skills default is gone (empty \$HOME/.claude/skills would have failed before the fix)" {
  # Regression guard: if the old default ever crept back in, this would
  # resolve to $HOME/.claude/skills (which doesn't exist under our
  # neutralized $HOME) and the run above would have failed. This test just
  # asserts that path was never even touched.
  SKILLS_REPO="$(mk_skills_repo ccxp-skills)"
  PROJECT_REPO="$(mk_project_repo)"

  cd "$PROJECT_REPO"
  run bash "$SKILLS_REPO/ccxp/scripts/sync-and-prune-branches.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/skills" ]
}

@test "--skills-dir flag overrides the self-relative default" {
  DEFAULT_SKILLS_REPO="$(mk_skills_repo ccxp-skills)"
  # A second, distinct ccxp-skills clone location (e.g. a different machine)
  # — its origin remote still ends in /ccxp-skills(.git), same as the real
  # thing, so the remote-shape guard accepts it too.
  ALT_SKILLS_REPO="$(mk_skills_repo alt-location/ccxp-skills)"
  PROJECT_REPO="$(mk_project_repo)"

  push_commit "$BATS_TEST_TMPDIR/remotes/alt-location/ccxp-skills.git"
  alt_want_head="$(git -C "$BATS_TEST_TMPDIR/remotes/alt-location/ccxp-skills.git" rev-parse main)"
  default_head_before="$(git -C "$DEFAULT_SKILLS_REPO" rev-parse HEAD)"

  cd "$PROJECT_REPO"
  run bash "$DEFAULT_SKILLS_REPO/ccxp/scripts/sync-and-prune-branches.sh" --skills-dir "$ALT_SKILLS_REPO"
  [ "$status" -eq 0 ]
  # The explicitly-passed dir got the new commit...
  [ "$(git -C "$ALT_SKILLS_REPO" rev-parse HEAD)" = "$alt_want_head" ]
  # ...and the default-resolved dir (not passed) was left untouched.
  [ "$(git -C "$DEFAULT_SKILLS_REPO" rev-parse HEAD)" = "$default_head_before" ]
}

@test "fails loudly, not with a raw git error, when skills_dir has no ccxp-skills-shaped origin remote" {
  WRONG_REPO_BARE="$(mk_bare "some-other-repo")"
  seed_main "$WRONG_REPO_BARE"
  WRONG_REPO="$BATS_TEST_TMPDIR/wrong-repo"
  git clone -q "$WRONG_REPO_BARE" "$WRONG_REPO"
  PROJECT_REPO="$(mk_project_repo)"

  cd "$PROJECT_REPO"
  run bash "$REPO_ROOT/ccxp/scripts/sync-and-prune-branches.sh" --skills-dir "$WRONG_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"doesn't look like the ccxp-skills checkout"* ]]
  [[ "$output" != *"pathspec"* ]]
}

@test "fails loudly when skills_dir is not a git repo at all" {
  NOT_A_REPO="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$NOT_A_REPO"
  PROJECT_REPO="$(mk_project_repo)"

  cd "$PROJECT_REPO"
  run bash "$REPO_ROOT/ccxp/scripts/sync-and-prune-branches.sh" --skills-dir "$NOT_A_REPO"
  [ "$status" -ne 0 ]
  [[ "$output" == *"doesn't look like the ccxp-skills checkout"* ]]
}

@test "proceeds normally (no regression) when skills_dir has a matching ccxp-skills origin remote" {
  SKILLS_REPO="$(mk_skills_repo ccxp-skills)"
  PROJECT_REPO="$(mk_project_repo)"

  cd "$PROJECT_REPO"
  run bash "$SKILLS_REPO/ccxp/scripts/sync-and-prune-branches.sh" --skills-dir "$SKILLS_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Phase 0:"* ]]
}
