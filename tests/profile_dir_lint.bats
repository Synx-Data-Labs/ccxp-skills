#!/usr/bin/env bats
# Tests for _session/lint_profile_dir.sh (T20261108-315759): no bare ~/.claude
# profile literal in code outside _session/profile-dir.sh.

load test_helper

setup() {
  LINT="$REPO_ROOT/_session/lint_profile_dir.sh"
  FIX="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$FIX/s"
}

@test "the repository tree is clean" {
  run bash "$LINT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a bare \$HOME/.claude line fails" {
  printf '%s\n' 'x="$HOME/.claude/state"' > "$FIX/s/a.sh"
  run bash "$LINT" "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"s/a.sh:1:"* ]]
}

@test "the inline CLAUDE_CONFIG_DIR fallback form fails too" {
  printf '%s\n' 'x="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/f"' > "$FIX/s/a.sh"
  run bash "$LINT" "$FIX"
  [ "$status" -eq 1 ]
}

@test "a tilde form and an end-of-line form fail" {
  printf '%s\n' 'cat ~/.claude/.env' > "$FIX/s/a.sh"
  printf '%s\n' 'd=$HOME/.claude' > "$FIX/s/b.sh"
  run bash "$LINT" "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.sh"* && "$output" == *"b.sh"* ]]
}

@test "python home forms fail" {
  printf '%s\n' 'p = Path.home() / ".claude"' > "$FIX/s/a.py"
  printf '%s\n' 'q = os.path.join(h, ".claude", "x")' > "$FIX/s/b.py"
  run bash "$LINT" "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.py"* && "$output" == *"b.py"* ]]
}

@test "comment-only lines, .claude-work, .claude-plugin and repo-relative paths pass" {
  {
    printf '%s\n' '# see ~/.claude/.env for the machine-global file'
    printf '%s\n' 'a=$HOME/.claude-work/x'
    printf '%s\n' 'b="$root/.claude-plugin/plugin.json"'
    printf '%s\n' 'c=.claude/state/drive-threads.json'
  } > "$FIX/s/a.sh"
  run bash "$LINT" "$FIX"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the profile-dir-ok marker exempts a line; the helper itself is exempt" {
  printf '%s\n' 'x="$HOME/.claude" # profile-dir-ok' > "$FIX/s/a.sh"
  mkdir -p "$FIX/_session"
  printf '%s\n' 'x="$HOME/.claude"' > "$FIX/_session/profile-dir.sh"
  run bash "$LINT" "$FIX"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "files under tests/ are not scanned" {
  mkdir -p "$FIX/tests"
  printf '%s\n' 'x="$HOME/.claude"' > "$FIX/tests/a.sh"
  run bash "$LINT" "$FIX"
  [ "$status" -eq 0 ]
}

@test "a missing root is a usage error" {
  run bash "$LINT" "$FIX/nope"
  [ "$status" -eq 2 ]
}
