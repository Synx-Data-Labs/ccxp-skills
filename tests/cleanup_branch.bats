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

load test_helper
setup() {
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
# FAKE_GH_FAIL=1 simulates a gh outage (non-zero exit, no output).
[[ "${FAKE_GH_FAIL:-}" == "1" ]] && exit 1
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

# --- additional coverage (skills scripting plan, Phase 1) -------------------

# squash_merge_feature: feature has one commit; main gets its content under a
# different SHA (rebase/squash merge) and the feature branch has no extra work.
add_branch_commit() { # branch file
  git checkout -q -b "$1"
  echo "$1 work" > "$2"
  git add "$2"
  git -c commit.gpgsign=false commit -q -m "$1 work"
}

@test "SKIPS a branch with no merged PR and keeps it (nothing to verify, nothing deleted)" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  add_branch_commit wip wip.txt
  git checkout -q main

  FAKE_GH_MERGED_BRANCHES="" run bash "$SCRIPT" wip
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(printf 'wip\tskipped: no merged PR')"* ]]
  run git rev-parse --verify wip
  [ "$status" -eq 0 ]
}

@test "fails closed when gh is unavailable: branch is reported skipped, not deleted" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  add_branch_commit feature feature.txt
  git checkout -q main

  FAKE_GH_FAIL=1 FAKE_GH_MERGED_BRANCHES="feature" run bash "$SCRIPT" feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: no merged PR"* ]]
  run git rev-parse --verify feature
  [ "$status" -eq 0 ]
}

@test "full sweep deletes only the merged branch, keeps the unmerged one, never touches main" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  add_branch_commit done done.txt
  git checkout -q main
  git merge -q --no-ff done -m "Merge branch 'done'"
  git push -q origin main
  add_branch_commit open open.txt
  git checkout -q main

  FAKE_GH_MERGED_BRANCHES="done" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(printf 'BRANCH\tSTATUS\tPR')"* ]]
  [[ "$output" == *"$(printf 'done\tdeleted\t')"* ]]
  [[ "$output" == *"$(printf 'open\tskipped: no merged PR')"* ]]
  [[ "$output" != *"$(printf 'main\t')"* ]]
  run git rev-parse --verify done
  [ "$status" -ne 0 ]
  run git rev-parse --verify open
  [ "$status" -eq 0 ]
  run git rev-parse --verify main
  [ "$status" -eq 0 ]
}

@test "reports and exits 0 when there are no feature branches" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no feature branches to clean up"* ]]
}

@test "stops without stashing or discarding when checkout main is blocked by local changes" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  git checkout -q -b feature
  echo "feature readme" > README.md
  git -c commit.gpgsign=false commit -q -am "feature edits README"
  echo "uncommitted edit" > README.md

  FAKE_GH_MERGED_BRANCHES="feature" run bash "$SCRIPT" feature
  [ "$status" -ne 0 ]
  [[ "$output" == *"git checkout main failed"* ]]
  [[ "$output" == *"do not stash or discard"* ]]
  # Work is intact: still on feature, edit still there, nothing stashed.
  [ "$(git branch --show-current)" = "feature" ]
  [ "$(cat README.md)" = "uncommitted edit" ]
  [ -z "$(git stash list)" ]
  run git rev-parse --verify feature
  [ "$status" -eq 0 ]
}

# mk_gone_branch NAME FILE -> branch pushed to origin, then deleted upstream
# and pruned, so its local upstream tracks as [gone]. Leaves main checked out.
mk_gone_branch() {
  add_branch_commit "$1" "$2"
  git push -q -u origin "$1"
  git push -q origin --delete "$1"
  git checkout -q main
}

@test "prune --dry-run lists the [gone] branch and deletes nothing" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  mk_gone_branch stale stale.txt

  run bash "$SCRIPT" prune --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would delete (upstream gone):"* ]]
  [[ "$output" == *"stale"* ]]
  [[ "$output" == *"Count: 1"* ]]
  run git rev-parse --verify stale
  [ "$status" -eq 0 ]
}

@test "prune deletes [gone] branches but keeps branches whose upstream still exists" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  mk_gone_branch stale stale.txt
  add_branch_commit live live.txt
  git push -q -u origin live
  git checkout -q main

  run bash "$SCRIPT" prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleted: 1 stale branch(es)"* ]]
  run git rev-parse --verify stale
  [ "$status" -ne 0 ]
  run git rev-parse --verify live
  [ "$status" -eq 0 ]
  run git rev-parse --verify main
  [ "$status" -eq 0 ]
}

@test "prune never deletes the currently checked-out branch, even when its upstream is gone" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  add_branch_commit here here.txt
  git push -q -u origin here
  git push -q origin --delete here
  # stay on `here`

  run bash "$SCRIPT" prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"No stale branches to delete."* ]]
  [ "$(git branch --show-current)" = "here" ]
}

@test "prune never deletes the default branch even when its upstream tracking is gone" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  add_branch_commit other other.txt   # current = other, so main is a candidate
  # Point main at a remote-tracking ref that does not exist -> [gone].
  git config branch.main.merge refs/heads/vanished

  run bash "$SCRIPT" prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"No stale branches to delete."* ]]
  run git rev-parse --verify main
  [ "$status" -eq 0 ]
}

@test "prune reports nothing to do when no branch is [gone]" {
  BARE="$(mk_bare origin)"; WORK="$(seed_work_repo "$BARE")"; cd "$WORK"
  run bash "$SCRIPT" prune --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No stale branches to delete."* ]]
}
