#!/usr/bin/env bats
# Tests for statusline-setup/scripts/statusline-command.sh — the Claude Code
# statusLine command that surfaces the task claimed by the calling clone plus
# the remaining context-window percentage.
#
# Helper functions are sourced and tested directly (function-wrapped, see the
# BASH_SOURCE guard at the bottom of the script — same pattern as
# quality-probe/scripts/probe.sh). The stdin entrypoint statusline-command is
# tested end-to-end by piping a synthetic hook-input JSON payload.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/statusline-setup/scripts/statusline-command.sh"

_load() { source "$SCRIPT"; }

# Build a throwaway git repo with a dev/TODO dir under $BATS_TEST_TMPDIR and
# print its path. Args: $1 = subdir name.
_make_repo() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir/dev/TODO"
  git -C "$dir" init -q
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# Sourceable / structure
# ---------------------------------------------------------------------------

@test "statusline-command.sh exists and is executable" {
  [ -x "$SCRIPT" ]
}

@test "statusline-command.sh is sourceable without executing its main (function-wrapped)" {
  run bash -c "source '$SCRIPT'; type statusline-command >/dev/null 2>&1 && echo OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ---------------------------------------------------------------------------
# sl-repo-root
# ---------------------------------------------------------------------------

@test "sl-repo-root resolves the git toplevel for a path inside a repo" {
  local repo
  repo=$(_make_repo repo1)
  mkdir -p "$repo/dev/TODO/nested"
  run bash -c "source '$SCRIPT'; sl-repo-root '$repo/dev/TODO/nested'"
  [ "$status" -eq 0 ]
  # Compare against git's own realpath-resolved toplevel, not $repo verbatim —
  # on macOS $BATS_TEST_TMPDIR lives under /var, a symlink to /private/var, so
  # raw $repo and git's resolved output legitimately differ textually.
  [ "$output" = "$(git -C "$repo" rev-parse --show-toplevel)" ]
}

@test "sl-repo-root falls back to the given cwd when not a git repo" {
  local dir="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$dir"
  run bash -c "source '$SCRIPT'; sl-repo-root '$dir'"
  [ "$status" -eq 0 ]
  [ "$output" = "$dir" ]
}

# ---------------------------------------------------------------------------
# sl-clone-id
# ---------------------------------------------------------------------------

@test "sl-clone-id joins hostname and repo root with a colon" {
  run bash -c "source '$SCRIPT'; sl-clone-id '/some/repo'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(hostname):/some/repo" ]
}

# ---------------------------------------------------------------------------
# sl-claimed-task-label
# ---------------------------------------------------------------------------

@test "sl-claimed-task-label prints nothing when the TODO dir does not exist" {
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$BATS_TEST_TMPDIR/missing' 'host:/repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-claimed-task-label prints nothing when no task is claimed by this clone" {
  local repo clone_id
  repo=$(_make_repo repo2)
  clone_id="$(hostname):$repo"
  cat > "$repo/dev/TODO/T20260101-000001.md" <<EOF
---
claimed_by: otherhost:/other/repo
---
# T20260101-000001: Some task
EOF
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$repo/dev/TODO' '$clone_id'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sl-claimed-task-label prints '<id>: <title>' when claimed_by matches and a heading exists" {
  local repo clone_id
  repo=$(_make_repo repo3)
  clone_id="$(hostname):$repo"
  cat > "$repo/dev/TODO/T20260427-242654.md" <<EOF
---
claimed_by: ${clone_id}
---
# T20260427-242654: Fix the thing
EOF
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$repo/dev/TODO' '$clone_id'"
  [ "$status" -eq 0 ]
  [ "$output" = "T20260427-242654: Fix the thing" ]
}

@test "sl-claimed-task-label prints just the id when no '# T<id>' heading exists" {
  local repo clone_id
  repo=$(_make_repo repo4)
  clone_id="$(hostname):$repo"
  cat > "$repo/dev/TODO/T20260427-242654.md" <<EOF
---
claimed_by: ${clone_id}
---
No heading here.
EOF
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$repo/dev/TODO' '$clone_id'"
  [ "$status" -eq 0 ]
  [ "$output" = "T20260427-242654" ]
}

@test "sl-claimed-task-label anchors the match so a longer sibling clone-id cannot match as a prefix" {
  local repo clone_id
  repo=$(_make_repo repo5)
  clone_id="$(hostname):$repo"
  # A sibling clone whose id has this clone's id as a strict prefix.
  cat > "$repo/dev/TODO/T20260427-999999.md" <<EOF
---
claimed_by: ${clone_id}-sibling-suffix
---
# T20260427-999999: Wrong match
EOF
  run bash -c "source '$SCRIPT'; sl-claimed-task-label '$repo/dev/TODO' '$clone_id'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# sl-branch-name
# ---------------------------------------------------------------------------

@test "sl-branch-name prints the current branch name" {
  local repo
  repo=$(_make_repo repo-branch1)
  git -C "$repo" checkout -q -b some-feature-branch
  run bash -c "source '$SCRIPT'; sl-branch-name '$repo'"
  [ "$status" -eq 0 ]
  [ "$output" = "some-feature-branch" ]
}

@test "sl-branch-name works pre-first-commit (unborn HEAD)" {
  local repo
  repo=$(_make_repo repo-branch2)
  run bash -c "source '$SCRIPT'; sl-branch-name '$repo'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(git -C "$repo" symbolic-ref --short HEAD)" ]
}

@test "sl-branch-name prints nothing when not a git repo" {
  local dir="$BATS_TEST_TMPDIR/not-a-repo-branch"
  mkdir -p "$dir"
  run bash -c "source '$SCRIPT'; sl-branch-name '$dir'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# sl-join
# ---------------------------------------------------------------------------

@test "sl-join joins non-empty parts with ' | '" {
  run bash -c "source '$SCRIPT'; sl-join 'a' 'b'"
  [ "$status" -eq 0 ]
  [ "$output" = "a | b" ]
}

@test "sl-join skips empty parts" {
  run bash -c "source '$SCRIPT'; sl-join '' 'b' ''"
  [ "$status" -eq 0 ]
  [ "$output" = "b" ]
}

@test "sl-join returns empty string when all parts are empty" {
  run bash -c "source '$SCRIPT'; sl-join '' ''"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# statusline-command (full stdin -> stdout pipeline)
# ---------------------------------------------------------------------------

@test "statusline-command reports no claimed task and the given context percentage" {
  local repo branch
  repo=$(_make_repo repo6)
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  run bash -c "echo '{\"cwd\":\"$repo\",\"context_window\":{\"remaining_percentage\":42}}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 42% left | branch: $branch | no claimed task" ]
}

@test "statusline-command reports the claimed task label when claimed_by matches" {
  local repo clone_id branch
  repo=$(_make_repo repo7)
  # statusline-command resolves cwd to git's realpath toplevel internally
  # (see the macOS /var->/private/var note above), so build clone_id from
  # that same resolved path rather than the raw $repo.
  clone_id="$(hostname):$(git -C "$repo" rev-parse --show-toplevel)"
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  cat > "$repo/dev/TODO/T20260427-242654.md" <<EOF
---
claimed_by: ${clone_id}
---
# T20260427-242654: Fix the thing
EOF
  run bash -c "echo '{\"cwd\":\"$repo\",\"context_window\":{\"remaining_percentage\":80}}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 80% left | branch: $branch | TASK: T20260427-242654: Fix the thing" ]
}

@test "statusline-command defaults remaining_percentage to 100 when absent" {
  local repo branch
  repo=$(_make_repo repo8)
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  run bash -c "echo '{\"cwd\":\"$repo\"}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 100% left | branch: $branch | no claimed task" ]
}

@test "statusline-command falls back to PWD when cwd is absent from the payload" {
  local repo branch
  repo=$(_make_repo repo9)
  branch=$(git -C "$repo" symbolic-ref --short HEAD)
  run bash -c "cd '$repo' && echo '{}' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$output" = "ctx: 100% left | branch: $branch | no claimed task" ]
}
