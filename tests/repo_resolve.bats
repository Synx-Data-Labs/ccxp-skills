#!/usr/bin/env bats
# Tests for _repos/resolve.sh (repo-resolve) and `repos.sh resolve|switch`
# (T20261031-139856, PR 2). Hermetic: temp registry via CLAUDE_CONFIG_DIR,
# real git repos, a fake pbcopy, the Claude version injected with
# CCXP_CLAUDE_VERSION.

load test_helper

REPOS="$REPO_ROOT/_repos/repos.sh"

setup() {
  ROOT="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/ws"
  mkdir -p "$ROOT"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  export CCXP_NO_CLIPBOARD=1
  export CCXP_CLAUDE_VERSION="2.1.311"
  unset CCXP_REPO
  REG="$CLAUDE_CONFIG_DIR/ccxp-repos.json"
}

mkrepo() {
  local d="$1" marker="${2:-1}"
  mkdir -p "$d"
  git -C "$d" init -q .
  git_identity "$d"
  if [ "$marker" = 1 ]; then mkdir -p "$d/dev/TODO"; : >"$d/dev/TODO/.gitkeep"; fi
  : >"$d/README"
  git -C "$d" add -A
  git -C "$d" commit -q -m init
}

# fixture: four registered repos; synx-skills has slug + alias.
fixture() {
  mkrepo "$ROOT/synx-skills"
  mkrepo "$ROOT/synx-data-labs"
  mkrepo "$ROOT/other"
  mkrepo "$ROOT/ccxp-skills"
  git -C "$ROOT/synx-skills" remote add origin git@host:Org/synx-skills.git
  bash "$REPOS" scan "$ROOT" >/dev/null
  jq '(.repos[] | select(.name == "synx-skills")).aliases = ["sk"]' "$REG" >"$REG.new" && mv "$REG.new" "$REG"
}

@test "tier exact/prefix/substring/subsequence" {
  fixture
  run bash "$REPOS" resolve synx-skills
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/synx-skills" ]
  run bash "$REPOS" resolve SYNX-SKILLS
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/synx-skills" ]
  run bash "$REPOS" resolve sk
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/synx-skills" ]
  run bash "$REPOS" resolve synx-d
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/synx-data-labs" ]
  run bash "$REPOS" resolve labs
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/synx-data-labs" ]
  run bash "$REPOS" resolve sdl
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/synx-data-labs" ]
}

@test "ambiguous prefix exits 3 with candidates and never widens" {
  fixture
  run bash "$REPOS" resolve synx
  [ "$status" -eq 3 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  # sorted by name: synx-data-labs before synx-skills; tab separated path, name, slug
  [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f2)" = "synx-data-labs" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p | cut -f1)" = "$ROOT/synx-skills" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p | cut -f3)" = "Org/synx-skills" ]
}

@test "same folder name under two orgs is ambiguous" {
  mkrepo "$ROOT/a/dup"
  mkrepo "$ROOT/b/dup"
  bash "$REPOS" scan "$ROOT" >/dev/null
  run bash "$REPOS" resolve dup
  [ "$status" -eq 3 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f1)" = "$ROOT/a/dup" ]
}

@test "no match exits 4 and points at /repo scan" {
  fixture
  run bash "$REPOS" resolve zzzz
  [ "$status" -eq 4 ]
  [[ "$output" == *"/repo scan"* ]]
}

@test "owner/name is a name, not a path" {
  fixture
  cd "$BATS_TEST_TMPDIR"
  run bash "$REPOS" resolve org/synx-skills
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/synx-skills" ]
}

@test "bare name never read as a folder" {
  fixture
  mkdir -p "$BATS_TEST_TMPDIR/cwd/other"
  cd "$BATS_TEST_TMPDIR/cwd"
  run bash "$REPOS" resolve other
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/other" ]
}

@test "stale registry path is ignored, not resolved" {
  fixture
  mkdir -p "$BATS_TEST_TMPDIR/graveyard"
  mv "$ROOT/other" "$BATS_TEST_TMPDIR/graveyard/other"
  run bash "$REPOS" resolve other
  [ "$status" -eq 4 ]
}

@test "malformed registry exits 6" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{broken' >"$REG"
  run bash "$REPOS" resolve anything
  [ "$status" -eq 6 ]
}

@test "--repo then CCXP_REPO then PWD order" {
  fixture
  cd "$ROOT/synx-skills"
  run bash "$REPOS" resolve
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/synx-skills" ]
  CCXP_REPO=other run bash "$REPOS" resolve
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/other" ]
  CCXP_REPO=other run bash "$REPOS" resolve sdl
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/synx-data-labs" ]
}

@test "resolve outside a git repo exits 2" {
  mkdir -p "$BATS_TEST_TMPDIR/nogit"
  cd "$BATS_TEST_TMPDIR/nogit"
  run env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" bash "$REPOS" resolve
  [ "$status" -eq 2 ]
}

@test "PWD fallback needs dev/TODO unless --any" {
  mkrepo "$ROOT/plain" 0
  cd "$ROOT/plain"
  run bash "$REPOS" resolve
  [ "$status" -eq 5 ]
  run bash "$REPOS" resolve --any
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/plain" ]
}

@test "unregistered path refused, --any accepts" {
  fixture
  mkrepo "$BATS_TEST_TMPDIR/stranger"
  run bash "$REPOS" resolve "$BATS_TEST_TMPDIR/stranger"
  [ "$status" -eq 5 ]
  run bash "$REPOS" resolve "$BATS_TEST_TMPDIR/stranger" --any
  [ "$status" -eq 0 ]; [ "$output" = "$(cd "$BATS_TEST_TMPDIR/stranger" && pwd -P)" ]
}

@test "registered path and subfolder resolve to the toplevel" {
  fixture
  mkdir -p "$ROOT/other/sub/deeper"
  run bash "$REPOS" resolve "$ROOT/other/sub/deeper"
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/other" ]
  cd "$ROOT"
  run bash "$REPOS" resolve ./other
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/other" ]
}

@test "worktree path accepted via git worktree list" {
  fixture
  git -C "$ROOT/other" worktree add -q "$ROOT/other-wt" -b wtb
  run bash "$REPOS" resolve "$ROOT/other-wt"
  [ "$status" -eq 0 ]; [ "$output" = "$ROOT/other-wt" ]
}

@test "usage: unknown argument to repo-resolve exits 2" {
  run bash -c "source '$REPOS'; repo-resolve --bogus"
  [ "$status" -eq 2 ]
}

@test "sourcing resolve.sh has no side effects and never changes directory" {
  fixture
  run bash -c "cd '$ROOT/other' && source '$REPOS' && repo-resolve --repo sdl >/dev/null && pwd -P"
  [ "$status" -eq 0 ]
  [ "$output" = "$ROOT/other" ]
}

@test "switch prints the /cd line on its own first line" {
  fixture
  run bash "$REPOS" switch sdl
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "/cd $ROOT/synx-data-labs" ]
  [[ "$output" == *"Type it yourself; I cannot run /cd"* ]]
  [[ "$output" == *"other repo"* ]]
}

@test "switch ambiguity lists candidates with exit 3" {
  fixture
  run bash "$REPOS" switch synx
  [ "$status" -eq 3 ]
  [[ "$output" == *"$ROOT/synx-data-labs"* ]]
  [[ "$output" == *"$ROOT/synx-skills"* ]]
}

@test "switch with no match exits 4, no query exits 2, and it never runs cd or checkout" {
  fixture
  run bash "$REPOS" switch zzzz
  [ "$status" -eq 4 ]
  run bash "$REPOS" switch
  [ "$status" -eq 2 ]
  cd "$ROOT/other"
  before="$(git rev-parse HEAD)"
  bash "$REPOS" switch sdl >/dev/null
  [ "$(pwd -P)" = "$ROOT/other" ]
  [ "$(git rev-parse HEAD)" = "$before" ]
  [ "$(git symbolic-ref --short HEAD)" = "$(git -C "$ROOT/other" symbolic-ref --short HEAD)" ]
}

@test "switch says already here for the current repo" {
  fixture
  cd "$ROOT/other"
  run bash "$REPOS" switch other
  [ "$status" -eq 0 ]
  [[ "$output" == "Already in $ROOT/other."* ]]
}

@test "version gate below/at/unknown" {
  fixture
  CCXP_CLAUDE_VERSION="2.1.245" run bash "$REPOS" switch sdl
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "cd $ROOT/synx-data-labs && claude" ]
  [[ "$output" == *"below 2.1.246"* ]]
  CCXP_CLAUDE_VERSION="2.1.246 (Claude Code)" run bash "$REPOS" switch sdl
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "/cd $ROOT/synx-data-labs" ]
  CCXP_CLAUDE_VERSION="2.2.0" run bash "$REPOS" switch sdl
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "/cd $ROOT/synx-data-labs" ]
  CCXP_CLAUDE_VERSION="10.0.0" run bash "$REPOS" switch sdl
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "/cd $ROOT/synx-data-labs" ]
  CCXP_CLAUDE_VERSION="1.99.999" run bash "$REPOS" switch sdl
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "cd $ROOT/synx-data-labs && claude" ]
  CCXP_CLAUDE_VERSION="not-a-version" run bash "$REPOS" switch sdl
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "cd $ROOT/synx-data-labs && claude" ]
}

@test "path with spaces" {
  mkrepo "$ROOT/with space/my repo"
  bash "$REPOS" scan "$ROOT" >/dev/null
  run bash "$REPOS" switch "my repo"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "/cd \"$ROOT/with space/my repo\"" ]
  [[ "$output" == *"cd $(printf '%q' "$ROOT/with space/my repo") && claude"* ]]
}

@test "switch copies the line with pbcopy when present" {
  fixture
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  printf '#!/bin/sh\ncat > "%s/clip"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/fakebin/pbcopy"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/pbcopy"
  unset CCXP_NO_CLIPBOARD
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run bash "$REPOS" switch sdl
  [ "$status" -eq 0 ]
  [[ "$output" == *"(copied to the clipboard)"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/clip")" = "/cd $ROOT/synx-data-labs" ]
}

@test "repo.sh forwards switch" {
  fixture
  run bash "$REPO_ROOT/repo/scripts/repo.sh" switch sdl
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "/cd $ROOT/synx-data-labs" ]
}
