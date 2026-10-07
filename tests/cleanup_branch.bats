#!/usr/bin/env bats
# Tests for cleanup-branch/scripts/cleanup-branch.sh's merged-PR force-delete
# fallback (T20261006-579135, split off T20260928-101526 README §1).
#
# Bug: run_pr_verified() falls back to `git branch -D` for ANY branch with a
# merged PR, once the safe `git branch -d` refuses (the normal case after a
# squash/rebase merge, since the branch's individual commits aren't ancestors
# of main even though their content landed there). That blanket fallback also
# force-deletes a branch that picked up MORE commits after its PR merged —
# silently discarding local work that was never pushed/merged anywhere.
#
# Fix: before force-deleting, check whether the branch's tree still matches
# main's (`git diff --quiet main "$b"`). Identical trees -> the `-d` refusal
# was just the squash/rebase SHA mismatch, safe to force-delete. Different
# trees -> the branch carries un-merged content; skip and report instead of
# discarding it.
#
# Hermetic: a real local git repo with a local bare "remote", seeded under
# $BATS_TEST_TMPDIR, same style as tests/sync_and_prune_branches.bats. The
# script's own `$GH_SCRIPT` resolution (`<scripts-dir>/../../_gh/gh.sh`) is
# satisfied by copying the real script into a fixture layout next to a fake
# `_gh/gh.sh` that reports a merged PR for whichever branch names the test
# lists in $FAKE_GH_MERGED_BRANCHES — no real `gh`/GitHub involved.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT_SRC="$REPO_ROOT/cleanup-branch/scripts/cleanup-branch.sh"

  export GIT_AUTHOR_NAME="bats" GIT_AUTHOR_EMAIL="bats@example.com"
  export GIT_COMMITTER_NAME="bats" GIT_COMMITTER_EMAIL="bats@example.com"

  FIXTURE="$BATS_TEST_TMPDIR/fixture-repo"
  mkdir -p "$FIXTURE/cleanup-branch/scripts" "$FIXTURE/_gh"
  cp "$SCRIPT_SRC" "$FIXTURE/cleanup-branch/scripts/cleanup-branch.sh"
  SCRIPT="$FIXTURE/cleanup-branch/scripts/cleanup-branch.sh"

  cat > "$FIXTURE/_gh/gh.sh" <<'FAKE_GH'
#!/usr/bin/env bash
# Fake gh.sh: reports a merged PR for every branch name listed in
# $FAKE_GH_MERGED_BRANCHES (space-separated), nothing for anything else.
head=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --head) head="$2"; shift 2 ;;
    *) shift ;;
  esac
done
for b in ${FAKE_GH_MERGED_BRANCHES:-}; do
  if [[ "$b" == "$head" ]]; then
    echo '{"number":42,"url":"https://github.com/example/repo/pull/42","mergedAt":"2026-01-01T00:00:00Z"}'
    exit 0
  fi
done
exit 0
FAKE_GH
  chmod +x "$FIXTURE/_gh/gh.sh"
}

# mk_bare NAME -> bare repo at $BATS_TEST_TMPDIR/remotes/NAME.git, HEAD pinned
# to refs/heads/main regardless of this machine's init.defaultBranch.
mk_bare() {
  local name="$1" bare="$BATS_TEST_TMPDIR/remotes/$name.git"
  mkdir -p "$(dirname "$bare")"
  git init -q --bare "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  echo "$bare"
}

# Clones $1 (a bare repo path) into a fresh work dir, seeds `main` with one
# commit, pushes it, and prints the work dir path.
seed_work_repo() {
  local bare="$1" dir="$BATS_TEST_TMPDIR/work"
  git clone -q "$bare" "$dir"
  (
    cd "$dir"
    git checkout -q -b main
    echo "init" > README.md
    git add README.md
    git -c commit.gpgsign=false commit -q -m "init"
    git push -q origin main
  )
  echo "$dir"
}

@test "SKIPS (does not force-delete) a merged-PR branch that has commits made after the merge" {
  BARE="$(mk_bare origin)"
  WORK="$(seed_work_repo "$BARE")"
  cd "$WORK"

  git checkout -q -b feature
  echo "feature work" > feature.txt
  git add feature.txt
  git -c commit.gpgsign=false commit -q -m "feature work"

  # Simulate a squash merge of the feature branch's content into main (the
  # normal case: same tree, different/no commit history relationship).
  git checkout -q main
  git checkout -q feature -- feature.txt
  git add feature.txt
  git -c commit.gpgsign=false commit -q -m "squash merge feature (#42)"
  git push -q origin main

  # Now the branch picks up MORE work after its PR's content already merged
  # — exactly the commits the bug would silently discard.
  git checkout -q feature
  echo "post-merge continued work" > post-merge.txt
  git add post-merge.txt
  git -c commit.gpgsign=false commit -q -m "post-merge continued work"

  FAKE_GH_MERGED_BRANCHES="feature" run bash "$SCRIPT" feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED: diverges from main since PR merge"* ]]
  [[ "$output" != *"deleted (force"* ]]

  # The branch, and its post-merge commit, must still exist.
  run git rev-parse --verify feature
  [ "$status" -eq 0 ]
  run git log feature --oneline
  [[ "$output" == *"post-merge continued work"* ]]
}

@test "force-deletes a merged-PR branch whose tree matches main (squash/rebase merge, no drift)" {
  BARE="$(mk_bare origin)"
  WORK="$(seed_work_repo "$BARE")"
  cd "$WORK"

  git checkout -q -b feature
  echo "feature work" > feature.txt
  git add feature.txt
  git -c commit.gpgsign=false commit -q -m "feature work"

  git checkout -q main
  git checkout -q feature -- feature.txt
  git add feature.txt
  git -c commit.gpgsign=false commit -q -m "squash merge feature (#42)"
  git push -q origin main

  # No further commits on feature after the squash merge — its tree is
  # identical to main's. Safe to force-delete.
  FAKE_GH_MERGED_BRANCHES="feature" run bash "$SCRIPT" feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"deleted (force, rebased/squash merge)"* ]]
  [[ "$output" != *"SKIPPED"* ]]

  run git rev-parse --verify feature
  [ "$status" -ne 0 ]
}

@test "still soft-deletes normally when the branch is a true ancestor of main (regular merge)" {
  BARE="$(mk_bare origin)"
  WORK="$(seed_work_repo "$BARE")"
  cd "$WORK"

  git checkout -q -b feature
  echo "feature work" > feature.txt
  git add feature.txt
  git -c commit.gpgsign=false commit -q -m "feature work"

  # A real (non-squash) merge: main's history actually contains feature's commit.
  git checkout -q main
  git merge -q --no-ff feature -m "Merge branch 'feature'"
  git push -q origin main

  FAKE_GH_MERGED_BRANCHES="feature" run bash "$SCRIPT" feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(printf 'feature\tdeleted\t')"* ]]
  [[ "$output" != *"SKIPPED"* ]]
  [[ "$output" != *"force"* ]]

  run git rev-parse --verify feature
  [ "$status" -ne 0 ]
}
