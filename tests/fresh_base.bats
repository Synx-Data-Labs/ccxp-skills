#!/usr/bin/env bats
# Tests for _gh/fresh-base.sh (d129): a bare origin, a working clone, plain git.

load test_helper
FB="$REPO_ROOT/_gh/fresh-base.sh"

setup() {
  export FRESH_BASE_GIT=git
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  UPSTREAM="$BATS_TEST_TMPDIR/upstream"
  WORK="$BATS_TEST_TMPDIR/work"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$UPSTREAM"; git_identity "$UPSTREAM"
  echo a > "$UPSTREAM/a.txt"; git -C "$UPSTREAM" add -A; git -C "$UPSTREAM" commit -qm init
  git -C "$UPSTREAM" remote add origin "$ORIGIN"; git -C "$UPSTREAM" push -q origin main
  git clone -q "$ORIGIN" "$WORK"; git_identity "$WORK"
}

_advance() { # <file> <content>: a new commit on origin/main
  echo "$2" > "$UPSTREAM/$1"; git -C "$UPSTREAM" add -A; git -C "$UPSTREAM" commit -qm "adv $1"
  git -C "$UPSTREAM" push -q origin main
}
_branch_commit() { # <file> <content>: a local feature commit
  git -C "$WORK" checkout -q -b feat; echo "$2" > "$WORK/$1"; git -C "$WORK" add -A; git -C "$WORK" commit -qm "feat $1"
}

@test "check: up to date prints fresh and exits 0" {
  run bash "$FB" check --dir "$WORK"
  [ "$status" -eq 0 ]; [[ "$output" == "fresh "* ]]
}

@test "check: behind origin/main prints stale and exits 10 without rebasing" {
  _branch_commit f.txt x; _advance b.txt b
  head_before="$(git -C "$WORK" rev-parse HEAD)"
  run bash "$FB" check --dir "$WORK"
  [ "$status" -eq 10 ]; [ "$output" = "stale behind=1" ]
  [ "$(git -C "$WORK" rev-parse HEAD)" = "$head_before" ]
}

@test "check --rebase: behind and clean rebases onto origin/main" {
  _branch_commit f.txt x; _advance b.txt b
  run bash "$FB" check --rebase --dir "$WORK"
  [ "$status" -eq 0 ]; [[ "$output" == "rebased "* ]]
  git -C "$WORK" merge-base --is-ancestor origin/main HEAD
  [ -f "$WORK/b.txt" ] && [ -f "$WORK/f.txt" ]
}

@test "check --rebase: a conflict aborts the rebase, exits 11, leaves the branch intact" {
  _branch_commit a.txt mine; _advance a.txt theirs
  head_before="$(git -C "$WORK" rev-parse HEAD)"
  run bash "$FB" check --rebase --dir "$WORK"
  [ "$status" -eq 11 ]; [ "$output" = "conflict" ]
  [ "$(git -C "$WORK" rev-parse HEAD)" = "$head_before" ]
  [ ! -d "$WORK/.git/rebase-merge" ] && [ ! -d "$WORK/.git/rebase-apply" ]
}

@test "check --rebase: tracked uncommitted changes refuse with dirty (exit 12)" {
  _branch_commit f.txt x; _advance b.txt b
  echo changed >> "$WORK/f.txt"
  run bash "$FB" check --rebase --dir "$WORK"
  [ "$status" -eq 12 ]; [ "$output" = "dirty" ]
}

@test "check: fetch failure fails closed (exit 3), never fresh" {
  git -C "$WORK" remote set-url origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  run bash "$FB" check --dir "$WORK"
  [ "$status" -eq 3 ]; [ "$output" = "fetch-failed" ]
}

@test "check: a remote without the base branch fails closed (exit 3)" {
  run bash "$FB" check --base nope --dir "$WORK"
  [ "$status" -eq 3 ]; [ "$output" = "fetch-failed" ]
}

@test "remote: a pushed branch containing origin/main is fresh, a stale one exits 10" {
  _branch_commit f.txt x; git -C "$WORK" push -q origin feat
  run bash "$FB" remote feat --dir "$WORK"
  [ "$status" -eq 0 ]; [[ "$output" == "fresh "* ]]
  _advance b.txt b
  run bash "$FB" remote feat --dir "$WORK"
  [ "$status" -eq 10 ]; [ "$output" = "stale behind=1" ]
}

@test "remote: an unpushed branch fails closed (exit 3)" {
  run bash "$FB" remote ghost --dir "$WORK"
  [ "$status" -eq 3 ]
}

@test "usage: no verb, unknown option, remote without branch, non-repo dir" {
  run bash "$FB"; [ "$status" -eq 2 ]
  run bash "$FB" check --bogus; [ "$status" -eq 2 ]
  run bash "$FB" remote --dir "$WORK"; [ "$status" -eq 2 ]
  run bash "$FB" check --dir "$BATS_TEST_TMPDIR"; [ "$status" -eq 2 ]
}

@test "check: a narrowed fetch refspec cannot leave a stale origin/main trusted" {
  git -C "$WORK" remote set-branches origin feat-other
  _advance b.txt b
  run bash "$FB" check --dir "$WORK"
  [ "$status" -eq 10 ]; [ "$output" = "stale behind=1" ]
}

@test "check --rebase: detached HEAD and a rebase already in progress exit 13" {
  _advance b.txt b
  git -C "$WORK" checkout -q --detach
  run bash "$FB" check --rebase --dir "$WORK"
  [ "$status" -eq 13 ]; [ "$output" = "detached" ]
  git -C "$WORK" checkout -q main; mkdir -p "$WORK/.git/rebase-merge"
  run bash "$FB" check --rebase --dir "$WORK"
  [ "$status" -eq 13 ]; [ "$output" = "in-progress" ]
}

@test "check --rebase: an untracked file in the way reports conflict and leaves the branch intact" {
  _branch_commit f.txt x; _advance new.txt theirs
  echo mine > "$WORK/new.txt"
  head_before="$(git -C "$WORK" rev-parse HEAD)"
  run bash "$FB" check --rebase --dir "$WORK"
  [ "$status" -eq 11 ]; [ "$(git -C "$WORK" rev-parse HEAD)" = "$head_before" ]
}

@test "check: --dir does not change the sourcing caller's cwd" {
  here="$PWD"; source "$FB"
  run fresh-base-main check --dir "$WORK"
  [ "$status" -eq 0 ]; [ "$PWD" = "$here" ]
}

@test "wiring: drive and gcpr docs call fresh-base.sh before push and dispatch" {
  grep -q 'fresh-base.sh check --rebase' "$REPO_ROOT/drive/SKILL.md"
  grep -q 'fresh-base.sh remote' "$REPO_ROOT/drive/SKILL.md"
  grep -q 'fresh-base.sh check --rebase' "$REPO_ROOT/gcpr/SKILL.md"
}
