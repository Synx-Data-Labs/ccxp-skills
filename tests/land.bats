#!/usr/bin/env bats
# Tests for _gh/land.sh — branch/add/commit/push/PR helper. push and gh are
# stubbed through LAND_GIT / LAND_GH; git itself is real (local bare origin).

load test_helper
setup() {
  LAND="$BATS_TEST_DIRNAME/../_gh/land.sh"
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  R="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$R"
  cd "$R"
  git_identity "$R" t@t t
  echo a > tracked.md; echo x > other.md
  git add .; git commit -qm init
  git remote add origin "$BATS_TEST_TMPDIR/origin.git"
  cat > "$BATS_TEST_TMPDIR/fakegh" <<'EOS'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_LOG"
echo "https://github.com/o/r/pull/42"
EOS
  cat > "$BATS_TEST_TMPDIR/fakegit" <<'EOS'
#!/usr/bin/env bash
echo "git $@" >> "$FAKE_LOG"
git "$@"
EOS
  chmod +x "$BATS_TEST_TMPDIR/fakegh" "$BATS_TEST_TMPDIR/fakegit"
  export FAKE_LOG="$BATS_TEST_TMPDIR/log"
  export LAND_GH="$BATS_TEST_TMPDIR/fakegh" LAND_GIT="$BATS_TEST_TMPDIR/fakegit"
}

@test "commits only the listed paths, pushes, prints the PR URL" {
  echo b >> tracked.md; echo y >> other.md
  run bash "$LAND" --branch docs/x --message "docs: x" --title "T" --body "B" -- tracked.md
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/o/r/pull/42" ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = docs/x ]
  [ "$(git show --name-only --format= HEAD)" = tracked.md ]
  git status --porcelain | grep -q "other.md"
  grep -q "push -q -u origin docs/x" "$FAKE_LOG"
  grep -q -- "pr create --base main --head docs/x --title T --body B" "$FAKE_LOG"
}

@test "exits 3 and creates no branch when the paths have no changes" {
  run bash "$LAND" --branch docs/x --message m --title T -- tracked.md
  [ "$status" -eq 3 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = main ]
  [ ! -e "$FAKE_LOG" ]
}

@test "reuses the branch when it is already checked out" {
  git checkout -q -b docs/x
  echo b >> tracked.md
  run bash "$LAND" --branch docs/x --message m --title T --body-file /dev/null -- tracked.md
  [ "$status" -eq 0 ]
  grep -q -- "--body-file /dev/null" "$FAKE_LOG"
}

@test "missing required args or unknown flag exits 2" {
  run bash "$LAND" --branch docs/x
  [ "$status" -eq 2 ]
  run bash "$LAND" --bogus
  [ "$status" -eq 2 ]
}

@test "an unrelated already-staged file is not swept into the commit" {
  echo b >> tracked.md; echo y >> other.md; git add other.md
  run bash "$LAND" --branch docs/x --message m --title T --body B -- tracked.md
  [ "$status" -eq 0 ]
  [ "$(git show --name-only --format= HEAD)" = tracked.md ]
  git diff --cached --name-only | grep -q other.md
}
