#!/usr/bin/env bats
# Tests for memory-to-skill/scripts/find-memory-dir.sh — deterministic
# resolution of the current clone's Claude Code auto-memory directory from
# its working-directory path (see memory-to-skill/SKILL.md).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/memory-to-skill/scripts/find-memory-dir.sh"

  CLAUDE_HOME="$BATS_TEST_TMPDIR/dot-claude"
  mkdir -p "$CLAUDE_HOME/projects/-Users-xlj-workspace-my-repo/memory"
}

@test "find-memory-dir.sh exists and is executable-by-bash" {
  [ -f "$REPO_ROOT/memory-to-skill/scripts/find-memory-dir.sh" ]
}

@test "resolves an existing memory dir by replacing every / with -" {
  run memory-to-skill-find-dir --cwd "/Users/xlj/workspace/my-repo" --claude-home "$CLAUDE_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$CLAUDE_HOME/projects/-Users-xlj-workspace-my-repo/memory" ]
}

@test "fails with exit 1 when no memory dir exists for that cwd" {
  run memory-to-skill-find-dir --cwd "/Users/xlj/workspace/never-remembered" --claude-home "$CLAUDE_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no memory directory"* ]]
}

@test "defaults --cwd to pwd when omitted" {
  mkdir -p "$BATS_TEST_TMPDIR/cwd-case"
  local encoded="${BATS_TEST_TMPDIR//\//-}-cwd-case"
  mkdir -p "$CLAUDE_HOME/projects/$encoded/memory"
  cd "$BATS_TEST_TMPDIR/cwd-case"
  run memory-to-skill-find-dir --claude-home "$CLAUDE_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$CLAUDE_HOME/projects/$encoded/memory" ]
}

@test "rejects a relative --cwd with exit 2" {
  run memory-to-skill-find-dir --cwd "relative/path" --claude-home "$CLAUDE_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be an absolute path"* ]]
}

@test "defaults --claude-home to \$HOME/.claude when omitted" {
  local real_home="$BATS_TEST_TMPDIR/home-case"
  mkdir -p "$real_home/.claude/projects/-tmp-somewhere/memory"
  HOME="$real_home" run memory-to-skill-find-dir --cwd "/tmp/somewhere"
  [ "$status" -eq 0 ]
  [ "$output" = "$real_home/.claude/projects/-tmp-somewhere/memory" ]
}

@test "rejects --cwd with a missing value with exit 2 (not an unbound-variable crash)" {
  run memory-to-skill-find-dir --cwd
  [ "$status" -eq 2 ]
  [[ "$output" == *"--cwd requires a value"* ]]
}

@test "rejects --claude-home with a missing value with exit 2" {
  run memory-to-skill-find-dir --cwd "/tmp/x" --claude-home
  [ "$status" -eq 2 ]
  [[ "$output" == *"--claude-home requires a value"* ]]
}

@test "-h/--help prints usage and exits 0" {
  run memory-to-skill-find-dir --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "rejects an unknown argument with exit 2" {
  run memory-to-skill-find-dir --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "sourcing the script does not leak set -e/-u/pipefail into the caller's shell" {
  run bash -c "source '$REPO_ROOT/memory-to-skill/scripts/find-memory-dir.sh'; unset_but_ok=\$UNSET_VAR; echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
